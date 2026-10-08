import Foundation
import AVFoundation
import LiveKitWebRTC

/// Process-wide WebRTC setup: one factory, one audio session policy, ICE servers.
final class RTCEnvironment {
    static let shared = RTCEnvironment()

    let factory: LKRTCPeerConnectionFactory

    private init() {
        LKRTCInitializeSSL()
        // The AVAudioEngine device module. LiveKit's default module brings up a remote-IO audio
        // unit as soon as the factory exists; the Simulator's audio server routinely stalls that
        // call and CoreAudio aborts the whole process (SIGABRT in AURemoteIO::Initialize).
        factory = LKRTCPeerConnectionFactory(audioDeviceModuleType: .audioEngine,
                                           bypassVoiceProcessing: false,
                                           encoderFactory: LKRTCDefaultVideoEncoderFactory(),
                                           decoderFactory: LKRTCDefaultVideoDecoderFactory(),
                                           audioProcessingModule: nil)
        #if targetEnvironment(simulator)
        // The Simulator has no audio hardware worth the name: opening its input/output units
        // stalls the audio server and CoreAudio aborts the process. Render audio manually there
        // so no hardware unit is ever opened. Real devices are unaffected.
        factory.audioDeviceModule.setManualRenderingMode(true)
        #endif
        let audio = LKRTCAudioSessionConfiguration.webRTC()
        audio.category = AVAudioSession.Category.playAndRecord.rawValue
        audio.mode = AVAudioSession.Mode.videoChat.rawValue
        #if os(tvOS)
        audio.categoryOptions = [.allowAirPlay, .mixWithOthers]
        #else
        audio.categoryOptions = [.defaultToSpeaker, .allowBluetoothHFP, .allowAirPlay, .mixWithOthers]
        #endif
        LKRTCAudioSessionConfiguration.setWebRTC(audio)
    }

    func makeConfiguration() -> LKRTCConfiguration {
        let config = LKRTCConfiguration()
        config.iceServers = ConnectionPreferences.iceServers
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        // We send one complete SDP (non-trickle) so a single mailbox round trip is enough.
        config.continualGatheringPolicy = .gatherOnce
        config.tcpCandidatePolicy = .enabled
        config.keyType = .ECDSA
        return config
    }
}

/// User-tunable network settings (Viewer settings screen). TURN is optional: most home
/// networks connect directly, a relay only helps on strict carrier/corporate NATs.
enum ConnectionPreferences {
    private static let defaults = UserDefaults.standard

    static var turnURL: String {
        get { defaults.string(forKey: "ice.turn.url") ?? "" }
        set { defaults.set(newValue, forKey: "ice.turn.url") }
    }
    static var turnUsername: String {
        get { defaults.string(forKey: "ice.turn.username") ?? "" }
        set { defaults.set(newValue, forKey: "ice.turn.username") }
    }
    static var turnCredential: String {
        get { defaults.string(forKey: "ice.turn.credential") ?? "" }
        set { defaults.set(newValue, forKey: "ice.turn.credential") }
    }

