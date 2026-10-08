import Foundation
import CoreMedia
import CoreVideo
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Vision
import os

/// Something a detector noticed. Shared by `MotionDetector` and `SoundDetector`.
struct DetectionResult {
    var kind: EventKind
    var label: String
    var confidence: Double
    /// Small JPEG (about 320 px wide) of the frame that triggered the event. Always nil for sound.
    var snapshotJPEG: Data?
}

/// Frame-differencing motion detector with optional Vision person/animal classification.
///
/// `process(pixelBuffer:time:)` is cheap: it samples at most ~5 frames a second and hands
/// them to a private serial queue, dropping frames while an analysis is still running.
/// Settings and `activityLevel` are safe to touch from any thread.
final class MotionDetector: @unchecked Sendable {

    // MARK: Settings (thread-safe)

    var isEnabled: Bool {
        get { lock.withLock { _isEnabled } }
        set {
            let wasEnabled = lock.withLock {
                let old = _isEnabled
                _isEnabled = newValue
                if !newValue { _activityLevel = 0 }
                return old
            }
            // The scene may have changed while we weren't looking; start from a fresh background.
            if newValue && !wasEnabled { reset() }
        }
    }

    /// 0...1. Higher triggers on smaller motion.
    var sensitivity: Double {
        get { lock.withLock { _sensitivity } }
        set { lock.withLock { _sensitivity = min(max(newValue, 0), 1) } }
    }

    var detectPeopleAndPets: Bool {
        get { lock.withLock { _detectPeopleAndPets } }
        set { lock.withLock { _detectPeopleAndPets = newValue } }
    }

    /// Called on the detector's private queue.
    var onEvent: ((DetectionResult) -> Void)? {
        get { lock.withLock { _onEvent } }
        set { lock.withLock { _onEvent = newValue } }
    }

    /// Latest motion score for a UI meter, 0...1. The event threshold sits at 0.5.
    var activityLevel: Double { lock.withLock { _activityLevel } }

    // MARK: Tuning

    private static let analysisInterval = 0.2           // ~5 analyses per second
    private static let cooldown: TimeInterval = 20      // per kind
    private static let visionInterval: TimeInterval = 1 // Vision runs at most once a second
    private static let requiredConsecutiveHits = 2
    private static let lightingChangeFraction = 0.7
    private static let gridLongSide = 80
    private static let gridShortSide = 60
    private static let samplesPerCellAxis = 4
    private static let snapshotWidth: CGFloat = 320
    private static let personConfidence: Float = 0.5
    private static let animalConfidence: Float = 0.5

    /// Per-cell luma difference (0...255) that counts as "changed".
    private static func cellThreshold(_ sensitivity: Double) -> Float {
        Float(40 - 28 * sensitivity)                    // 40 … 12
    }

    /// Fraction of changed cells needed for a motion candidate.
    private static func motionThreshold(_ sensitivity: Double) -> Double {
        0.10 * pow(0.05, sensitivity)                   // 10% … 0.5% (≈2.2% at 0.5)
    }

    // MARK: Lock-protected state

    private let lock = NSLock()
    private var _isEnabled = true
    private var _sensitivity = 0.5
    private var _detectPeopleAndPets = true
    private var _onEvent: ((DetectionResult) -> Void)?
    private var _activityLevel = 0.0
    private var lastAnalysisTime: Double?
    private var isAnalysing = false

    // MARK: Analysis-queue state

    private let queue = DispatchQueue(label: "Mira.MotionDetector", qos: .utility)
    private var background: [Float] = []
    private var gridWidth = 0
    private var gridHeight = 0
    private var consecutiveHits = 0
    private var lastEventAt: [EventKind: TimeInterval] = [:]
    private var lastVisionAt: TimeInterval = -.infinity
    private var loggedUnsupportedFormat = false
    private var loggedVisionError = false
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let logger = Logger(subsystem: "Mira", category: "MotionDetector")

    init() {}

    // MARK: Public API

