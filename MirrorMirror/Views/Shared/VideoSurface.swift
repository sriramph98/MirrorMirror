import AVFoundation
import AVKit
import SwiftUI
import WebRTC

/// A UIView backed by AVSampleBufferDisplayLayer. Used for the camera's own preview and for
/// remote streams; the same layer drives Picture in Picture on the viewer.
final class VideoSurfaceView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Fans decoded or captured frames out to whichever surfaces are currently on screen,
/// and remembers the latest frame for snapshots. Safe to feed from any thread.
final class FrameSink: NSObject {
    private let lock = NSLock()
    private var surfaces: [ObjectIdentifier: WeakSurface] = [:]
    private var formatDescription: CMVideoFormatDescription?
    private(set) var latestFrame: CVPixelBuffer?
    private(set) var lastFrameDate: Date?
    /// Called (any thread) when the size of incoming frames changes.
    var onSizeChange: ((CGSize) -> Void)?
    private var lastSize: CGSize = .zero

    private struct WeakSurface { weak var view: VideoSurfaceView? }

    func attach(_ view: VideoSurfaceView) {
        lock.withLock { surfaces[ObjectIdentifier(view)] = WeakSurface(view: view) }
        if let latestFrame { enqueue(latestFrame, to: [view]) }
    }

    func detach(_ view: VideoSurfaceView) {
        _ = lock.withLock { surfaces.removeValue(forKey: ObjectIdentifier(view)) }
    }

    func clear() {
        lock.withLock {
            latestFrame = nil
            lastFrameDate = nil
        }
        let views = lock.withLock { surfaces.values.compactMap(\.view) }
        DispatchQueue.main.async { views.forEach { $0.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true) {} } }
    }

    func push(_ pixelBuffer: CVPixelBuffer) {
        let views = lock.withLock { () -> [VideoSurfaceView] in
            latestFrame = pixelBuffer
            lastFrameDate = Date()
            return surfaces.values.compactMap(\.view)
        }
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        if size != lastSize {
            lastSize = size
            onSizeChange?(size)
        }
        enqueue(pixelBuffer, to: views)
    }

    private func enqueue(_ pixelBuffer: CVPixelBuffer, to views: [VideoSurfaceView]) {
        guard !views.isEmpty, let sample = makeSampleBuffer(pixelBuffer) else { return }
        for view in views {
            let renderer = view.displayLayer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            if renderer.isReadyForMoreMediaData { renderer.enqueue(sample) }
        }
    }

    private func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }
        if formatDescription.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixelBuffer) }) ?? true {
            formatDescription = nil
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription)
        }
        guard let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: formatDescription,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        if let sample, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sample
    }

    func snapshotJPEG(quality: CGFloat = 0.9) -> Data? {
        guard let frame = lock.withLock({ latestFrame }) else { return nil }
        return CIContext().jpegRepresentation(of: CIImage(cvPixelBuffer: frame), colorSpace: CGColorSpaceCreateDeviceRGB(),
                                             options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
    }
}

/// Converts incoming WebRTC frames to CVPixelBuffers for a FrameSink.
final class RemoteVideoRenderer: NSObject, RTCVideoRenderer {
    let sink: FrameSink
    private var nv12Pool: CVPixelBufferPool?
    private var poolSize: (Int32, Int32) = (0, 0)

    init(sink: FrameSink) { self.sink = sink }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        if let buffer = frame.buffer as? RTCCVPixelBuffer {
            sink.push(buffer.pixelBuffer)
        } else if let converted = convertToNV12(frame.buffer.toI420()) {
            sink.push(converted)
        }
    }

    /// Software decoders hand us I420; the display layer wants a CVPixelBuffer.
    private func convertToNV12(_ i420: RTCI420BufferProtocol) -> CVPixelBuffer? {
        let w = i420.width, h = i420.height
        if poolSize != (w, h) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey as String: Int(w),
                kCVPixelBufferHeightKey as String: Int(h),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            nv12Pool = nil
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &nv12Pool)
            poolSize = (w, h)
        }
        guard let nv12Pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, nv12Pool, &out)
        guard let out else { return nil }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        guard let yDst = CVPixelBufferGetBaseAddressOfPlane(out, 0)?.assumingMemoryBound(to: UInt8.self),
              let uvDst = CVPixelBufferGetBaseAddressOfPlane(out, 1)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(out, 0), uvStride = CVPixelBufferGetBytesPerRowOfPlane(out, 1)
        for row in 0..<Int(h) {
            memcpy(yDst + row * yStride, i420.dataY + row * Int(i420.strideY), Int(w))
        }
        for row in 0..<Int(i420.chromaHeight) {
            let u = i420.dataU + row * Int(i420.strideU), v = i420.dataV + row * Int(i420.strideV)
            let dst = uvDst + row * uvStride
            for col in 0..<Int(i420.chromaWidth) {
                dst[col * 2] = u[col]
                dst[col * 2 + 1] = v[col]
            }
        }
        return out
    }
}

/// SwiftUI wrapper. `onSurface` hands back the view so callers can attach PiP.
struct VideoSurface: UIViewRepresentable {
    let sink: FrameSink
    var fill = false
    var onSurface: ((VideoSurfaceView) -> Void)? = nil

    func makeUIView(context: Context) -> VideoSurfaceView {
        let view = VideoSurfaceView()
        sink.attach(view)
        onSurface?(view)
        return view
    }

    func updateUIView(_ view: VideoSurfaceView, context: Context) {
        view.displayLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }

    static func dismantleUIView(_ view: VideoSurfaceView, coordinator: ()) {
        // The sink holds surfaces weakly, so nothing to do; flush to free the last frame.
        view.displayLayer.sampleBufferRenderer.flush()
    }
}
