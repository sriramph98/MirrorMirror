import AVFoundation
import CoreImage
import CoreText
import UIKit
import VideoToolbox
import LiveKitWebRTC

/// Owns the camera + microphone and produces the processed frames everything else consumes
/// (live streams, recorder, motion detection, local preview). On devices without a camera
/// (the simulator) it falls back to a generated test pattern so the rest of the app still works.
final class CaptureEngine: NSObject {
    struct State: Equatable {
        var usingFrontCamera = false
        var lenses: [LensOption] = []
        var zoom: Double = 1
        var maxZoom: Double = 1
        var torchAvailable = false
        var torchOn = false
        var nightActive = false
        var isSynthetic = false
        var hasAudio = false
        var isRunning = false
        /// Cameras this device can switch between (a Mac: built-in, Continuity Camera, USB).
        var cameraCount = 1
    }

    /// Processed, upright frames. Called on the video queue.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    /// Microphone sample buffers. Called on the audio queue.
    var onAudio: ((CMSampleBuffer) -> Void)?
    /// Something in `state` changed. Any thread.
    var onStateChange: ((State) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "mm.capture.session")
    private let videoQueue = DispatchQueue(label: "mm.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "mm.capture.audio", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var device: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var wideBaseZoom: CGFloat = 1

    private let lock = NSLock()
    private var _state = State()
    var state: State { lock.withLock { _state } }

    private var quality: QualityPreset = .high
    private var nightMode: NightMode = .auto
    private var nightEnhance = true
    private var mainsHz = 60
    private var latestFrame: CVPixelBuffer?

    private let processor = FrameProcessor()
    private var darkSamples = 0
    private var brightSamples = 0
    private var frameCount = 0
    private var syntheticTimer: DispatchSourceTimer?
    private var synthetic: SyntheticFrameSource?

    // MARK: Lifecycle

    func configure(quality: QualityPreset, nightMode: NightMode, enhance: Bool, mains: MainsFrequency) {
        sessionQueue.async { [self] in
            let formatChanged = quality != self.quality || mains.resolvedHz != mainsHz
            self.quality = quality
            self.nightMode = nightMode
            self.nightEnhance = enhance
            self.mainsHz = mains.resolvedHz
            processor.targetLongEdge = quality.dimensions.long
            if nightMode == .on { updateState { $0.nightActive = true } }
            if nightMode == .off { updateState { $0.nightActive = false } }
            if let device, formatChanged { applyFormat(to: device) } else if let device { applyExposurePolicy(to: device) }
        }
    }

    func start() {
        sessionQueue.async { [self] in
            if session.inputs.isEmpty && synthetic == nil { setUp() }
            if let synthetic {
                startSynthetic(synthetic)
            } else if !session.isRunning {
                session.startRunning()
            }
            updateState { $0.isRunning = true }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            syntheticTimer?.cancel()
            syntheticTimer = nil
            if session.isRunning { session.stopRunning() }
            setTorchLocked(false)
            updateState { $0.isRunning = false }
        }
    }

    /// Most recent processed frame, for full-resolution snapshots.
    func currentFrame() -> CVPixelBuffer? { lock.withLock { latestFrame } }

    // MARK: Controls

    func setLens(_ factor: Double) { setZoom(factor, animated: false) }

    func setZoom(_ factor: Double, animated: Bool = true) {
        sessionQueue.async { [self] in
            guard let device else { return }
            let target = min(max(CGFloat(factor) * wideBaseZoom, device.minAvailableVideoZoomFactor),
                             min(device.maxAvailableVideoZoomFactor, 10 * wideBaseZoom))
            do {
                try device.lockForConfiguration()
                if animated { device.ramp(toVideoZoomFactor: target, withRate: 8) } else { device.videoZoomFactor = target }
                device.unlockForConfiguration()
                updateState { $0.zoom = Double(target / wideBaseZoom) }
            } catch {
                print("CaptureEngine zoom: \(error)")
            }
        }
    }

    func flipCamera() {
        sessionQueue.async { [self] in
            guard synthetic == nil else { return }
            #if targetEnvironment(macCatalyst)
            // No front and back on a Mac: step to the next camera that is plugged in or nearby.
            let cameras = Self.macCameras()
            guard cameras.count > 1, let current = device,
                  let index = cameras.firstIndex(where: { $0.uniqueID == current.uniqueID }) else { return }
            let newDevice = cameras[(index + 1) % cameras.count]
            #else
            let front = !state.usingFrontCamera
            guard let newDevice = Self.bestDevice(front: front) else { return }
            #endif
            setTorchLocked(false)
            session.beginConfiguration()
            if let videoInput { session.removeInput(videoInput) }
            if let input = try? AVCaptureDeviceInput(device: newDevice), session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
                device = newDevice
            } else if let videoInput {
                session.addInput(videoInput)
            }
            session.commitConfiguration()
            updateState { $0.usingFrontCamera = self.device?.position == .front }
            if let device { didSelect(device) }
            processor.resetNightSampling()
        }
    }

