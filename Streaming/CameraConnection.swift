import Foundation
import AVFoundation
import Photos
import UIKit
import UserNotifications
import LiveKitWebRTC

/// The viewer's live link to one camera: video, audio both ways, remote control, the
/// recordings timeline, playback and clip export. Reconnects on its own when the network blips.
@MainActor
final class CameraConnection: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting(String)
        case connected
        case failed(String)
        case rejected(String)

        var isActive: Bool {
            switch self {
            case .connecting, .connected: true
            default: false
            }
        }
    }

    struct PlaybackState: Equatable {
        var isLive = true
        var date: Date?
        var isPlaying = true
        var rate: Double = 1
    }

    struct ExportJob: Identifiable, Equatable {
        enum State: Equatable { case working, done(URL), failed(String) }
        var id: UUID
        var from: Date
        var to: Date
        var progress: Double = 0
        var state: State = .working
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status: CameraStatus?
    @Published private(set) var events: [CameraEvent] = []
    @Published private(set) var segments: [RecordingSegment] = []
    @Published private(set) var stats = LinkStats()
    @Published private(set) var isTalking = false
    @Published var isListening = true { didSet { updateAudio() } }
    @Published private(set) var playback = PlaybackState()
    @Published private(set) var exports: [UUID: ExportJob] = [:]
    @Published private(set) var thumbnails: [UUID: UIImage] = [:]
    @Published private(set) var otherTalker: String?
    @Published private(set) var latestEvent: CameraEvent?
    @Published private(set) var toast: String?
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var hasVideo = false

    private(set) var camera: PairedCamera
    var id: String { camera.id }
    let sink = FrameSink()
    private lazy var renderer = RemoteVideoRenderer(sink: sink)
    private weak var hub: ViewerHub?

    private var link: PeerLink?
    private var remoteVideo: LKRTCVideoTrack?
    private var remoteAudio: LKRTCAudioTrack?
    private var audioTransceiver: LKRTCRtpTransceiver?
    private var micTrack: LKRTCAudioTrack?
    private var connectTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var wantsConnection = false
    private var incomingFile: (header: FileTransferHeader, data: Data)?
    private var pendingThumbnails = Set<UUID>()
    private var pendingSnapshots = Set<UUID>()
    var audioFocused = true { didSet { updateAudio() } }

    // MARK: Apple Watch relay
    /// While an Apple Watch watches through this iPhone, camera sound goes to the watch instead of the iPhone speaker.
    var watchRelayActive = false { didSet { updateAudio() } }
    /// Camera audio as voice packets (only while `relayVoice(true)`).
    var onRelayVoicePacket: ((Data) -> Void)?
    private(set) var voiceRelayRequested = false

    func relayVoice(_ on: Bool) {
        guard phase == .connected else { voiceRelayRequested = false; return }
        voiceRelayRequested = on
        send(.relayVoice(on))
    }

    /// The watch wearer starts/stops talking (their voice arrives via `sendRelayVoice`).
    func relayTalk(_ on: Bool) {
        guard phase == .connected else { return }
        send(.talk(on))
    }

    func sendRelayVoice(_ packet: Data) {
        link?.sendVoice(packet)
    }

    init(camera: PairedCamera, hub: ViewerHub) {
        self.camera = camera
        self.hub = hub
        sink.onSizeChange = { [weak self] size in
            Task { @MainActor in
                self?.videoSize = size
                self?.hasVideo = true
            }
        }
    }

    func update(camera: PairedCamera) { self.camera = camera }

    // MARK: Connect

    func connect() {
        wantsConnection = true
        guard !phase.isActive else { return }
        connectTask?.cancel()
        connectTask = Task { await runConnect() }
    }

    func disconnect() {
        wantsConnection = false
        connectTask?.cancel()
        teardown()
        phase = .idle
    }

    private func runConnect() async {
        guard let hub else { return }
        teardown()
        phase = .connecting(hub.lan.isVisible(camera.key) ? "Connecting on this network…" : "Reaching camera…")

        guard let link = PeerLink() else {
            phase = .failed("Couldn't start WebRTC")
            return
        }
        self.link = link
        wire(link)

        let videoInit = LKRTCRtpTransceiverInit()
        videoInit.direction = .recvOnly
        link.connection.addTransceiver(of: .video, init: videoInit)
        // Receive-only until the user taps Talk, so the viewer's microphone is never open otherwise.
        let audioInit = LKRTCRtpTransceiverInit()
        audioInit.direction = .recvOnly
        audioTransceiver = link.connection.addTransceiver(of: .audio, init: audioInit)

        do {
            let sdp = try await link.makeOffer()
            let offer = SignalMessage(kind: .offer, session: UUID(), from: DeviceIdentity.id, fromName: DeviceIdentity.name, sdp: sdp)
            let answer = try await hub.exchange(offer, key: camera.key)
            guard !Task.isCancelled else { return }
            if answer.kind == .reject {
                phase = .rejected(answer.reason ?? "The camera declined the connection.")
                wantsConnection = false
                teardown()
                return
            }
            guard let answerSDP = answer.sdp else { throw URLError(.badServerResponse) }
            try await link.accept(answerSDP: answerSDP)
            phase = .connecting("Starting video…")

            // ICE should finish quickly; if it hasn't in 20 s, start over.
            try await Task.sleep(for: .seconds(20))
            if case .connecting = phase { scheduleReconnect(reason: "The camera didn't respond in time.") }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            let reason = (error as? SignalingError)?.message ?? "Couldn't reach the camera."
            scheduleReconnect(reason: reason)
        }
    }

    private func wire(_ link: PeerLink) {
        link.onControlOpen = { [weak self] in
            Task { @MainActor in
                self?.send(.hello(viewerID: DeviceIdentity.id, name: DeviceIdentity.name))
            }
        }
        link.onControlMessage = { [weak self] data in
            guard let message = try? JSONDecoder().decode(CameraMessage.self, from: data) else { return }
            Task { @MainActor in self?.handle(message) }
        }
        link.onVoicePacket = { [weak self] packet in
            Task { @MainActor in self?.onRelayVoicePacket?(packet) }
        }
        link.onFileMessage = { [weak self] buffer in
            let data = buffer.data, isBinary = buffer.isBinary
            Task { @MainActor in self?.handleFile(data, isBinary: isBinary) }
        }
        link.onRemoteTrack = { [weak self] track in
            Task { @MainActor in self?.attach(track) }
        }
        link.onConnectionState = { [weak self, weak link] state in
            Task { @MainActor in
                guard let self, let link, link === self.link else { return }
                switch state {
                case .connected:
                    DebugSupport.log("viewer", "connected to \(self.camera.name)")
                    self.phase = .connected
                    self.reconnectAttempt = 0
                    self.startStats()
                case .failed, .closed:
                    self.scheduleReconnect(reason: "Connection lost.")
                case .disconnected:
                    // Often recovers by itself (Wi-Fi ↔ cellular); give it a moment.
                    try? await Task.sleep(for: .seconds(5))
                    if link === self.link, link.connection.connectionState == .disconnected {
                        self.scheduleReconnect(reason: "Connection lost.")
                    }
                default:
                    break
                }
            }
        }
    }

    private func attach(_ track: LKRTCMediaStreamTrack) {
        if let video = track as? LKRTCVideoTrack {
            remoteVideo?.remove(renderer)
            remoteVideo = video
            video.add(renderer)
        } else if let audio = track as? LKRTCAudioTrack {
            remoteAudio = audio
            updateAudio()
        }
    }

    private func scheduleReconnect(reason: String) {
        DebugSupport.log("viewer", "connection to \(camera.name) failed: \(reason)")
        teardown()
        guard wantsConnection else {
            phase = .failed(reason)
            return
        }
        reconnectAttempt += 1
        let delay = min(30, pow(2, Double(min(reconnectAttempt, 5))))
        phase = .failed("\(reason) Retrying in \(Int(delay)) s…")
        connectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, wantsConnection else { return }
            await runConnect()
        }
    }

    private func teardown() {
        voiceRelayRequested = false
        statsTask?.cancel()
        statsTask = nil
        remoteVideo?.remove(renderer)
        remoteVideo = nil
        remoteAudio = nil
        micTrack = nil
        audioTransceiver = nil
        isTalking = false
        renegotiationWaiter?.resume(throwing: CancellationError())
        renegotiationWaiter = nil
        link?.close()
        link = nil
        incomingFile = nil
        pendingThumbnails = []
        playback = PlaybackState()
        for (id, job) in exports where job.state == .working {
            exports[id]?.state = .failed("Connection lost")
        }
    }

    private func startStats() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let link = self?.link else { return }
                let stats = await link.stats(inbound: true)
                self?.stats = stats
                DebugSupport.log("viewer", "stats \(stats.width ?? 0)x\(stats.height ?? 0) fps=\(Int(stats.fps ?? 0)) kbps=\(Int((stats.bitrate ?? 0) / 1000)) rtt=\(Int((stats.roundTrip ?? 0) * 1000))ms path=\(stats.path.rawValue) remote=\(stats.remoteAddress ?? "?") audioBytes=\(stats.audioBytesReceived ?? 0) audioLevel=\(String(format: "%.3f", stats.audioLevel ?? 0))")
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Audio

    private func updateAudio() {
        remoteAudio?.isEnabled = isListening && audioFocused && !watchRelayActive
    }

    /// Opens or closes the microphone path by renegotiating the audio direction in-band.
    func setTalking(_ on: Bool) async {
        guard phase == .connected, let transceiver = audioTransceiver, let link, on != isTalking else { return }
        if on {
            guard await AVAudioApplication.requestRecordPermission() else {
                showToast("Allow microphone access in Settings to talk.")
                return
            }
            if micTrack == nil {
                let factory = RTCEnvironment.shared.factory
                micTrack = factory.audioTrack(with: factory.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)),
                                              trackId: "viewer-mic")
            }
            micTrack?.isEnabled = true
            transceiver.sender.track = micTrack
        } else {
            micTrack?.isEnabled = false
            transceiver.sender.track = nil
        }
        var directionError: NSError?
        transceiver.setDirection(on ? .sendRecv : .recvOnly, error: &directionError)
        do {
            let offer = try await link.renegotiationOffer()
            let answer = try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
                renegotiationWaiter = c
                send(.renegotiate(sdp: offer))
                Task {
                    try? await Task.sleep(for: .seconds(6))
                    if let waiter = renegotiationWaiter {
                        renegotiationWaiter = nil
                        waiter.resume(throwing: TimeoutError())
                    }
                }
            }
            try await link.accept(answerSDP: answer)
            isTalking = on
            send(.talk(on))
        } catch {
            transceiver.sender.track = nil
            transceiver.setDirection(.recvOnly, error: &directionError)
            isTalking = false
            showToast("Couldn't start talking. Try again.")
        }
    }

    private var renegotiationWaiter: CheckedContinuation<String, Error>?

    // MARK: Commands

    func send(_ command: ViewerCommand) {
        guard let data = try? JSONEncoder().encode(command) else { return }
        link?.sendControl(data)
    }

    func play(from date: Date) {
        playback = PlaybackState(isLive: false, date: date, isPlaying: true, rate: playback.rate)
        send(.playback(from: date))
    }

    func goLive() {
        playback = PlaybackState()
        send(.goLive)
    }

    func togglePause() {
        playback.isPlaying.toggle()
        send(playback.isPlaying ? .playbackResume : .playbackPause)
    }

    func setRate(_ rate: Double) {
        playback.rate = rate
        send(.playbackRate(rate))
    }

    func refreshTimeline() { send(.requestTimeline) }

    @discardableResult
    func exportClip(from: Date, to: Date, quality: ExportQuality) -> UUID {
        let id = UUID()
        exports[id] = ExportJob(id: id, from: from, to: to)
        send(.exportClip(requestID: id, from: from, to: to, quality: quality))
        return id
    }

    func dismissExport(_ id: UUID) {
        if case let .done(url) = exports[id]?.state { try? FileManager.default.removeItem(at: url) }
        exports[id] = nil
    }

    func thumbnail(for event: CameraEvent) -> UIImage? {
        if let image = thumbnails[event.id] { return image }
        if event.thumbnailFile != nil, phase == .connected, !pendingThumbnails.contains(event.id) {
            pendingThumbnails.insert(event.id)
            send(.requestThumbnail(eventID: event.id))
        }
        return nil
    }

    /// Full-resolution still from the camera, saved to Photos. Falls back to the received frame.
    func takeSnapshot() {
        if phase == .connected {
            let id = UUID()
            pendingSnapshots.insert(id)
            send(.requestSnapshot(requestID: id))
            showToast("Capturing…")
        } else if let jpeg = sink.snapshotJPEG() {
            saveToPhotos(jpeg: jpeg)
        }
    }

    // MARK: Incoming

    private func handle(_ message: CameraMessage) {
        switch message {
        case let .welcome(name):
            if name != camera.name { hub?.rename(camera, to: name, fromCamera: true) }
        case let .rejected(reason):
            phase = .rejected(reason)
            wantsConnection = false
            teardown()
        case let .status(status):
            self.status = status
        case let .event(event):
            events.append(event)
            latestEvent = event
            notifyIfBackground(event)
        case let .timeline(segments, events):
            self.segments = segments
            self.events = events
        case let .playbackState(date, isPlaying, isLive, rate):
            // Periodic updates may carry no date while the reader is between segments; keep the last one.
            playback = PlaybackState(isLive: isLive, date: date ?? (isLive ? nil : playback.date), isPlaying: isPlaying, rate: rate)
        case let .exportProgress(id, progress):
            exports[id]?.progress = progress
        case let .exportFailed(id, message):
            exports[id]?.state = .failed(message)
        case let .talkState(name):
            otherTalker = (name == DeviceIdentity.name && isTalking) ? nil : name
        case .pong:
            break
        case let .renegotiated(sdp):
            renegotiationWaiter?.resume(returning: sdp)
            renegotiationWaiter = nil
        }
    }

    private func handleFile(_ data: Data, isBinary: Bool) {
        if isBinary {
            incomingFile?.data.append(data)
            if let header = incomingFile?.header, header.kind == .clip, header.size > 0 {
                let received = Double(incomingFile?.data.count ?? 0) / Double(header.size)
                exports[header.reference]?.progress = 0.7 + 0.3 * received
            }
            return
        }
        if let header = try? JSONDecoder().decode(FileTransferHeader.self, from: data) {
            var buffer = Data()
            buffer.reserveCapacity(header.size)
            incomingFile = (header, buffer)
        } else if let footer = try? JSONDecoder().decode(FileTransferFooter.self, from: data),
                  let file = incomingFile, file.header.id == footer.id {
            incomingFile = nil
            complete(file.header, data: file.data)
        }
    }

    private func complete(_ header: FileTransferHeader, data: Data) {
        switch header.kind {
        case .thumbnail:
            pendingThumbnails.remove(header.reference)
            thumbnails[header.reference] = UIImage(data: data)
        case .snapshot:
            pendingSnapshots.remove(header.reference)
            saveToPhotos(jpeg: data)
        case .clip:
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(header.fileName)
            do {
                try data.write(to: url, options: .atomic)
                exports[header.reference]?.progress = 1
                exports[header.reference]?.state = .done(url)
            } catch {
                exports[header.reference]?.state = .failed(error.localizedDescription)
            }
        }
    }

    private func saveToPhotos(jpeg: Data) {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                showToast("Allow Photos access to save snapshots.")
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: jpeg, options: nil)
                }
                showToast("Snapshot saved to Photos")
            } catch {
                showToast("Couldn't save snapshot")
            }
        }
    }

    func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if toast == text { toast = nil }
        }
    }

    private func notifyIfBackground(_ event: CameraEvent) {
        #if !os(tvOS)
        // With iCloud push active the camera's push already alerts; don't double up.
        guard UIApplication.shared.applicationState == .background, camera.notificationsEnabled,
              hub?.cloudAvailable != true else { return }
        let content = UNMutableNotificationContent()
        content.title = camera.name
        content.body = event.label
        content.sound = .default
        content.userInfo = ["cameraID": camera.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil))
        #endif
    }
}
