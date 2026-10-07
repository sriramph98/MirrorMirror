import Foundation
import Combine
import UIKit

struct SignalingError: Error {
    var message: String
}

/// The viewer side of the app: paired cameras, where each one is reachable, and the
/// live connections to them.
@MainActor
final class ViewerHub: ObservableObject {
    static let shared = ViewerHub()

    enum Reachability: Equatable {
        case localNetwork
        case online(Date)
        case offline(Date?)
        case unknown
    }

    @Published private(set) var cameras: [PairedCamera] = []
    @Published private(set) var presence: [String: PresenceInfo] = [:]
    @Published private(set) var cloudAvailable = false
    @Published var audioFocus: String? { didSet { applyAudioFocus() } }
    /// Set when a notification or link should open a camera.
    @Published var pendingOpenCameraID: String?

    let lan = LocalSignalBrowser()
    private var connections: [String: CameraConnection] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var presenceTask: Task<Void, Never>?
    private var kvsObserver: NSObjectProtocol?
    private let relay = CloudRelay.shared

    private var hiddenICloudCameras: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "viewer.hiddenICloudCameras") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "viewer.hiddenICloudCameras") }
    }

    private init() {
        cameras = Keychain.codable([PairedCamera].self, for: "viewer-cameras") ?? []
        lan.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    /// Called when the viewer UI appears.
    func activate() {
        lan.start()
        importFromICloud()
        if kvsObserver == nil {
            kvsObserver = ICloudPairing.observe { [weak self] in self?.importFromICloud() }
        }
        guard presenceTask == nil else { return }
        presenceTask = Task { [weak self] in
            guard let self else { return }
            self.cloudAvailable = await self.relay.accountAvailable()
            DebugSupport.log("viewer", "iCloud relay \(self.cloudAvailable ? "available" : "unavailable")")
            if self.cloudAvailable { await self.subscribeAll() }
            while !Task.isCancelled {
                await self.refreshPresence()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    // MARK: Cameras

    func connection(for camera: PairedCamera) -> CameraConnection {
        if let existing = connections[camera.id] { return existing }
        let connection = CameraConnection(camera: camera, hub: self)
        connections[camera.id] = connection
        return connection
    }

    @discardableResult
    func add(_ invite: PairingInvite, source: PairedCamera.Source = .invite) -> PairedCamera {
        if let index = cameras.firstIndex(where: { $0.id == invite.key.cameraID }) {
            // Re-pairing (e.g. after the camera reset its key) updates the key in place.
            cameras[index].key = invite.key
            cameras[index].name = invite.name
            save()
            connections[cameras[index].id]?.update(camera: cameras[index])
            return cameras[index]
        }
        let camera = PairedCamera(key: invite.key, name: invite.name, source: source)
        cameras.append(camera)
        hiddenICloudCameras.remove(camera.id)
        save()
        Task { await subscribe(camera) }
        return camera
    }

    func remove(_ camera: PairedCamera) {
        connections[camera.id]?.disconnect()
        connections[camera.id] = nil
        cameras.removeAll { $0.id == camera.id }
        if camera.source == .iCloud { hiddenICloudCameras.insert(camera.id) }
        save()
        Task { await relay.unsubscribe(subscriptionID: camera.subscriptionID) }
    }

    func rename(_ camera: PairedCamera, to name: String, fromCamera: Bool = false) {
        guard let index = cameras.firstIndex(where: { $0.id == camera.id }), cameras[index].name != name else { return }
        cameras[index].name = name
        save()
        connections[camera.id]?.update(camera: cameras[index])
        Task { await subscribe(cameras[index]) }
    }

    func setNotifications(_ camera: PairedCamera, enabled: Bool) {
        guard let index = cameras.firstIndex(where: { $0.id == camera.id }) else { return }
        cameras[index].notificationsEnabled = enabled
        save()
        connections[camera.id]?.update(camera: cameras[index])
        Task {
            if enabled { await subscribe(cameras[index]) } else { await relay.unsubscribe(subscriptionID: camera.subscriptionID) }
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        cameras.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func save() {
        Keychain.setCodable(cameras, for: "viewer-cameras")
    }

    private func importFromICloud() {
        let hidden = hiddenICloudCameras
        DebugSupport.log("viewer", "iCloud pairing store has \(ICloudPairing.invites().count) camera(s)")
        for invite in ICloudPairing.invites() where invite.key.cameraID != DeviceIdentity.id && !hidden.contains(invite.key.cameraID) {
            if let existing = cameras.first(where: { $0.id == invite.key.cameraID }), existing.key == invite.key { continue }
            add(invite, source: .iCloud)
        }
    }

    private func applyAudioFocus() {
        for (id, connection) in connections { connection.audioFocused = audioFocus == nil || audioFocus == id }
    }

    // MARK: Reachability

    func reachability(of camera: PairedCamera) -> Reachability {
        if lan.isVisible(camera.key) && !DebugSupport.disableLAN { return .localNetwork }
        guard let info = presence[camera.id] else { return cloudAvailable ? .offline(nil) : .unknown }
        // Cameras refresh presence every 2 minutes.
        return Date().timeIntervalSince(info.updated) < 300 ? .online(info.updated) : .offline(info.updated)
    }

    func refreshPresence() async {
        guard cloudAvailable else { return }
        for camera in cameras {
            if let record = await relay.presence(recordName: camera.key.presenceRecordName),
               let info = try? camera.key.open(PresenceInfo.self, from: record.payload) {
                presence[camera.id] = info
            }
        }
    }

    // MARK: Signaling

    /// Delivers an offer over every path that might reach the camera and returns the first answer.
    func exchange(_ offer: SignalMessage, key: PairingKey) async throws -> SignalMessage {
        // Bonjour results can lag a second behind the app opening.
        if !lan.isVisible(key) {
            for _ in 0..<6 where !lan.isVisible(key) { try await Task.sleep(for: .milliseconds(250)) }
        }
        let useLAN = lan.isVisible(key) && !DebugSupport.disableLAN
        let useCloud = cloudAvailable
        guard useLAN || useCloud else {
            throw SignalingError(message: relay.isConfigured
                ? "Camera isn't on this network. Sign in to iCloud to watch from anywhere."
                : "Camera isn't on this network.")
        }

        // First answer wins and the slower path is cancelled without waiting for it.
        let race = AnswerRace(expected: (useLAN ? 1 : 0) + (useCloud ? 1 : 0))
        return try await withCheckedThrowingContinuation { continuation in
            race.start(continuation)
            if useLAN {
                race.add(Task { [lan] in
                    do { race.succeed(try await lan.exchange(offer, key: key)) } catch { race.fail(error) }
                })
            }
            if useCloud {
                race.add(Task {
                    do { race.succeed(try await self.cloudExchange(offer, key: key)) } catch { race.fail(error) }
                })
            }
        }
    }

    private nonisolated func cloudExchange(_ offer: SignalMessage, key: PairingKey) async throws -> SignalMessage {
        let relay = CloudRelay.shared
        let recordID = try await relay.post(try key.seal(offer), to: key.mailbox)
        defer { Task { await relay.delete([recordID]) } }
        let reply = key.replyMailbox(session: offer.session)
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(900))
            for message in (try? await relay.fetch(mailbox: reply, maxAge: 60)) ?? [] {
                if let answer = try? key.open(SignalMessage.self, from: message.payload), answer.session == offer.session {
                    return answer
                }
            }
        }
        throw TimeoutError()
    }

    // MARK: Push

    private func subscribeAll() async {
        for camera in cameras where camera.notificationsEnabled { await subscribe(camera) }
    }

    private func subscribe(_ camera: PairedCamera) async {
        guard cloudAvailable, camera.notificationsEnabled else { return }
        await relay.subscribeToEvents(mailbox: camera.key.eventMailbox, subscriptionID: camera.subscriptionID, cameraName: camera.name)
    }

    func camera(forSubscriptionID id: String) -> PairedCamera? {
        cameras.first { $0.subscriptionID == id }
    }

    func camera(id: String) -> PairedCamera? {
        cameras.first { $0.id == id }
    }
}

/// Resolves with the first successful signaling answer; fails only when every path failed.
private final class AnswerRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SignalMessage, Error>?
    private var tasks: [Task<Void, Never>] = []
    private var remaining: Int
    private var lastError: Error = SignalingError(message: "Camera is offline or the app isn't open on it.")

    init(expected: Int) { remaining = expected }

    func start(_ continuation: CheckedContinuation<SignalMessage, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func add(_ task: Task<Void, Never>) {
        lock.withLock { tasks.append(task) }
    }

    func succeed(_ answer: SignalMessage) {
        let (continuation, tasks) = lock.withLock { () -> (CheckedContinuation<SignalMessage, Error>?, [Task<Void, Never>]) in
            defer { self.continuation = nil }
            return (self.continuation, self.tasks)
        }
        continuation?.resume(returning: answer)
        tasks.forEach { $0.cancel() }
    }

    func fail(_ error: Error) {
        let continuation = lock.withLock { () -> CheckedContinuation<SignalMessage, Error>? in
            if error is SignalingError { lastError = error }
            remaining -= 1
            guard remaining <= 0 else { return nil }
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(throwing: lastError)
    }
}