    static var iceServers: [LKRTCIceServer] {
        var servers = [LKRTCIceServer(urlStrings: ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302", "stun:stun.cloudflare.com:3478"])]
        let turn = turnURL.trimmingCharacters(in: .whitespaces)
        if !turn.isEmpty {
            servers.append(LKRTCIceServer(urlStrings: [turn], username: turnUsername, credential: turnCredential))
        }
        return servers
    }
}

/// Snapshot of connection quality, read from WebRTC stats.
struct LinkStats: Equatable {
    var roundTrip: TimeInterval?
    var bitrate: Double?          // bits/s received (viewer) or sent (camera)
    var fps: Double?
    var width: Int?
    var height: Int?
    var framesDecoded: Int?
    /// Audio bytes received from the other side; proves sound is flowing.
    var audioBytesReceived: Int?
    /// Loudness of the incoming audio, 0...1.
    var audioLevel: Double?
    var path: Path = .unknown
    var remoteAddress: String?

    enum Path: String { case unknown, local, direct, relay }

    var pathLabel: String {
        switch path {
        case .unknown: "Connecting"
        case .local: "Local network"
        case .direct: "Direct · P2P"
        case .relay: "Relayed"
        }
    }
}

/// A WebRTC peer connection plus the two data channels the app uses:
/// "control" for JSON messages and "files" for thumbnails, snapshots and exported clips.
final class PeerLink: NSObject {
    let connection: LKRTCPeerConnection
    let control: LKRTCDataChannel
    let files: LKRTCDataChannel
    /// Voice packets for the Apple Watch relay: unordered, no retransmits, latest wins.
    let voice: LKRTCDataChannel

    var onControlMessage: ((Data) -> Void)?
    var onControlOpen: (() -> Void)?
    var onFileMessage: ((LKRTCDataBuffer) -> Void)?
    var onVoicePacket: ((Data) -> Void)?
    var onConnectionState: ((LKRTCPeerConnectionState) -> Void)?
    var onRemoteTrack: ((LKRTCMediaStreamTrack) -> Void)?

    private var lastBytes: (bytes: Double, time: TimeInterval)?

    init?(environment: RTCEnvironment = .shared) {
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
        guard let pc = environment.factory.peerConnection(with: environment.makeConfiguration(), constraints: constraints, delegate: nil) else { return nil }
        connection = pc

        // Pre-negotiated channels: both ends create them with the same IDs, no extra round trip.
        let controlConfig = LKRTCDataChannelConfiguration()
        controlConfig.isNegotiated = true
        controlConfig.channelId = 0
        controlConfig.isOrdered = true
        let filesConfig = LKRTCDataChannelConfiguration()
        filesConfig.isNegotiated = true
        filesConfig.channelId = 1
        filesConfig.isOrdered = true
        let voiceConfig = LKRTCDataChannelConfiguration()
        voiceConfig.isNegotiated = true
        voiceConfig.channelId = 2
        voiceConfig.isOrdered = false
        voiceConfig.maxRetransmits = 0
        guard let control = pc.dataChannel(forLabel: "control", configuration: controlConfig),
              let files = pc.dataChannel(forLabel: "files", configuration: filesConfig),
              let voice = pc.dataChannel(forLabel: "voice", configuration: voiceConfig) else { return nil }
        self.control = control
        self.files = files
        self.voice = voice
        super.init()
        pc.delegate = self
        control.delegate = self
        files.delegate = self
        voice.delegate = self
    }

    // MARK: Handshake

    func makeOffer() async throws -> String {
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let offer = try await connection.offer(for: constraints)
        try await connection.setLocalDescription(offer)
        await waitForGathering()
        return connection.localDescription?.sdp ?? offer.sdp
    }

    /// `attachTracks` runs between applying the offer and creating the answer, so tracks added
    /// there bind to the offerer's transceivers instead of creating new ones.
    func answer(offerSDP: String, attachTracks: () -> Void) async throws -> String {
        try await connection.setRemoteDescription(LKRTCSessionDescription(type: .offer, sdp: offerSDP))
        attachTracks()
        let answer = try await connection.answer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        try await connection.setLocalDescription(answer)
        await waitForGathering()
        return connection.localDescription?.sdp ?? answer.sdp
    }

    /// Offer for a change on an already-connected link (ICE is up, so no gathering wait).
    func renegotiationOffer() async throws -> String {
        let offer = try await connection.offer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        try await connection.setLocalDescription(offer)
        return offer.sdp
    }

    func answerRenegotiation(offerSDP: String) async throws -> String {
        try await connection.setRemoteDescription(LKRTCSessionDescription(type: .offer, sdp: offerSDP))
        let answer = try await connection.answer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        try await connection.setLocalDescription(answer)
        return answer.sdp
    }

    func accept(answerSDP: String) async throws {
        try await connection.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: answerSDP))
    }