    func setTorch(_ on: Bool) {
        sessionQueue.async { [self] in setTorchLocked(on) }
    }

    private func setTorchLocked(_ on: Bool) {
        guard let device, device.hasTorch, device.isTorchAvailable else { return }
        do {
            try device.lockForConfiguration()
            if on { try device.setTorchModeOn(level: 0.6) } else { device.torchMode = .off }
            device.unlockForConfiguration()
            updateState { $0.torchOn = on }
        } catch {
            print("CaptureEngine torch: \(error)")
        }
    }

    // MARK: Setup

    private func setUp() {
        guard let camera = Self.bestDevice(front: false) else {
            synthetic = SyntheticFrameSource()
            updateState { $0.isSynthetic = true; $0.lenses = [LensOption(factor: 1)] }
            return
        }

        session.beginConfiguration()
        session.automaticallyConfiguresApplicationAudioSession = false
        session.sessionPreset = .inputPriority

        if let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
            device = camera
        }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        if let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
            session.addInput(input)
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
                updateState { $0.hasAudio = true }
            }
        }
        session.commitConfiguration()

        if let device { didSelect(device) }
        updateState { $0.cameraCount = Self.cameraCount() }

        NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
            // Media services reset or similar: restart after a beat.
            self?.sessionQueue.asyncAfter(deadline: .now() + 1) {
                guard let self, self.state.isRunning, !self.session.isRunning else { return }
                self.session.startRunning()
            }
        }

        #if targetEnvironment(macCatalyst)
        // Cameras come and go on a Mac (a USB camera, an iPhone within reach): keep the count current.
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.sessionQueue.async { self?.updateState { $0.cameraCount = Self.cameraCount() } }
            }
        }
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// Every camera a Mac can use, built-in first: the FaceTime camera, then Continuity Camera
    /// iPhones and USB cameras. None of them is "front" or "back".
    private static func macCameras() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .continuityCamera, .external]
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        return devices.sorted { a, b in
            let rank = { (d: AVCaptureDevice) in types.firstIndex(of: d.deviceType) ?? types.count }
            return rank(a) < rank(b)
        }
    }

    private static func cameraCount() -> Int { max(1, macCameras().count) }

    private static func bestDevice(front: Bool) -> AVCaptureDevice? { macCameras().first }
    #else
    private static func cameraCount() -> Int { 1 }

    /// Prefer the multi-lens virtual devices so lens changes are seamless zoom changes.
    private static func bestDevice(front: Bool) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = front
            ? [.builtInTrueDepthCamera, .builtInWideAngleCamera]
            : [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: front ? .front : .back).devices
        for type in types {
            if let device = devices.first(where: { $0.deviceType == type }) { return device }
        }
        return nil
    }
    #endif

    private func didSelect(_ device: AVCaptureDevice) {
        let constituents = device.isVirtualDevice ? device.constituentDevices.map(\.deviceType) : [device.deviceType]
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let hasUltraWide = constituents.contains(.builtInUltraWideCamera)
        wideBaseZoom = hasUltraWide ? (switchOvers.first ?? 2) : 1

        var lenses: [LensOption] = []
        if hasUltraWide { lenses.append(LensOption(factor: 0.5)) }
        lenses.append(LensOption(factor: 1))
        if constituents.contains(.builtInTelephotoCamera), let tele = switchOvers.last, tele > wideBaseZoom {
            lenses.append(LensOption(factor: Double((tele / wideBaseZoom).rounded())))
        }

        applyFormat(to: device)
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = wideBaseZoom
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = true }
            device.unlockForConfiguration()
        } catch {
            print("CaptureEngine config: \(error)")
        }

        if let connection = videoOutput.connection(with: .video), connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .off // stabilization adds latency
        }
        observeRotation(of: device)

        updateState {
            $0.lenses = lenses
            $0.zoom = 1
            $0.maxZoom = Double(min(device.maxAvailableVideoZoomFactor, 10 * self.wideBaseZoom) / self.wideBaseZoom)
            $0.torchAvailable = device.hasTorch
            $0.torchOn = false
            $0.usingFrontCamera = device.position == .front
        }
    }

    /// Keeps frames upright for however the phone is propped up.
    private func observeRotation(of device: AVCaptureDevice) {
        rotationObservation = nil
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
            self?.sessionQueue.async {
                guard let connection = self?.videoOutput.connection(with: .video) else { return }
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            }
        }
    }

    /// Smallest 16:9 format that covers the quality preset at its frame rate.
    private func applyFormat(to device: AVCaptureDevice) {
        let target = quality.dimensions
        let fps = Double(flickerSafeFPS(quality.fps))

        func score(_ f: AVCaptureDevice.Format) -> (fits: Bool, area: Int32)? {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard CMFormatDescriptionGetMediaSubType(f.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                  d.width * 9 == d.height * 16 else { return nil }
            let fits = d.width >= target.long && d.height >= target.short
                && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps }
            return (fits, d.width * d.height)
        }
        let candidates = device.formats.compactMap { f in score(f).map { (f, $0) } }
        let chosen = candidates.filter { $0.1.fits }.min { $0.1.area < $1.1.area }?.0
            ?? candidates.max { $0.1.area < $1.1.area }?.0

        do {
            try device.lockForConfiguration()
            if let chosen, device.activeFormat != chosen { device.activeFormat = chosen }
            device.unlockForConfiguration()
        } catch {
            print("CaptureEngine format: \(error)")
        }
        applyExposurePolicy(to: device)
    }

    /// Anti-flicker: under 50 Hz mains, frame rates that are multiples of 25 keep exposure in step
    /// with the lights. Night: allow frames to stretch to 1/15 s so auto-exposure can gather more light.
    private func applyExposurePolicy(to device: AVCaptureDevice) {
        let fps = flickerSafeFPS(quality.fps)
        let supported = device.activeFormat.videoSupportedFrameRateRanges
        let maxSupported = supported.map(\.maxFrameRate).max() ?? 30
        let minSupported = supported.map(\.minFrameRate).min() ?? 1
        let effective = min(Double(fps), maxSupported)
        let night = state.nightActive && nightMode != .off
        let slowest = night ? max(minSupported, mainsHz == 50 ? 12.5 : 15) : effective

        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1000, timescale: CMTimeScale(effective * 1000))
            device.activeVideoMaxFrameDuration = CMTime(value: 1000, timescale: CMTimeScale(slowest * 1000))
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = nightMode != .off
            }
            device.unlockForConfiguration()
        } catch {
            print("CaptureEngine exposure: \(error)")
        }
    }

    private func flickerSafeFPS(_ fps: Int) -> Int {
        guard mainsHz == 50 else { return fps }
        switch fps {
        case 60: return 50
        case 24, 30: return 25
        default: return fps
        }
    }

    // MARK: Frame processing

    fileprivate func handle(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        frameCount += 1
        if frameCount % 15 == 0 { evaluateNight(pixelBuffer) }

        let enhance = state.nightActive && nightEnhance
        let output = processor.process(pixelBuffer, enhance: enhance) ?? pixelBuffer
        lock.withLock { latestFrame = output }
        onFrame?(output, time)
    }

    /// Auto night mode with hysteresis, from frame brightness plus (on real cameras) sensor ISO.
    private func evaluateNight(_ pixelBuffer: CVPixelBuffer) {
        guard nightMode == .auto else { return }
        let luma = FrameProcessor.averageLuma(pixelBuffer)
        var isoRatio = 0.0
        if let device {
            let maxISO = Double(device.activeFormat.maxISO)
            if maxISO > 0 { isoRatio = Double(device.iso) / maxISO }
        }
        let dark = luma < 0.15 || isoRatio > 0.75
        let bright = luma > 0.25 && isoRatio < 0.5
        darkSamples = dark ? darkSamples + 1 : 0
        brightSamples = bright ? brightSamples + 1 : 0

        if !state.nightActive, darkSamples >= 4 {
            updateState { $0.nightActive = true }
            sessionQueue.async { [self] in if let device { applyExposurePolicy(to: device) } }
        } else if state.nightActive, brightSamples >= 4 {
            updateState { $0.nightActive = false }
            sessionQueue.async { [self] in if let device { applyExposurePolicy(to: device) } }
        }
    }

    private func startSynthetic(_ source: SyntheticFrameSource) {
        guard syntheticTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: videoQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            guard let self, let buffer = source.nextFrame(nightActive: self.state.nightActive) else { return }
            self.handle(buffer, time: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        timer.resume()
        syntheticTimer = timer
    }

    private func updateState(_ change: (inout State) -> Void) {
        let (old, new) = lock.withLock { () -> (State, State) in
            let old = _state
            change(&_state)
            return (old, _state)
        }
        if old != new { onStateChange?(new) }
    }
}

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            onAudio?(sampleBuffer)
        } else if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            handle(pixelBuffer, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
    }
}

