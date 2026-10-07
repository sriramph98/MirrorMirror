import Combine
import CoreImage
import UIKit
import WatchConnectivity

/// The iPhone half of the Apple Watch viewer. The watch can't run WebRTC, so the iPhone
/// connects to the camera as usual and forwards a small JPEG stream, the camera's audio and
/// the watch wearer's voice over WatchConnectivity (Apple's encrypted paired-device link).
@MainActor
final class WatchRelay: NSObject {
    static let shared = WatchRelay()

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }
    private var cancellables = Set<AnyCancellable>()
    private var connection: CameraConnection?
    /// True when the relay opened the connection itself (so it should close it again).
    private var ownsConnection = false
    private var frameTask: Task<Void, Never>?
    private var lastPing = Date.distantPast
    private var listening = true
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    func activate() {
        guard let session, session.delegate == nil else { return }
        session.delegate = self
        session.activate()
        ViewerHub.shared.$cameras
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.publishCameras() }
            .store(in: &cancellables)
    }

    /// Cameras and their keys go to the watch over the paired-device link, never iCloud.
    private func publishCameras() {
        guard let session, session.activationState == .activated else { return }
        guard session.isPaired, session.isWatchAppInstalled else {
            DebugSupport.log("watch", "not sending cameras: paired=\(session.isPaired) installed=\(session.isWatchAppInstalled)")
            return
        }
        let cameras = ViewerHub.shared.cameras.map { WatchCamera(id: $0.id, name: $0.name, key: $0.key) }
        guard let data = try? JSONEncoder().encode(cameras) else { return }
        do {
            try session.updateApplicationContext([WatchLink.camerasKey: data])
            DebugSupport.log("watch", "sent \(cameras.count) camera(s) to the watch")
        } catch {
            DebugSupport.log("watch", "context update failed: \(error)")
        }
    }

    // MARK: Requests

    private func handle(_ request: WatchRequest) -> WatchReply {
        switch request {
        case let .watch(cameraID, listen):
            guard let camera = ViewerHub.shared.camera(id: cameraID) else {
                return WatchReply(ok: false, message: "That camera isn't on this iPhone any more.")
            }
            start(camera, listen: listen)
        case let .listen(on):
            listening = on
            connection?.relayVoice(on)
        case let .talk(on):
            connection?.relayTalk(on)
        case .ping:
            lastPing = Date()
        case .stop:
            stop()
        }
        return WatchReply(ok: true)
    }

    private func start(_ camera: PairedCamera, listen: Bool) {
        lastPing = Date()
        listening = listen
        if connection?.id == camera.id {
            connection?.relayVoice(listen)
            return
        }
        stop()
        let hub = ViewerHub.shared
        let connection = hub.connection(for: camera)
        self.connection = connection
        ownsConnection = connection.phase == .idle || {
            if case .failed = connection.phase { return true }
            return false
        }()
        connection.watchRelayActive = true
        connection.onRelayVoicePacket = { [weak self] packet in
            self?.send(.voice, packet)
        }
        connection.connect()
        DebugSupport.log("watch", "relaying \(camera.name) (listen=\(listen))")

        frameTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self, let connection = self.connection else { return }
                if Date().timeIntervalSince(self.lastPing) > 20 {
                    DebugSupport.log("watch", "watch went quiet; stopping relay")
                    self.stop()
                    return
                }
                if connection.phase == .connected {
                    if tick == 0 || !connection.voiceRelayRequested { connection.relayVoice(self.listening) }
                    if let jpeg = self.encodeFrame(connection.sink.latestFrame) { self.send(.frame, jpeg) }
                }
                if tick % 12 == 0 { self.sendStatus(connection) }
                tick += 1
                try? await Task.sleep(for: .milliseconds(160))   // ~6 fps keeps the watch link comfortable
            }
        }
    }

    private func stop() {
        frameTask?.cancel()
        frameTask = nil
        guard let connection else { return }
        connection.relayVoice(false)
        connection.relayTalk(false)
        connection.watchRelayActive = false
        connection.onRelayVoicePacket = nil
        if ownsConnection { connection.disconnect() }
        self.connection = nil
    }

    // MARK: Sending

    private func encodeFrame(_ buffer: CVPixelBuffer?) -> Data? {
        guard let buffer else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = 320 / max(image.extent.width, image.extent.height)
        return ciContext.jpegRepresentation(of: image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
                                            colorSpace: CGColorSpaceCreateDeviceRGB(),
                                            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.45])
    }

    private func sendStatus(_ connection: CameraConnection) {
        let phase: WatchLiveStatus.Phase
        var detail: String?
        switch connection.phase {
        case .connected: phase = connection.playback.isLive ? .live : .playback
        case let .connecting(message): phase = .connecting; detail = message
        case let .failed(message), let .rejected(message): phase = .failed; detail = message
        case .idle: phase = .connecting
        }
        let status = WatchLiveStatus(phase: phase, detail: detail, batteryLevel: connection.status?.batteryLevel,
                                     isRecording: connection.status?.isRecording ?? false,
                                     nightActive: connection.status?.nightActive ?? false,
                                     otherTalker: connection.otherTalker)
        if let data = try? JSONEncoder().encode(status) { send(.status, data) }
    }

    private func send(_ kind: WatchLink.Payload, _ data: Data) {
        guard let session, session.isReachable else { return }
        session.sendMessageData(WatchLink.pack(kind, data), replyHandler: nil, errorHandler: nil)
    }

    fileprivate func receive(_ data: Data) {
        guard let (kind, payload) = WatchLink.unpack(data), kind == .talk else { return }
        connection?.sendRelayVoice(payload)
    }
}

extension WatchRelay: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.publishCameras() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()   // switching between watches
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.publishCameras() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let data = message[WatchLink.requestKey] as? Data, let request = try? JSONDecoder().decode(WatchRequest.self, from: data) else {
            replyHandler([:])
            return
        }
        Task { @MainActor in
            let reply = self.handle(request)
            replyHandler([WatchLink.replyKey: (try? JSONEncoder().encode(reply)) ?? Data()])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message[WatchLink.requestKey] as? Data, let request = try? JSONDecoder().decode(WatchRequest.self, from: data) else { return }
        Task { @MainActor in _ = self.handle(request) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task { @MainActor in self.receive(messageData) }
    }
}