    /// Waits until ICE gathering completes (or 3 s, whichever is first) so the SDP carries every
    /// candidate. Polling keeps this cancellable and can't strand a continuation.
    private func waitForGathering() async {
        let deadline = Date().addingTimeInterval(3)
        while connection.iceGatheringState != .complete, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: Messaging

    @discardableResult
    func sendControl(_ data: Data) -> Bool {
        guard control.readyState == .open else { return false }
        return control.sendData(LKRTCDataBuffer(data: data, isBinary: false))
    }

    /// Sends a whole file on the files channel with back-pressure. Call from a background task.
    func sendFile(_ data: Data, header: FileTransferHeader) async -> Bool {
        guard files.readyState == .open, let head = try? JSONEncoder().encode(header) else { return false }
        files.sendData(LKRTCDataBuffer(data: head, isBinary: false))
        let chunk = 16 * 1024
        var offset = 0
        while offset < data.count {
            while files.bufferedAmount > 2 * 1024 * 1024 {
                if files.readyState != .open { return false }
                try? await Task.sleep(for: .milliseconds(15))
            }
            let end = min(offset + chunk, data.count)
            guard files.sendData(LKRTCDataBuffer(data: data.subdata(in: offset..<end), isBinary: true)) else { return false }
            offset = end
        }
        guard let foot = try? JSONEncoder().encode(FileTransferFooter(id: header.id)) else { return false }
        return files.sendData(LKRTCDataBuffer(data: foot, isBinary: false))
    }

    @discardableResult
    func sendVoice(_ packet: Data) -> Bool {
        guard voice.readyState == .open, voice.bufferedAmount < 64 * 1024 else { return false }
        return voice.sendData(LKRTCDataBuffer(data: packet, isBinary: true))
    }

    func close() {
        voice.close()
        control.close()
        files.close()
        connection.close()
    }

    // MARK: Stats

    /// True when two host candidates are on the same network: a private address, or IPv6
    /// addresses sharing a /64 prefix (home networks hand every device a global IPv6 address).
    static func isSameNetwork(_ local: String, _ remote: String) -> Bool {
        if isPrivate(remote) { return true }
        guard local.contains(":"), remote.contains(":") else { return false }
        func prefix(_ a: String) -> [String] {
            let expanded = a.lowercased().replacingOccurrences(of: "::", with: ":0:")
            return Array(expanded.split(separator: ":", omittingEmptySubsequences: false).prefix(4).map(String.init))
        }
        return prefix(local) == prefix(remote)
    }

    /// RFC 1918 / link-local / unique-local addresses, i.e. not routable on the internet.
    static func isPrivate(_ address: String) -> Bool {
        let a = address.lowercased()
        if a.contains(":") {
            return a.hasPrefix("fe80") || a.hasPrefix("fc") || a.hasPrefix("fd")
        }
        let parts = a.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return a.hasSuffix(".local") }
        switch (parts[0], parts[1]) {
        case (10, _), (192, 168), (169, 254), (127, _): return true
        case (172, 16...31): return true
        case (100, 64...127): return false   // carrier-grade NAT: not the same home network
        default: return false
        }
    }