// MARK: - Frame processing

/// Downscales oversized camera frames to the quality preset and applies the night-vision
/// enhancement (denoise, lift shadows, desaturate) on the GPU.
final class FrameProcessor {
    var targetLongEdge = 1920
    private let context = CIContext(options: [.cacheIntermediates: false, .priorityRequestLow: false])
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolKey: (Int, Int, OSType)?

    func resetNightSampling() {}

    func process(_ input: CVPixelBuffer, enhance: Bool) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(input), h = CVPixelBufferGetHeight(input)
        let long = max(w, h)
        let needsScale = long > targetLongEdge
        guard needsScale || enhance else { return nil }

        let scale = needsScale ? Double(targetLongEdge) / Double(long) : 1
        // Even dimensions keep 4:2:0 encoders happy.
        let outW = Int((Double(w) * scale) / 2) * 2, outH = Int((Double(h) * scale) / 2) * 2
        guard let output = makeBuffer(width: outW, height: outH, format: CVPixelBufferGetPixelFormatType(input)) else { return nil }

        if enhance {
            var image = CIImage(cvPixelBuffer: input)
            if needsScale { image = image.transformed(by: CGAffineTransform(scaleX: CGFloat(outW) / CGFloat(w), y: CGFloat(outH) / CGFloat(h))) }
            image = image
                .applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.03, "inputSharpness": 0.45])
                .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.62])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.45, kCIInputContrastKey: 1.08, kCIInputBrightnessKey: 0.02])
            context.render(image, to: output)
        } else {
            if transfer == nil {
                VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
                if let transfer {
                    VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Trim)
                }
            }
            guard let transfer, VTPixelTransferSessionTransferImage(transfer, from: input, to: output) == noErr else { return nil }
        }
        return output
    }

    private func makeBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        if poolKey.map({ $0 != (width, height, format) }) ?? true {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary, attributes as CFDictionary, &pool)
            poolKey = (width, height, format)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    /// Mean brightness 0...1 from a sparse sample grid (NV12 luma plane or BGRA).
    static func averageLuma(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let isBGRA = format == kCVPixelFormatType_32BGRA
        let plane = isBGRA ? nil : CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
        guard let base = plane ?? CVPixelBufferGetBaseAddress(buffer) else { return 0.5 }
        let width = isBGRA ? CVPixelBufferGetWidth(buffer) : CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = isBGRA ? CVPixelBufferGetHeight(buffer) : CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = isBGRA ? CVPixelBufferGetBytesPerRow(buffer) : CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        var total = 0, count = 0
        for y in Swift.stride(from: height / 20, to: height, by: max(1, height / 10)) {
            for x in Swift.stride(from: width / 20, to: width, by: max(1, width / 16)) {
                if isBGRA {
                    let p = bytes + y * stride + x * 4
                    total += (Int(p[2]) * 299 + Int(p[1]) * 587 + Int(p[0]) * 114) / 1000
                } else {
                    total += Int(bytes[y * stride + x])
                }
                count += 1
            }
        }
        return count == 0 ? 0.5 : Double(total) / Double(count) / 255
    }
}

