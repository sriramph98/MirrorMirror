import AVFoundation
import CloudKit
import SwiftUI
import WatchConnectivity

/// The watch can't run WebRTC, so it watches through the paired iPhone (live JPEG + voice over
/// WatchConnectivity) and falls back to sealed iCloud snapshots when the iPhone is out of reach.
@MainActor
final class WatchStore: NSObject, ObservableObject {
    static let shared = WatchStore()

    enum Source: Equatable { case none, iPhone, iCloud }

    @Published private(set) var cameras: [WatchCamera] = []
    @Published private(set) var phoneReachable = false
    @Published private(set) var frame: UIImage?
    @Published private(set) var frameDate: Date?
    @Published private(set) var source: Source = .none
    @Published private(set) var status: WatchLiveStatus?
    @Published private(set) var isListening = true
    @Published private(set) var isTalking = false
    @Published private(set) var message: String?
    @Published private(set) var activeCameraID: String?

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }
    private let voicePlayer = VoicePlayer()
    private let recorder = VoiceRecorder()
    private var pingTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var lastRelayFrame = Date.distantPast
    private let cloud = WatchCloud()

    private override init() {
        super.init()
        cameras = Keychain.codable([WatchCamera].self, for: "watch-cameras") ?? []
        session?.delegate = self
        session?.activate()
    }

    // MARK: Viewing

    func open(_ camera: WatchCamera) {
        guard activeCameraID != camera.id else { return }
        close()
        activeCameraID = camera.id
        frame = nil
        status = WatchLiveStatus(phase: .connecting, detail: "Connecting…", isRecording: false, nightActive: false)
        configureAudio(talking: false)
        requestRelay(camera)

        // Keep the iPhone relay alive, and fall back to iCloud if no picture arrives through it.
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self, self.activeCameraID == camera.id else { return }
                if self.phoneReachable {
                    self.send(.ping)
                    if self.source != .iPhone { self.requestRelay(camera) }
                }
                let relayStale = Date().timeIntervalSince(self.lastRelayFrame) > 8
                if relayStale, self.snapshotTask == nil { self.startSnapshots(camera) }
                if !relayStale, self.snapshotTask != nil { self.stopSnapshots() }
            }
        }
    }

    func close() {
        if activeCameraID != nil { send(.stop) }
        pingTask?.cancel()
        pingTask = nil
        stopSnapshots()
        if isTalking { setTalking(false) }
        voicePlayer.stop()
        activeCameraID = nil
        source = .none
        frame = nil
    }

    func setListening(_ on: Bool) {
        isListening = on
        if !on { voicePlayer.stop() }
        send(.listen(on))
    }

    /// Whether the talk button is still held; permission prompts can resolve after release.
    private var wantsTalk = false

    func setTalking(_ on: Bool) {
        wantsTalk = on
        guard on != isTalking else { return }
        if on {
            Task {
                guard await AVAudioApplication.requestRecordPermission() else {
                    message = "Allow the microphone in Settings to talk."
                    return
                }
                guard wantsTalk else { return }
                configureAudio(talking: true)
                var sent = 0
                recorder.onPacket = { [weak self] packet in
                    Task { @MainActor in
                        sent += 1
                        if sent % 25 == 1 { watchDebugLog("MM watch: talk packets \(sent)") }
                        self?.sendData(WatchLink.pack(.talk, packet))
                    }
                }
                do {
                    try recorder.start()
                    isTalking = true
                    send(.talk(true))
                    watchDebugLog("MM watch: talking (reachable=\(session?.isReachable ?? false))")
                } catch {
                    watchDebugLog("MM watch: microphone failed: \(error)")
                    message = "Couldn't start the microphone."
                }
            }
        } else {
            recorder.stop()
            isTalking = false
            send(.talk(false))
            configureAudio(talking: false)
        }
    }

    private func configureAudio(talking: Bool) {
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(talking ? .playAndRecord : .playback, mode: .default)
        try? audio.setActive(true)
    }

    // MARK: iPhone relay

    private func requestRelay(_ camera: WatchCamera) {
        guard let session, session.isReachable,
              let data = try? JSONEncoder().encode(WatchRequest.watch(cameraID: camera.id, listen: isListening)) else { return }
        session.sendMessage([WatchLink.requestKey: data], replyHandler: { [weak self] reply in
            guard let data = reply[WatchLink.replyKey] as? Data, let reply = try? JSONDecoder().decode(WatchReply.self, from: data) else { return }
            Task { @MainActor in if !reply.ok { self?.message = reply.message } }
        }, errorHandler: nil)
    }

    private func send(_ request: WatchRequest) {
        guard let session, session.isReachable, let data = try? JSONEncoder().encode(request) else { return }
        session.sendMessage([WatchLink.requestKey: data], replyHandler: nil, errorHandler: nil)
    }

    private func sendData(_ data: Data) {
        guard let session, session.isReachable else { return }
        session.sendMessageData(data, replyHandler: nil, errorHandler: nil)
    }

    fileprivate func receive(_ data: Data) {
        guard activeCameraID != nil, let (kind, payload) = WatchLink.unpack(data) else { return }
        switch kind {
        case .frame:
            if let image = UIImage(data: payload) {
                frame = image
                frameDate = Date()
                lastRelayFrame = Date()
                source = .iPhone
                if snapshotTask != nil { stopSnapshots() }
            }
        case .voice:
            if isListening { voicePlayer.play(payload) }
        case .status:
            status = try? JSONDecoder().decode(WatchLiveStatus.self, from: payload)
        case .talk:
            break
        }
    }

    // MARK: iCloud fallback

    private func startSnapshots(_ camera: WatchCamera) {
        snapshotTask = Task { [weak self] in
            var lastRequest = Date.distantPast
            var lastTaken = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                if Date().timeIntervalSince(lastRequest) > 30 {
                    await self.cloud.requestSnapshots(from: camera)
                    lastRequest = Date()
                }
                if let info = await self.cloud.latestSnapshot(of: camera), info.taken > lastTaken {
                    lastTaken = info.taken
                    if let image = UIImage(data: info.jpeg), Date().timeIntervalSince(self.lastRelayFrame) > 8 {
                        self.frame = image
                        self.frameDate = info.taken
                        self.source = .iCloud
                        self.status = WatchLiveStatus(phase: .live, detail: nil, batteryLevel: info.batteryLevel,
                                                      isRecording: info.isRecording, nightActive: false)
                    }
                } else if self.source == .none {
                    self.status = WatchLiveStatus(phase: .connecting,
                                                  detail: self.phoneReachable ? "Reaching camera…" : "Waiting for iCloud…",
                                                  isRecording: false, nightActive: false)
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func stopSnapshots() {
        snapshotTask?.cancel()
        snapshotTask = nil
    }

    fileprivate func update(cameras: [WatchCamera]) {
        self.cameras = cameras
        Keychain.setCodable(cameras, for: "watch-cameras")
    }

    fileprivate func setReachable(_ reachable: Bool) {
        phoneReachable = reachable
    }
}

extension WatchStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        let reachable = session.isReachable
        Task { @MainActor in
            self.setReachable(reachable)
            if let data = context[WatchLink.camerasKey] as? Data,
               let cameras = try? JSONDecoder().decode([WatchCamera].self, from: data) {
                self.update(cameras: cameras)
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.setReachable(reachable) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchLink.camerasKey] as? Data,
              let cameras = try? JSONDecoder().decode([WatchCamera].self, from: data) else { return }
        Task { @MainActor in self.update(cameras: cameras) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task { @MainActor in self.receive(messageData) }
    }
}

/// CloudKit access for the snapshot fallback. Payloads are sealed with the camera's key.
struct WatchCloud {
    private var database: CKDatabase { CKContainer(identifier: "iCloud.com.sriramph.mirrormirror").publicCloudDatabase }

    func requestSnapshots(from camera: WatchCamera) async {
        let request = SignalMessage(kind: .snapshotRequest, session: UUID(), from: DeviceIdentity.id, fromName: "Apple Watch")
        guard let payload = try? camera.key.seal(request) else { return }
        let record = CKRecord(recordType: "Signal")
        record["mailbox"] = camera.key.mailbox
        record["payload"] = payload
        _ = try? await database.save(record)
    }

    func latestSnapshot(of camera: WatchCamera) async -> SnapshotInfo? {
        guard let record = try? await database.record(for: CKRecord.ID(recordName: camera.key.snapshotRecordName)),
              let payload = record["payload"] as? Data else { return nil }
        return try? camera.key.open(SnapshotInfo.self, from: payload)
    }
}

/// Debug-only logging (visible in the watch's system log); compiled out of Release.
func watchDebugLog(_ format: String, _ args: CVarArg...) {
    #if DEBUG
    withVaList(args) { NSLogv(format, $0) }
    #endif
}