    /// Call for every captured frame. Returns immediately.
    func process(pixelBuffer: CVPixelBuffer, time: CMTime) {
        let seconds = time.isNumeric ? time.seconds : ProcessInfo.processInfo.systemUptime
        let settings: (sensitivity: Double, detectPeopleAndPets: Bool)? = lock.withLock {
            guard _isEnabled, !isAnalysing else { return nil }
            // A backwards jump means the clock restarted (e.g. new session); analyse right away.
            if let last = lastAnalysisTime, seconds >= last, seconds - last < Self.analysisInterval {
                return nil
            }
            lastAnalysisTime = seconds
            isAnalysing = true
            return (_sensitivity, _detectPeopleAndPets)
        }
        guard let settings else { return }

        // The closure keeps the pixel buffer alive only until the analysis finishes. Nothing else
        // touches it meanwhile, so handing it across queues is safe.
        nonisolated(unsafe) let frame = pixelBuffer
        queue.async { [self] in
            analyse(frame, sensitivity: settings.sensitivity, detectPeopleAndPets: settings.detectPeopleAndPets)
            lock.withLock { isAnalysing = false }
        }
    }

    /// Forgets the background model, e.g. after switching cameras.
    func reset() {
        lock.withLock {
            lastAnalysisTime = nil
            _activityLevel = 0
        }
        queue.async { [self] in
            background = []
            gridWidth = 0
            gridHeight = 0
            consecutiveHits = 0
        }
    }

    // MARK: Analysis

    private func analyse(_ pixelBuffer: CVPixelBuffer, sensitivity: Double, detectPeopleAndPets: Bool) {
        guard let grid = downsampledLuma(pixelBuffer) else { return }

        if grid.width != gridWidth || grid.height != gridHeight || background.count != grid.values.count {
            seedBackground(grid)
            return
        }

        let current = grid.values
        let count = current.count

        // Cancel out global exposure drift so auto exposure doesn't read as motion.
        var currentSum: Float = 0
        var backgroundSum: Float = 0
        for i in 0..<count {
            currentSum += current[i]
            backgroundSum += background[i]
        }
        let exposureShift = (currentSum - backgroundSum) / Float(count)

        let cellThreshold = Self.cellThreshold(sensitivity)
        var changed = 0
        for i in 0..<count where abs(current[i] - exposureShift - background[i]) > cellThreshold {
            changed += 1
        }
        let fraction = Double(changed) / Double(count)

        if fraction > Self.lightingChangeFraction {
            // Lights switched on/off or the camera re-exposed: not motion.
            seedBackground(grid)
            return
        }

        // Changed cells blend in slowly so someone standing still isn't absorbed immediately.
        for i in 0..<count {
            let diff = current[i] - background[i]
            let rate: Float = abs(diff - exposureShift) > cellThreshold ? 0.02 : 0.1
            background[i] += rate * diff
        }

        let threshold = Self.motionThreshold(sensitivity)
        let activity = min(1, fraction / (2 * threshold))
        lock.withLock { _activityLevel = activity }

        guard fraction > threshold else {
            consecutiveHits = 0
            return
        }
        consecutiveHits += 1
        guard consecutiveHits >= Self.requiredConsecutiveHits else { return }

        let now = ProcessInfo.processInfo.systemUptime
        var detection = (kind: EventKind.motion, label: "Motion detected", confidence: activity)

        if detectPeopleAndPets && (isReady(.person, at: now) || isReady(.animal, at: now)) {
            // Wait for Vision rather than reporting plain motion that might be a person.
            guard now - lastVisionAt >= Self.visionInterval else { return }
            lastVisionAt = now
            if let found = classify(pixelBuffer) { detection = found }
        }

        guard isReady(detection.kind, at: now) else { return }
        lastEventAt[detection.kind] = now
        // A person or pet event already covers the motion that caused it.
        if detection.kind != .motion { lastEventAt[.motion] = now }

        let result = DetectionResult(
            kind: detection.kind,
            label: detection.label,
            confidence: detection.confidence,
            snapshotJPEG: snapshot(pixelBuffer)
        )
        onEvent?(result)
    }

    private func seedBackground(_ grid: LumaGrid) {
        background = grid.values
        gridWidth = grid.width
        gridHeight = grid.height
        consecutiveHits = 0
        lock.withLock { _activityLevel = 0 }
    }

    private func isReady(_ kind: EventKind, at now: TimeInterval) -> Bool {
        guard let last = lastEventAt[kind] else { return true }
        return now - last >= Self.cooldown
    }

    // MARK: Downsampling

    private struct LumaGrid {
        var width: Int
        var height: Int
        var values: [Float]
    }

