import Foundation
import AVFoundation
import WebRTC

/// Process-wide WebRTC setup: one factory, one audio session policy, ICE servers.
final class RTCEnvironment {
    static let shared = RTCEnvironment()

    let factory: RTCPeerConnectionFactory

    private init() {
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                           decoderFactory: RTCDefaultVideoDecoderFactory())
        let audio = RTCAudioSessionConfiguration.webRTC()
        audio.category = AVAudioSession.Category.playAndRecord.rawValue
        audio.mode = AVAudioSession.Mode.videoChat.rawValue
        audio.categoryOptions = [.defaultToSpeaker, .allowBluetoothHFP, .allowAirPlay, .mixWithOthers]
        RTCAudioSessionConfiguration.setWebRTC(audio)
    }

    func makeConfiguration() -> RTCConfiguration {
        let config = RTCConfiguration()
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

    static var iceServers: [RTCIceServer] {
        var servers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302", "stun:stun.cloudflare.com:3478"])]
        let turn = turnURL.trimmingCharacters(in: .whitespaces)
        if !turn.isEmpty {
            servers.append(RTCIceServer(urlStrings: [turn], username: turnUsername, credential: turnCredential))
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
    var path: Path = .unknown

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
    let connection: RTCPeerConnection
    let control: RTCDataChannel
    let files: RTCDataChannel

    var onControlMessage: ((Data) -> Void)?
    var onControlOpen: (() -> Void)?
    var onFileMessage: ((RTCDataBuffer) -> Void)?
    var onConnectionState: ((RTCPeerConnectionState) -> Void)?
    var onRemoteTrack: ((RTCMediaStreamTrack) -> Void)?

    private var gatheringWaiters: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()
    private var lastBytes: (bytes: Double, time: TimeInterval)?

    init?(environment: RTCEnvironment = .shared) {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
        guard let pc = environment.factory.peerConnection(with: environment.makeConfiguration(), constraints: constraints, delegate: nil) else { return nil }
        connection = pc

        // Pre-negotiated channels: both ends create them with the same IDs, no extra round trip.
        let controlConfig = RTCDataChannelConfiguration()
        controlConfig.isNegotiated = true
        controlConfig.channelId = 0
        controlConfig.isOrdered = true
        let filesConfig = RTCDataChannelConfiguration()
        filesConfig.isNegotiated = true
        filesConfig.channelId = 1
        filesConfig.isOrdered = true
        guard let control = pc.dataChannel(forLabel: "control", configuration: controlConfig),
              let files = pc.dataChannel(forLabel: "files", configuration: filesConfig) else { return nil }
        self.control = control
        self.files = files
        super.init()
        pc.delegate = self
        control.delegate = self
        files.delegate = self
    }

    // MARK: Handshake

    func makeOffer() async throws -> String {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let offer = try await connection.offer(for: constraints)
        try await connection.setLocalDescription(offer)
        await waitForGathering()
        return connection.localDescription?.sdp ?? offer.sdp
    }

    /// `attachTracks` runs between applying the offer and creating the answer, so tracks added
    /// there bind to the offerer's transceivers instead of creating new ones.
    func answer(offerSDP: String, attachTracks: () -> Void) async throws -> String {
        try await connection.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: offerSDP))
        attachTracks()
        let answer = try await connection.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        try await connection.setLocalDescription(answer)
        await waitForGathering()
        return connection.localDescription?.sdp ?? answer.sdp
    }

    func accept(answerSDP: String) async throws {
        try await connection.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answerSDP))
    }

    /// Waits until ICE gathering completes (or 3 s, whichever is first) so the SDP carries every candidate.
    private func waitForGathering() async {
        if connection.iceGatheringState == .complete { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { c in
                    self.lock.lock()
                    if self.connection.iceGatheringState == .complete {
                        self.lock.unlock()
                        c.resume()
                    } else {
                        self.gatheringWaiters.append(c)
                        self.lock.unlock()
                    }
                }
            }
            group.addTask { try? await Task.sleep(for: .seconds(3)) }
            await group.next()
            group.cancelAll()
        }
        // If the timeout won, resume the waiter so it doesn't leak.
        flushGatheringWaiters()
    }

    private func flushGatheringWaiters() {
        lock.lock()
        let waiters = gatheringWaiters
        gatheringWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    // MARK: Messaging

    @discardableResult
    func sendControl(_ data: Data) -> Bool {
        guard control.readyState == .open else { return false }
        return control.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    /// Sends a whole file on the files channel with back-pressure. Call from a background task.
    func sendFile(_ data: Data, header: FileTransferHeader) async -> Bool {
        guard files.readyState == .open, let head = try? JSONEncoder().encode(header) else { return false }
        files.sendData(RTCDataBuffer(data: head, isBinary: false))
        let chunk = 16 * 1024
        var offset = 0
        while offset < data.count {
            while files.bufferedAmount > 2 * 1024 * 1024 {
                if files.readyState != .open { return false }
                try? await Task.sleep(for: .milliseconds(15))
            }
            let end = min(offset + chunk, data.count)
            guard files.sendData(RTCDataBuffer(data: data.subdata(in: offset..<end), isBinary: true)) else { return false }
            offset = end
        }
        guard let foot = try? JSONEncoder().encode(FileTransferFooter(id: header.id)) else { return false }
        return files.sendData(RTCDataBuffer(data: foot, isBinary: false))
    }

    func close() {
        flushGatheringWaiters()
        control.close()
        files.close()
        connection.close()
    }

    // MARK: Stats

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
            case inbound ? "inbound-rtp" : "outbound-rtp":
                guard (v["kind"] as? String) == "video" else { continue }
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

        func candidateType(_ id: String?) -> String? {
            id.flatMap { report.statistics[$0]?.values["candidateType"] as? String }
        }
        let types = [candidateType(localCandidateID), candidateType(remoteCandidateID)]
        if types.contains("relay") {
            stats.path = .relay
        } else if types.allSatisfy({ $0 == "host" }) {
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

extension PeerLink: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { flushGatheringWaiters() }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        onConnectionState?(newState)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        if let track = rtpReceiver.track { onRemoteTrack?(track) }
    }
}

extension PeerLink: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel === control, dataChannel.readyState == .open { onControlOpen?() }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        if dataChannel === control {
            onControlMessage?(buffer.data)
        } else {
            onFileMessage?(buffer)
        }
    }
}

/// Feeds CVPixelBuffers into a WebRTC video source (one per connected viewer).
final class FrameInjector {
    let source: RTCVideoSource
    let track: RTCVideoTrack
    private let capturer: RTCVideoCapturer

    init(environment: RTCEnvironment = .shared, trackID: String) {
        source = environment.factory.videoSource()
        capturer = RTCVideoCapturer(delegate: source)
        track = environment.factory.videoTrack(with: source, trackId: trackID)
    }

    func push(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
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
