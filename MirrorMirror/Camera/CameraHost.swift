import Foundation
import AVFoundation
import CoreImage
import UIKit
import LiveKitWebRTC

/// Runs "camera mode": capture, detection, recording, and serving any number of viewers
/// over WebRTC, reachable on the local network (Bonjour) and remotely (CloudKit mailbox).
@MainActor
final class CameraHost: ObservableObject {
    @Published var settings: CameraSettings { didSet { settingsChanged(from: oldValue) } }
    @Published private(set) var engineState = CaptureEngine.State()
    @Published private(set) var viewers: [ViewerSummary] = []
    @Published private(set) var knownViewers: [KnownViewer] = []
    @Published private(set) var isRecording = false
    @Published private(set) var effectiveQuality: QualityPreset = .high
    @Published private(set) var recentEvents: [CameraEvent] = []
    @Published private(set) var motionLevel: Double = 0
    @Published private(set) var soundLevel: Double = 0
    @Published private(set) var talkingViewer: String?
    @Published private(set) var remoteReady = false
    @Published private(set) var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var batteryLevel: Double?
    @Published private(set) var isCharging = false
    @Published private(set) var key: PairingKey
    @Published var previewEnabled = true

    struct ViewerSummary: Identifiable, Hashable {
        var id: UUID
        var viewerID: String
        var name: String
        var isLive: Bool
        var isTalking: Bool
        var connectedAt: Date
    }

    let store = RecordingStore.shared
    let preview = FrameSink()
    /// Lets viewers on this network find the camera and pair with a code shown here.
    let nearby = NearbyPairingServer()
    var invite: PairingInvite { PairingInvite(key: key, name: settings.name) }

    private let engine = CaptureEngine()
    private let motion = MotionDetector()
    private let sound = SoundDetector()
    private let recorder: SegmentRecorder
    private let server: LocalSignalServer
    private let relay = CloudRelay.shared
    private lazy var micTrack: LKRTCAudioTrack = {
        let factory = RTCEnvironment.shared.factory
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        return factory.audioTrack(with: factory.audioSource(with: constraints), trackId: "camera-mic")
    }()

    /// Sessions are read from the capture queue for frame fan-out, so they live behind a lock.
    private let sessionLock = NSLock()
    nonisolated(unsafe) private var sessionList: [ViewerSession] = []
    private var sessions: [ViewerSession] { sessionLock.withLock { sessionList } }

    private var tasks: [Task<Void, Never>] = []
    private var processedSignals = Set<String>()
    private var lastCloudEvent = Date.distantPast
    private var manualRecording = false
    private var isRunning = false
    private var portraitFrames = false
    private var lowBatteryNotified = false
    private let ciContext = CIContext()
    private var observers: [NSObjectProtocol] = []

    init() {
        var settings = UserDefaults.standard.data(forKey: "camera.settings")
            .flatMap { try? JSONDecoder().decode(CameraSettings.self, from: $0) } ?? CameraSettings()
        if settings.name.isEmpty { settings.name = DeviceIdentity.name }
        self.settings = settings
        let key = Keychain.codable(PairingKey.self, for: "camera-key") ?? {
            let key = PairingKey.generate(cameraID: DeviceIdentity.id)
            Keychain.setCodable(key, for: "camera-key")
            return key
        }()
        self.key = key
        self.server = LocalSignalServer(key: key)
        self.recorder = SegmentRecorder(store: RecordingStore.shared)
        self.knownViewers = UserDefaults.standard.data(forKey: "camera.knownViewers")
            .flatMap { try? JSONDecoder().decode([KnownViewer].self, from: $0) } ?? []
        self.recentEvents = Array(store.events.suffix(30).reversed())
        wirePipeline()
    }

    // MARK: Start / stop

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true

        _ = await AVCaptureDevice.requestAccess(for: .video)
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        activateAudioSession()

        applySettings()
        engine.start()