// MARK: - Simulator test pattern

/// A moving test scene so the simulator (which has no camera) can broadcast, record and
/// trigger motion events end to end.
final class SyntheticFrameSource {
    private let width = 1280, height = 720
    private var pool: CVPixelBufferPool?
    private var tick = 0
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init() {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    }

    func nextFrame(nightActive: Bool) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return nil }
        tick += 1

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        // A "room": wall, floor, window.
        ctx.setFillColor(UIColor(red: 0.20, green: 0.22, blue: 0.26, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(UIColor(red: 0.30, green: 0.25, blue: 0.20, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: 220))
        ctx.setFillColor(UIColor(red: 0.55, green: 0.70, blue: 0.85, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 860, y: 340, width: 260, height: 220))

        // Every ~20 s something walks across the room for ~6 s, which trips motion detection.
        let cycle = tick % 600
        if cycle < 180 {
            let x = CGFloat(cycle) / 180 * CGFloat(width + 200) - 100
            ctx.setFillColor(UIColor(red: 0.93, green: 0.93, blue: 0.49, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: x, y: 540, width: 150, height: 150))
            ctx.fill(CGRect(x: x + 15, y: 160, width: 120, height: 390))
        }

        let text = "MirrorMirror test camera   \(formatter.string(from: Date()))"
        let attributed = NSAttributedString(string: text, attributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 36, weight: .semibold),
            .foregroundColor: UIColor.white,
        ])
        ctx.textPosition = CGPoint(x: 40, y: 40)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
        return buffer
    }
}