    /// - Parameter inbound: true on the viewer (measure received video), false on the camera.
    func stats(inbound: Bool) async -> LinkStats {
        let report = await withCheckedContinuation { c in connection.statistics { c.resume(returning: $0) } }
        var stats = LinkStats()
        var localCandidateID: String?
        var remoteCandidateID: String?
        var bytes: Double?

        for (_, s) in report.statistics {
            let v = s.values
            switch s.type {
            case "inbound-rtp" where (v["kind"] as? String) == "audio":
                stats.audioBytesReceived = (v["bytesReceived"] as? NSNumber)?.intValue
                stats.audioLevel = (v["audioLevel"] as? NSNumber)?.doubleValue
            case inbound ? "inbound-rtp" : "outbound-rtp":
                guard (v["kind"] as? String) == "video" else { continue }
                stats.framesDecoded = (v[inbound ? "framesDecoded" : "framesEncoded"] as? NSNumber)?.intValue
                bytes = (v[inbound ? "bytesReceived" : "bytesSent"] as? NSNumber)?.doubleValue
                stats.fps = (v["framesPerSecond"] as? NSNumber)?.doubleValue
                stats.width = (v["frameWidth"] as? NSNumber)?.intValue
                stats.height = (v["frameHeight"] as? NSNumber)?.intValue
            case "candidate-pair":
                guard (v["nominated"] as? NSNumber)?.boolValue == true, (v["state"] as? String) == "succeeded" else { continue }
                stats.roundTrip = (v["currentRoundTripTime"] as? NSNumber)?.doubleValue
                localCandidateID = v["localCandidateId"] as? String
                remoteCandidateID = v["remoteCandidateId"] as? String
            default:
                break
            }
        }

        func candidate(_ id: String?) -> [String: NSObject]? { id.flatMap { report.statistics[$0]?.values } }
        let local = candidate(localCandidateID), remote = candidate(remoteCandidateID)
        let types = [local?["candidateType"] as? String, remote?["candidateType"] as? String]
        let remoteAddress = (remote?["address"] as? String) ?? (remote?["ip"] as? String) ?? ""
        let localAddress = (local?["address"] as? String) ?? (local?["ip"] as? String) ?? ""
        stats.remoteAddress = remoteAddress
        if types.contains("relay") {
            stats.path = .relay
        } else if types.allSatisfy({ $0 == "host" }) && Self.isSameNetwork(localAddress, remoteAddress) {
            // Host-to-host only means "same network" when the address is private; public IPv6
            // host candidates connect phones on cellular directly across the internet.
            stats.path = .local
        } else if types.contains(where: { $0 != nil }) {
            stats.path = .direct
        }

        let now = Date().timeIntervalSince1970
        if let bytes {
            if let last = lastBytes, now > last.time, bytes >= last.bytes {
                stats.bitrate = (bytes - last.bytes) * 8 / (now - last.time)
            }
            lastBytes = (bytes, now)
        }
        return stats
    }
}

extension PeerLink: LKRTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        onConnectionState?(newState)
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd rtpReceiver: LKRTCRtpReceiver, streams mediaStreams: [LKRTCMediaStream]) {
        if let track = rtpReceiver.track { onRemoteTrack?(track) }
    }
}

extension PeerLink: LKRTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        if dataChannel === control, dataChannel.readyState == .open { onControlOpen?() }
    }

    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        if dataChannel === control {
            onControlMessage?(buffer.data)
        } else if dataChannel === voice {
            onVoicePacket?(buffer.data)
        } else {
            onFileMessage?(buffer)
        }
    }
}

/// Feeds CVPixelBuffers into a WebRTC video source (one per connected viewer).
final class FrameInjector {
    let source: LKRTCVideoSource
    let track: LKRTCVideoTrack
    private let capturer: LKRTCVideoCapturer

    init(environment: RTCEnvironment = .shared, trackID: String) {
        source = environment.factory.videoSource()
        capturer = LKRTCVideoCapturer(delegate: source)
        track = environment.factory.videoTrack(with: source, trackId: trackID)
    }

    func push(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        let frame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: pixelBuffer),
                                  rotation: ._0,
                                  timeStampNs: Int64(CMTimeGetSeconds(time) * 1_000_000_000))
        source.capturer(capturer, didCapture: frame)
    }

    func adapt(to preset: QualityPreset, portrait: Bool) {
        let d = preset.dimensions
        source.adaptOutputFormat(toWidth: Int32(portrait ? d.short : d.long),
                                 height: Int32(portrait ? d.long : d.short),
                                 fps: Int32(preset.fps))
    }
}