        server.onOffer = { [weak self] offer in
            guard let self else { return SignalMessage(kind: .reject, session: offer.session, from: "", fromName: "") }
            return await self.handleOffer(offer)
        }
        server.onGoodbye = { [weak self] message in
            Task { @MainActor in self?.viewerRemovedCamera(message.from, name: message.fromName) }
        }
        server.start()
        nearby.invite = { [unowned self] in self.invite }
        nearby.start(name: settings.name, cameraID: key.cameraID)
        publishToICloud()
        observeDevice()
        DebugSupport.log("camera", "started synthetic=\(engine.state.isSynthetic) audio=\(engine.state.hasAudio) remote=\(relay.isConfigured)")
        DebugSupport.log("camera", "invite \(invite.url.absoluteString)")
        if let delay = DebugSupport.testEventDelay {
            tasks.append(Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.record(DetectionResult(kind: .crying, label: "Baby crying", confidence: 0.93))
            })
        }

        tasks.append(Task { [weak self] in await self?.statusLoop() })
        tasks.append(Task { [weak self] in await self?.maintenanceLoop() })
        if await relay.accountAvailable() {
            remoteReady = true
            DebugSupport.log("camera", "iCloud relay ready")
            tasks.append(Task { [weak self] in await self?.cloudInboxLoop() })
            tasks.append(Task { [weak self] in await self?.presenceLoop() })
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        tasks.forEach { $0.cancel() }
        tasks = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        server.stop()
        nearby.stop()
        engine.stop()
        recorder.stop()
        sessionLock.withLock {
            sessionList.forEach { $0.close() }
            sessionList = []
        }
        refreshViewers()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func activateAudioSession() {
        #if targetEnvironment(simulator)
        return   // no audio hardware; see RTCEnvironment
        #endif
        let session = LKRTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        do {
            try session.setCategory(.playAndRecord, mode: .videoChat, options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
            try session.setActive(true)
        } catch {
            print("CameraHost audio session: \(error)")
        }
        session.unlockForConfiguration()
    }

    // MARK: Pipeline

    private func wirePipeline() {
        let recorder = self.recorder, motion = self.motion, sound = self.sound, preview = self.preview
        engine.onFrame = { [weak self] buffer, time in
            recorder.append(pixelBuffer: buffer, time: time)
            motion.process(pixelBuffer: buffer, time: time)
            guard let self else { return }
            let portrait = CVPixelBufferGetHeight(buffer) > CVPixelBufferGetWidth(buffer)
            for session in self.sessionLock.withLock({ self.sessionList }) { session.pushLive(buffer, time: time) }
            if self.previewOn { preview.push(buffer) }
            if portrait != self.portraitOnQueue {
                self.portraitOnQueue = portrait
                Task { @MainActor in self.orientationChanged(portrait: portrait) }
            }
        }
        let voicePacketizer = self.voicePacketizer
        voicePacketizer.onPacket = { [weak self] packet in
            guard let self else { return }
            for session in self.sessionLock.withLock({ self.sessionList }) where session.wantsVoice {
                session.link.sendVoice(packet)
            }
        }
        engine.onAudio = { [weak self] buffer in
            recorder.append(audio: buffer)
            sound.process(sampleBuffer: buffer)
            if self?.voiceRelayActive == true { voicePacketizer.append(buffer) }
        }
        engine.onStateChange = { [weak self] state in
            Task { @MainActor in self?.engineState = state }
        }
        motion.onEvent = { [weak self] result in
            Task { @MainActor in self?.record(result) }
        }
        sound.onEvent = { [weak self] result in
            Task { @MainActor in self?.record(result) }
        }
        recorder.onStateChange = { [weak self] recording in
            Task { @MainActor in self?.isRecording = recording }
        }
    }

    // Read on the capture queue; cheap flags that don't need main-actor isolation.
    nonisolated(unsafe) private var previewOn = true
    /// True while any viewer relays camera audio to an Apple Watch.
    nonisolated(unsafe) private var voiceRelayActive = false
    private let voicePacketizer = VoicePacketizer()
    /// Plays an Apple Watch wearer's voice (relayed by their iPhone) through the camera's speaker.
    private lazy var watchVoicePlayer = VoicePlayer()
    private var watchVoicePackets = 0
    nonisolated(unsafe) private var portraitOnQueue = false

    func setPreviewVisible(_ visible: Bool) {
        previewOn = visible
        previewEnabled = visible
    }

    private func orientationChanged(portrait: Bool) {
        portraitFrames = portrait
        sessions.forEach { $0.apply(quality: effectiveQuality, portrait: portrait) }
    }

    // MARK: Settings

    private func settingsChanged(from old: CameraSettings) {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "camera.settings") }
        applySettings()
        if old.name != settings.name {
            publishToICloud()
            nearby.rename(settings.name)
        }
        if old.recordingMode != settings.recordingMode { manualRecording = false }
        broadcastStatus()
    }

    private func applySettings() {
        updateEffectiveQuality()
        engine.configure(quality: effectiveQuality, nightMode: settings.nightMode, enhance: settings.nightEnhance, mains: settings.mainsFrequency)
        motion.isEnabled = settings.motionEnabled
        motion.sensitivity = settings.motionSensitivity
        motion.detectPeopleAndPets = settings.detectPeopleAndPets
        sound.isEnabled = settings.soundEnabled
        sound.sensitivity = settings.soundSensitivity
        sound.enabledKinds = settings.soundKinds
        recorder.recordAudio = settings.recordAudio
        recorder.segmentDuration = DebugSupport.segmentDuration ?? (settings.recordingMode == .events ? 30 : 60)
        updateRecorder()
        for session in sessions { session.remoteAudio?.source.volume = settings.speakerVolume * 10 }
    }

    private func updateEffectiveQuality() {
        var quality = settings.quality
        if settings.adaptToHeat {
            switch thermal {
            case .serious: quality = quality.lower
            case .critical: quality = .saver
            default: break
            }
        }
        guard quality != effectiveQuality else { return }
        effectiveQuality = quality
        engine.configure(quality: quality, nightMode: settings.nightMode, enhance: settings.nightEnhance, mains: settings.mainsFrequency)
        sessions.forEach { $0.apply(quality: quality, portrait: portraitFrames) }
    }

    private func updateRecorder() {
        let shouldRecord = isRunning && (settings.recordingMode != .manual || manualRecording)
        if shouldRecord && !recorder.isRecording { recorder.start() }
        if !shouldRecord && recorder.isRecording { recorder.stop() }
    }

    /// Record button (here or on a viewer). Turning recording off in an automatic mode switches to manual.
    func setRecording(_ on: Bool) {
        if !on && settings.recordingMode != .manual { settings.recordingMode = .manual }
        manualRecording = on
        updateRecorder()
        broadcastStatus()
    }

    // MARK: Camera controls

    func setLens(_ factor: Double) { engine.setLens(factor); resetMotionAfterViewChange() }
    func setZoom(_ factor: Double) { engine.setZoom(factor); resetMotionAfterViewChange() }
    func flipCamera() { engine.flipCamera(); resetMotionAfterViewChange() }

    /// The whole picture changes on a lens/zoom/camera switch; that isn't motion in the room.
    private func resetMotionAfterViewChange() {
        motion.reset()
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            motion.reset()
        }
    }
    func setTorch(_ on: Bool) { engine.setTorch(on) }

    func resetPairing() {
        key = PairingKey.generate(cameraID: DeviceIdentity.id)
        Keychain.setCodable(key, for: "camera-key")
        server.updateKey(key)
        sessionLock.withLock {
            sessionList.forEach { $0.close() }
            sessionList = []
        }
        refreshViewers()
        publishToICloud()
    }

    func setBlocked(_ viewer: KnownViewer, blocked: Bool) {
        guard let index = knownViewers.firstIndex(where: { $0.id == viewer.id }) else { return }
        knownViewers[index].blocked = blocked
        saveKnownViewers()
        if blocked { disconnect(viewerID: viewer.id) }
    }

    func forget(_ viewer: KnownViewer) {
        knownViewers.removeAll { $0.id == viewer.id }
        saveKnownViewers()
    }

    func disconnect(viewerID: String) {
        let removed = sessionLock.withLock { () -> [ViewerSession] in
            let removed = sessionList.filter { $0.viewerID == viewerID }
            sessionList.removeAll { $0.viewerID == viewerID }
            return removed
        }
        removed.forEach { $0.close() }
        refreshViewers()
    }

    // MARK: Signaling

    private func handleOffer(_ offer: SignalMessage) async -> SignalMessage {
        func reject(_ reason: String) -> SignalMessage {
            SignalMessage(kind: .reject, session: offer.session, from: key.cameraID, fromName: settings.name, reason: reason)
        }
        guard offer.kind == .offer, let sdp = offer.sdp else { return reject("Malformed offer") }
        if knownViewers.contains(where: { $0.id == offer.from && $0.blocked }) {
            return reject("This camera's owner has removed your access.")
        }
        if let existing = sessions.first(where: { $0.id == offer.session }) {
            // Same offer arriving over both LAN and iCloud: the first one already answered.
            return SignalMessage(kind: .answer, session: offer.session, from: key.cameraID, fromName: settings.name,
                                 sdp: existing.link.connection.localDescription?.sdp)
        }
        guard let link = PeerLink() else { return reject("Camera couldn't start a connection") }
        let session = ViewerSession(id: offer.session, viewerID: offer.from, viewerName: offer.fromName, link: link)
        do {
            let answer = try await link.answer(offerSDP: sdp) {
                session.videoSender = link.connection.add(session.injector.track, streamIds: ["mirrormirror"])
                link.connection.add(micTrack, streamIds: ["mirrormirror"])
            }
            session.apply(quality: effectiveQuality, portrait: portraitFrames)
            attach(session)
            return SignalMessage(kind: .answer, session: offer.session, from: key.cameraID, fromName: settings.name, sdp: answer)
        } catch {
            link.close()
            return reject("Camera couldn't answer: \(error.localizedDescription)")
        }
    }

    private func attach(_ session: ViewerSession) {
        // A viewer reconnecting replaces its previous session.
        let replaced = sessionLock.withLock { () -> [ViewerSession] in
            let old = sessionList.filter { $0.viewerID == session.viewerID }
            sessionList.removeAll { $0.viewerID == session.viewerID }
            sessionList.append(session)
            return old
        }
        replaced.forEach { $0.close() }
        DebugSupport.log("camera", "viewer session \(session.viewerName) attached")

        let link = session.link
        link.onControlMessage = { [weak self, weak session] data in
            guard let session, let command = try? JSONDecoder().decode(ViewerCommand.self, from: data) else { return }
            Task { @MainActor in self?.handle(command, from: session) }
        }
        link.onConnectionState = { [weak self, weak session] state in
            guard let session else { return }
            if state == .failed || state == .closed || state == .disconnected {
                Task { @MainActor in
                    // Give a "disconnected" peer a few seconds to recover before dropping it.
                    if state == .disconnected { try? await Task.sleep(for: .seconds(8)) }
                    guard session.link.connection.connectionState != .connected else { return }
                    self?.drop(session)
                }
            }
        }
        link.onVoicePacket = { [weak self] packet in
            Task { @MainActor in
                guard let self else { return }
                self.watchVoicePackets += 1
                if self.watchVoicePackets % 25 == 1 { DebugSupport.log("camera", "watch voice packets: \(self.watchVoicePackets)") }
                self.watchVoicePlayer.play(packet)
            }
        }
        link.onRemoteTrack = { [weak self, weak session] track in
            guard let audio = track as? LKRTCAudioTrack else { return }
            DebugSupport.log("camera", "receiving viewer audio track")
            Task { @MainActor in
                audio.source.volume = (self?.settings.speakerVolume ?? 1) * 10
                session?.remoteAudio = audio
            }
        }
        refreshViewers()
    }

    private func drop(_ session: ViewerSession) {
        sessionLock.withLock { sessionList.removeAll { $0 === session } }
        session.close()
        if talkingViewer == session.viewerName { talkingViewer = nil }
        voiceRelayActive = sessions.contains { $0.wantsVoice }
        refreshViewers()
    }

    private func refreshViewers() {
        viewers = sessions.map {
            ViewerSummary(id: $0.id, viewerID: $0.viewerID, name: $0.viewerName, isLive: $0.isLive, isTalking: $0.isTalking, connectedAt: $0.connectedAt)
        }
    }

    /// Connection stats for each connected viewer (camera-side view: video sent, audio received).
    func viewerStats() async -> [LinkStats] {
        var result: [LinkStats] = []
        for session in sessions { result.append(await session.link.stats(inbound: false)) }
        return result
    }

    // MARK: Viewer commands

    private func handle(_ command: ViewerCommand, from session: ViewerSession) {
        DebugSupport.log("camera", "command \(String(describing: command).prefix(80)) from \(session.viewerName)")
        switch command {
        case let .hello(viewerID, name):
            guard viewerID == session.viewerID else { return }
            session.rename(name)
            if let index = knownViewers.firstIndex(where: { $0.id == viewerID }) {
                if knownViewers[index].blocked {
                    send(.rejected(reason: "This camera's owner has removed your access."), to: session)
                    drop(session)
                    return
                }
                knownViewers[index].name = name
                knownViewers[index].lastSeen = Date()
            } else {
                knownViewers.append(KnownViewer(id: viewerID, name: name, firstSeen: Date(), lastSeen: Date()))
            }
            saveKnownViewers()
            session.helloReceived = true
            send(.welcome(cameraName: settings.name), to: session)
            send(.status(makeStatus()), to: session)
            sendTimeline(to: session)
            refreshViewers()
        case let .setLens(factor): setLens(factor)
        case let .setZoom(factor): setZoom(factor)
        case .flipCamera: flipCamera()
        case let .setTorch(on): setTorch(on)
        case let .setNightMode(mode): settings.nightMode = mode
        case let .setQuality(quality): settings.quality = quality
        case let .setRecording(on): setRecording(on)
        case let .updateSettings(newSettings):
            var merged = newSettings
            merged.name = newSettings.name.isEmpty ? settings.name : newSettings.name
            settings = merged
        case let .talk(on):
            session.isTalking = on
            if !on { session.remoteAudio = nil }
            talkingViewer = on ? session.viewerName : (sessions.first { $0.isTalking }?.viewerName)
            refreshViewers()
            sessions.forEach { send(.talkState(viewerName: talkingViewer), to: $0) }
        case .requestTimeline:
            sendTimeline(to: session)
        case let .playback(date):
            session.startPlayback(from: date, store: store) { [weak self, weak session] date, playing, live, rate in
                guard let session else { return }
                Task { @MainActor in
                    self?.send(.playbackState(date: date, isPlaying: playing, isLive: live, rate: rate), to: session)
                    self?.refreshViewers()
                }
            }
            refreshViewers()
        case .playbackPause:
            session.pausePlayback()
            send(.playbackState(date: session.playbackDate, isPlaying: false, isLive: false, rate: 1), to: session)
        case .playbackResume:
            session.resumePlayback()
            send(.playbackState(date: session.playbackDate, isPlaying: true, isLive: false, rate: 1), to: session)
        case let .playbackRate(rate):
            session.setRate(rate)
        case .goLive:
            session.goLive()
            send(.playbackState(date: nil, isPlaying: true, isLive: true, rate: 1), to: session)
            refreshViewers()
        case let .exportClip(requestID, from, to, quality):
            exportClip(requestID: requestID, from: from, to: to, quality: quality, for: session)
        case let .requestThumbnail(eventID):
            sendThumbnail(eventID: eventID, to: session)
        case let .requestSnapshot(requestID):
            sendSnapshot(requestID: requestID, to: session)
        case let .ping(date):
            send(.pong(date), to: session)
        case let .renegotiate(sdp):
            Task {
                guard let answer = try? await session.link.answerRenegotiation(offerSDP: sdp) else { return }
                send(.renegotiated(sdp: answer), to: session)
            }
        case let .relayVoice(on):
            session.wantsVoice = on
            voiceRelayActive = sessions.contains { $0.wantsVoice }
        case .goodbye:
            viewerRemovedCamera(session.viewerID, name: session.viewerName)
        }
    }

    /// A viewer removed this camera on their side: forget the device and close its session.
    private func viewerRemovedCamera(_ viewerID: String, name: String) {
        DebugSupport.log("camera", "\(name) removed this camera")
        knownViewers.removeAll { $0.id == viewerID }
        saveKnownViewers()
        disconnect(viewerID: viewerID)
    }

    private func send(_ message: CameraMessage, to session: ViewerSession) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        session.link.sendControl(data)
    }

    private func broadcast(_ message: CameraMessage) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        for session in sessions where session.helloReceived { session.link.sendControl(data) }
    }

    private func sendTimeline(to session: ViewerSession) {
        // One control message must stay well under WebRTC's data-channel limit (256 KB), or the
        // channel fails and the viewer's later commands never arrive. Send merged coverage spans
        // (viewers only draw coverage) and the newest events, halving until it fits.
        let since = Date().addingTimeInterval(-7 * 24 * 3600)
        var spans = Array(RecordingSegment.spans(store.segmentsSnapshot().filter { $0.end > since }).suffix(800))
        var events = Array(store.eventsSnapshot().filter { $0.date > since }.suffix(400))
        while let size = try? JSONEncoder().encode(CameraMessage.timeline(segments: spans, events: events)).count,
              size > Self.maxControlMessageBytes, spans.count + events.count > 1 {
            spans = Array(spans.suffix(max(1, spans.count / 2)))
            events = Array(events.suffix(events.count / 2))
        }
        send(.timeline(segments: spans, events: events), to: session)
    }

    static let maxControlMessageBytes = 150_000

    private func exportClip(requestID: UUID, from: Date, to: Date, quality: ExportQuality, for session: ViewerSession) {
        let store = self.store
        Task.detached { [weak self, weak session] in
            do {
                var lastSent = 0.0
                let url = try await ClipExporter.export(from: from, to: to, store: store, quality: quality) { progress in
                    guard progress - lastSent > 0.05 || progress >= 1 else { return }
                    lastSent = progress
                    Task { @MainActor in
                        guard let session else { return }
                        // Export is the first ~70 %, the transfer the rest.
                        self?.send(.exportProgress(requestID: requestID, progress: progress * 0.7), to: session)
                    }
                }
                defer { try? FileManager.default.removeItem(at: url) }
                let data = try Data(contentsOf: url)
                guard let session else { return }
                let header = FileTransferHeader(id: UUID(), kind: .clip, reference: requestID, fileName: url.lastPathComponent, size: data.count)
                if !(await session.link.sendFile(data, header: header)) {
                    await self?.send(.exportFailed(requestID: requestID, message: "The connection dropped while sending the clip."), to: session)
                }
            } catch {
                guard let session else { return }
                await self?.send(.exportFailed(requestID: requestID, message: error.localizedDescription), to: session)
            }
        }
    }

    private func sendThumbnail(eventID: UUID, to session: ViewerSession) {
        guard let event = store.eventsSnapshot().first(where: { $0.id == eventID }),
              let url = store.thumbnailURL(for: event),
              let data = try? Data(contentsOf: url) else { return }
        let header = FileTransferHeader(id: UUID(), kind: .thumbnail, reference: eventID, fileName: url.lastPathComponent, size: data.count)
        Task.detached { _ = await session.link.sendFile(data, header: header) }
    }

    private func sendSnapshot(requestID: UUID, to session: ViewerSession) {
        guard let frame = engine.currentFrame(),
              let data = ciContext.jpegRepresentation(of: CIImage(cvPixelBuffer: frame), colorSpace: CGColorSpaceCreateDeviceRGB(),
                                                      options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92])
        else { return }
        let header = FileTransferHeader(id: UUID(), kind: .snapshot, reference: requestID, fileName: "Snapshot.jpg", size: data.count)
        Task.detached { _ = await session.link.sendFile(data, header: header) }
    }

    // MARK: Events

    private func record(_ result: DetectionResult) {
        DebugSupport.log("camera", "event \(result.kind.rawValue) \"\(result.label)\" confidence=\(String(format: "%.2f", result.confidence))")
        let event = store.addEvent(CameraEvent(date: Date(), kind: result.kind, label: result.label, confidence: result.confidence),
                                   thumbnailJPEG: result.snapshotJPEG)
        recentEvents.insert(event, at: 0)
        if recentEvents.count > 30 { recentEvents.removeLast() }
        broadcast(.event(event))
        notifyRemoteViewers(event)
    }

    /// Push via CloudKit, at most once a minute so a busy room doesn't spam phones.
    private func notifyRemoteViewers(_ event: CameraEvent) {
        guard settings.notifyViewers, remoteReady, Date().timeIntervalSince(lastCloudEvent) > 60,
              let payload = try? key.seal(CloudEventInfo(event: event, cameraName: settings.name)) else { return }
        lastCloudEvent = Date()
        let mailbox = key.eventMailbox
        Task { await relay.postEvent(payload, mailbox: mailbox) }
    }

    // MARK: Loops

    private func statusLoop() async {
        var tick = 0
        while !Task.isCancelled {
            motionLevel = motion.activityLevel
            soundLevel = sound.level
            refreshBattery()
            broadcastStatus()
            // Keep replaying viewers' clocks and scrubbers moving.
            for session in sessions where !session.isLive {
                send(.playbackState(date: session.playbackDate, isPlaying: !session.isPaused, isLive: false, rate: session.currentRate), to: session)
            }
            tick += 1
            if tick % 5 == 0 {
                let e = engineState
                let audioIn = await viewerStats().map { $0.audioBytesReceived ?? 0 }
                DebugSupport.log("camera", "status viewers=\(viewers.map(\.name)) rec=\(isRecording) mode=\(settings.recordingMode.rawValue) quality=\(effectiveQuality.rawValue) thermal=\(thermal.rawValue) battery=\(batteryLevel.map { Int($0 * 100) } ?? -1) mic=\(e.hasAudio) front=\(e.usingFrontCamera) lenses=\(e.lenses.map(\.factor)) zoom=\(String(format: "%.2f", e.zoom)) torch=\(e.torchOn) night=\(e.nightActive) motion=\(String(format: "%.2f", motionLevel)) sound=\(String(format: "%.2f", soundLevel)) talker=\(talkingViewer ?? "-") viewerAudioBytes=\(audioIn) segments=\(store.segments.count)")
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func maintenanceLoop() async {
        while !Task.isCancelled {
            store.enforceRetention(capBytes: Int64(settings.storageCapGB * 1_000_000_000), mode: settings.recordingMode)
            try? await Task.sleep(for: .seconds(60))
        }
    }

    /// Polls the CloudKit inbox for offers from viewers that aren't on this network.
    private func cloudInboxLoop() async {
        let started = Date()
        while !Task.isCancelled {
            let key = self.key
            if let messages = try? await relay.fetch(mailbox: key.mailbox, maxAge: 60) {
                for message in messages where !processedSignals.contains(message.id.recordName) {
                    processedSignals.insert(message.id.recordName)
                    guard let offer = try? key.open(SignalMessage.self, from: message.payload) else { continue }
                    if offer.kind == .goodbye {
                        // Honoured even if it was sent while this camera was off (within the fetch window).
                        viewerRemovedCamera(offer.from, name: offer.fromName)
                        await relay.delete([message.id])
                        continue
                    }
                    guard offer.sentAt > started.addingTimeInterval(-30) else { continue }
                    if offer.kind == .snapshotRequest {
                        serveSnapshots(for: offer.fromName)
                        continue
                    }
                    guard offer.kind == .offer else { continue }
                    DebugSupport.log("camera", "offer via iCloud from \(offer.fromName)")
                    let answer = await handleOffer(offer)
                    if let sealed = try? key.seal(answer),
                       let id = try? await relay.post(sealed, to: key.replyMailbox(session: offer.session)) {
                        Task {
                            try? await Task.sleep(for: .seconds(120))
                            await CloudRelay.shared.delete([id])
                        }
                    }
                }
            }
            try? await Task.sleep(for: .seconds(sessions.isEmpty ? 2 : 4))
        }
    }

    // MARK: Apple Watch snapshots (iCloud fallback)

    private var snapshotsUntil = Date.distantPast
    private var snapshotTask: Task<Void, Never>?

    /// A watch that can't reach its iPhone asked for pictures: publish a sealed snapshot every
    /// few seconds for a short while (it re-asks while it's still looking).
    private func serveSnapshots(for requester: String) {
        snapshotsUntil = Date().addingTimeInterval(45)
        guard snapshotTask == nil else { return }
        DebugSupport.log("camera", "serving iCloud snapshots to \(requester)")
        snapshotTask = Task { [weak self] in
            while let self, !Task.isCancelled, Date() < self.snapshotsUntil {
                await self.publishSnapshot()
                try? await Task.sleep(for: .seconds(3))
            }
            self?.snapshotTask = nil
        }
    }

    private func publishSnapshot() async {
        guard let frame = engine.currentFrame() else { return }
        let image = CIImage(cvPixelBuffer: frame)
        let scale = 480 / max(image.extent.width, image.extent.height)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let jpeg = ciContext.jpegRepresentation(of: small, colorSpace: CGColorSpaceCreateDeviceRGB(),
                                                      options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.55]) else { return }
        let info = SnapshotInfo(jpeg: jpeg, taken: Date(), cameraName: settings.name, batteryLevel: batteryLevel, isRecording: isRecording)
        guard let payload = try? key.seal(info) else { return }
        await relay.publishPresence(payload, recordName: key.snapshotRecordName)
    }

    private func presenceLoop() async {
        while !Task.isCancelled {
            let info = PresenceInfo(name: settings.name, batteryLevel: batteryLevel, isCharging: isCharging,
                                    isRecording: isRecording, viewerCount: sessions.count, updated: Date())
            if let payload = try? key.seal(info) {
                await relay.publishPresence(payload, recordName: key.presenceRecordName)
            }
            try? await Task.sleep(for: .seconds(120))
        }
    }

    // MARK: Status

    private func broadcastStatus() {
        broadcast(.status(makeStatus()))
    }

    private func makeStatus() -> CameraStatus {
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return CameraStatus(
            name: settings.name, batteryLevel: batteryLevel, isCharging: isCharging, thermal: thermal.rawValue,
            isRecording: isRecording, recordingMode: settings.recordingMode, storageUsedBytes: store.totalBytes,
            storageFreeBytes: free, viewerCount: sessions.count, quality: settings.quality, effectiveQuality: effectiveQuality,
            nightMode: settings.nightMode, nightActive: engineState.nightActive, torchOn: engineState.torchOn,
            torchAvailable: engineState.torchAvailable, usingFrontCamera: engineState.usingFrontCamera,
            lenses: engineState.lenses, zoom: engineState.zoom, maxZoom: engineState.maxZoom,
            motionLevel: motionLevel, soundLevel: soundLevel, settings: settings)
    }

    private func refreshBattery() {
        let device = UIDevice.current
        batteryLevel = device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil
        isCharging = device.batteryState == .charging || device.batteryState == .full
        if let level = batteryLevel, level < 0.15, !isCharging {
            if !lowBatteryNotified {
                lowBatteryNotified = true
                record(DetectionResult(kind: .lowBattery, label: "Battery at \(Int(level * 100))%. Plug in the camera.", confidence: 1))
            }
        } else {
            lowBatteryNotified = false
        }
    }

    private func observeDevice() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let newState = ProcessInfo.processInfo.thermalState
                if newState == .critical, self.thermal != .critical {
                    self.record(DetectionResult(kind: .overheating, label: "Camera is very hot. Quality reduced.", confidence: 1))
                }
                self.thermal = newState
                self.updateEffectiveQuality()
            }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.activateAudioSession()
                self.engine.start()
                self.server.start()
            }
        })
    }

    // MARK: Persistence

    private func saveKnownViewers() {
        if let data = try? JSONEncoder().encode(knownViewers) { UserDefaults.standard.set(data, forKey: "camera.knownViewers") }
    }

    /// Devices on the same Apple Account pick this camera up automatically.
    private func publishToICloud() {
        ICloudPairing.publish(PairingInvite(key: key, name: settings.name))
    }
}