    /// Averages a few luma samples per cell into a small grid whose orientation follows the frame's.
    private func downsampledLuma(_ buffer: CVPixelBuffer) -> LumaGrid? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let isBiPlanar = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard isBiPlanar || format == kCVPixelFormatType_32BGRA else {
            if !loggedUnsupportedFormat {
                loggedUnsupportedFormat = true
                logger.error("Unsupported pixel format \(format, privacy: .public); motion detection is off")
            }
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let baseAddress: UnsafeMutableRawPointer?
        let width: Int
        let height: Int
        let bytesPerRow: Int
        if isBiPlanar {
            baseAddress = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
            width = CVPixelBufferGetWidthOfPlane(buffer, 0)
            height = CVPixelBufferGetHeightOfPlane(buffer, 0)
            bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        } else {
            baseAddress = CVPixelBufferGetBaseAddress(buffer)
            width = CVPixelBufferGetWidth(buffer)
            height = CVPixelBufferGetHeight(buffer)
            bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        }

        let (gridWidth, gridHeight) = width >= height
            ? (Self.gridLongSide, Self.gridShortSide)
            : (Self.gridShortSide, Self.gridLongSide)
        guard let baseAddress, width >= gridWidth, height >= gridHeight else { return nil }

        let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)
        let samples = Self.samplesPerCellAxis
        let samplesPerCell = Float(samples * samples)
        var values = [Float](repeating: 0, count: gridWidth * gridHeight)

        for gy in 0..<gridHeight {
            let y0 = gy * height / gridHeight
            let cellHeight = (gy + 1) * height / gridHeight - y0
            for gx in 0..<gridWidth {
                let x0 = gx * width / gridWidth
                let cellWidth = (gx + 1) * width / gridWidth - x0
                var sum = 0
                for sy in 0..<samples {
                    // Sample at the centres of an evenly spaced sub-grid inside the cell.
                    let row = pixels + (y0 + cellHeight * (2 * sy + 1) / (2 * samples)) * bytesPerRow
                    for sx in 0..<samples {
                        let x = x0 + cellWidth * (2 * sx + 1) / (2 * samples)
                        if isBiPlanar {
                            sum += Int(row[x])
                        } else {
                            let p = row + x * 4   // B, G, R, A
                            sum += (29 * Int(p[0]) + 150 * Int(p[1]) + 77 * Int(p[2])) >> 8
                        }
                    }
                }
                values[gy * gridWidth + gx] = Float(sum) / samplesPerCell
            }
        }
        return LumaGrid(width: gridWidth, height: gridHeight, values: values)
    }

    // MARK: Vision

    private func classify(_ pixelBuffer: CVPixelBuffer) -> (kind: EventKind, label: String, confidence: Double)? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        // Perform separately so one unavailable model doesn't take the other down with it.
        if perform(humans, with: handler),
           let best = humans.results?.max(by: { $0.confidence < $1.confidence }),
           best.confidence > Self.personConfidence {
            return (.person, "Person detected", Double(best.confidence))
        }

        let animals = VNRecognizeAnimalsRequest()
        guard perform(animals, with: handler) else { return nil }
        var bestAnimal: (name: String, confidence: Float)?
        for observation in animals.results ?? [] {
            for label in observation.labels where label.confidence > Self.animalConfidence {
                let name: String
                switch label.identifier {
                case VNAnimalIdentifier.cat.rawValue: name = "Cat"
                case VNAnimalIdentifier.dog.rawValue: name = "Dog"
                default: continue
                }
                if label.confidence > bestAnimal?.confidence ?? 0 {
                    bestAnimal = (name, label.confidence)
                }
            }
        }
        if let bestAnimal {
            return (.animal, "\(bestAnimal.name) detected", Double(bestAnimal.confidence))
        }
        return nil
    }

    private func perform(_ request: VNRequest, with handler: VNImageRequestHandler) -> Bool {
        do {
            try handler.perform([request])
            return true
        } catch {
            if !loggedVisionError {
                loggedVisionError = true
                logger.error("Vision request failed, falling back to plain motion: \(error.localizedDescription, privacy: .public)")
            }
            return false
        }
    }

    // MARK: Snapshot

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private func snapshot(_ pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard image.extent.width > 0 else { return nil }

        let scaleFilter = CIFilter.lanczosScaleTransform()
        scaleFilter.inputImage = image
        scaleFilter.scale = Float(min(1, Self.snapshotWidth / image.extent.width))
        scaleFilter.aspectRatio = 1
        guard let scaled = scaleFilter.outputImage else { return nil }

        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return ciContext.jpegRepresentation(of: scaled, colorSpace: Self.sRGB, options: [quality: 0.6])
    }
}
