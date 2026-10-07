import AVFoundation

/// Compact voice packets for the Apple Watch path (listen + talk), which can't use WebRTC.
/// 12 kHz mono μ-law: about 12 KB/s, cheap on the watch's CPU, small enough to share the
/// WatchConnectivity link with video. Packet = 1 version byte + μ-law samples.
enum VoiceCodec {
    static let sampleRate: Double = 12_000
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private static let version: UInt8 = 1

    static func encode(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        var data = Data(capacity: Int(buffer.frameLength) + 1)
        data.append(version)
        for i in 0..<Int(buffer.frameLength) {
            data.append(linearToMuLaw(samples[i]))
        }
        return data
    }

    static func decode(_ data: Data) -> AVAudioPCMBuffer? {
        guard data.count > 1, data.first == version,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count - 1)),
              let out = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(data.count - 1)
        data.withUnsafeBytes { raw in
            for i in 1..<raw.count { out[i - 1] = muLawToLinear(raw[i]) }
        }
        return buffer
    }

    // MARK: G.711 μ-law

    private static func linearToMuLaw(_ sample: Float) -> UInt8 {
        let bias: Int32 = 0x84, clip: Int32 = 32635
        var pcm = Int32(max(-1, min(1, sample)) * 32767)
        let sign: Int32 = pcm < 0 ? 0x80 : 0
        if pcm < 0 { pcm = -pcm }
        pcm = min(pcm, clip) + bias
        var exponent: Int32 = 7
        var mask: Int32 = 0x4000
        while exponent > 0 && (pcm & mask) == 0 { exponent -= 1; mask >>= 1 }
        let mantissa = (pcm >> (exponent + 3)) & 0x0F
        return UInt8(truncatingIfNeeded: ~(sign | (exponent << 4) | mantissa))
    }

    private static func muLawToLinear(_ byte: UInt8) -> Float {
        let u = Int32(~byte & 0xFF)
        let sign = u & 0x80, exponent = (u >> 4) & 0x07, mantissa = u & 0x0F
        var magnitude = ((mantissa << 3) + 0x84) << exponent
        magnitude -= 0x84
        return Float(sign != 0 ? -magnitude : magnitude) / 32768
    }
}

/// Turns arbitrary capture buffers into 12 kHz mono packets of ~60 ms.
final class VoicePacketizer {
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var pending = [Float]()
    private let packetFrames = Int(VoiceCodec.sampleRate * 0.06)
    var onPacket: ((Data) -> Void)?

    func append(_ buffer: AVAudioPCMBuffer) {
        if sourceFormat != buffer.format {
            sourceFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: VoiceCodec.format)
        }
        guard let converter else { return }
        let ratio = VoiceCodec.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: VoiceCodec.format, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let samples = out.floatChannelData?[0] else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(out.frameLength)))
        while pending.count >= packetFrames {
            let chunk = Array(pending.prefix(packetFrames))
            pending.removeFirst(packetFrames)
            guard let packetBuffer = AVAudioPCMBuffer(pcmFormat: VoiceCodec.format, frameCapacity: AVAudioFrameCount(chunk.count)) else { continue }
            packetBuffer.frameLength = AVAudioFrameCount(chunk.count)
            chunk.withUnsafeBufferPointer { packetBuffer.floatChannelData![0].update(from: $0.baseAddress!, count: chunk.count) }
            if let data = VoiceCodec.encode(packetBuffer) { onPacket?(data) }
        }
    }

    /// Capture-session audio (camera side).
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return }
        var streamDescription = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else { return }
        append(buffer)
    }
}

/// Plays incoming voice packets with a small jitter buffer.
final class VoicePlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "mm.voice-player")
    private var scheduled = 0
    private var started = false
    /// Packets to collect before starting, so brief link hiccups don't cause gaps (~180 ms).
    private let prebuffer = 3
    private(set) var level: Float = 0

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: VoiceCodec.format)
    }

    func play(_ packet: Data) {
        queue.async { [self] in
            guard let buffer = VoiceCodec.decode(packet) else { return }
            level = Self.rms(buffer)
            if !engine.isRunning {
                do { try engine.start() } catch { return }
            }
            scheduled += 1
            node.scheduleBuffer(buffer) { [weak self] in self?.queue.async { self?.scheduled -= 1 } }
            if !started, scheduled >= prebuffer {
                node.play()
                started = true
            }
            // Fell too far behind (e.g. the link stalled then burst): drop to stay live.
            if scheduled > 12 {
                node.stop()
                scheduled = 0
                started = false
            }
        }
    }

    func stop() {
        queue.async { [self] in
            node.stop()
            engine.stop()
            scheduled = 0
            started = false
            level = 0
        }
    }

    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return min(1, max(0, (20 * log10(max(rms, 1e-6)) + 60) / 60))
    }
}

/// Microphone → voice packets (Apple Watch talk-back).
final class VoiceRecorder {
    private let engine = AVAudioEngine()
    private let packetizer = VoicePacketizer()
    var onPacket: ((Data) -> Void)? {
        get { packetizer.onPacket }
        set { packetizer.onPacket = newValue }
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [packetizer] buffer, _ in
            packetizer.append(buffer)
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