// MARK: - Read-only conveniences for the camera-mode UI

extension CameraHost {
    /// The most recent detection, if any.
    var latestEvent: CameraEvent? { recentEvents.first }

    /// The small JPEG saved with an event, if there is one on disk.
    func thumbnailImage(for event: CameraEvent) -> UIImage? {
        store.thumbnailURL(for: event).flatMap { UIImage(contentsOfFile: $0.path) }
    }

    /// What is being streamed and recorded right now, as readout items: ["1080", "30", "HEVC"].
    var streamFormatItems: [String] {
        let quality = effectiveQuality
        return ["\(quality.dimensions.short)", "\(quality.fps)", "HEVC"]
    }

    /// Bytes free on the device for recordings.
    var storageFreeBytes: Int64 {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Roughly how many hours of footage still fit before the storage cap (or the device) is full,
    /// at the current quality's recording bitrate (plus audio when it's recorded).
    var estimatedRecordingHoursLeft: Double {
        let dims = effectiveQuality.dimensions
        let videoBits = SegmentRecorder.defaultBitrate(width: dims.long, height: dims.short)
        let bitsPerSecond = Double(videoBits + (settings.recordAudio ? 64_000 : 0))
        let capBytes = Int64(settings.storageCapGB * 1_000_000_000)
        let room = max(0, min(storageFreeBytes, capBytes - store.totalBytes))
        return Double(room) * 8 / bitsPerSecond / 3600
    }
}
