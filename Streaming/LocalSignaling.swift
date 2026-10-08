import Foundation
import Network

private let serviceType = "_mirror-mirror._tcp"

// MARK: - Framing

/// 4-byte big-endian length prefix + payload over a TCP NWConnection.
enum Framing {
    static func send(_ data: Data, on connection: NWConnection) async throws {
        var length = UInt32(data.count).bigEndian
        let frame = Data(bytes: &length, count: 4) + data
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    static func receive(on connection: NWConnection) async throws -> Data {
        let header = try await receive(exactly: 4, on: connection)
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard length > 0, length < 1_000_000 else { throw URLError(.cannotParseResponse) }
        return try await receive(exactly: Int(length), on: connection)
    }

    private static func receive(exactly count: Int, on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error { c.resume(throwing: error) }
                else if let data, data.count == count { c.resume(returning: data) }
                else { c.resume(throwing: isComplete ? URLError(.networkConnectionLost) : URLError(.cannotParseResponse)) }
            }
        }
    }
}

// MARK: - Camera side

/// Advertises the camera on the local network under its opaque mailbox name and answers
/// offers that arrive directly from viewers on the same Wi-Fi.
final class LocalSignalServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "mm.local-signal-server")
    private var key: PairingKey
    /// Receives a decrypted offer and returns the answer (or rejection) to send back.
    var onOffer: ((SignalMessage) async -> SignalMessage)?
    /// A viewer that removed this camera saying so (echoed back as the acknowledgement).
    var onGoodbye: ((SignalMessage) -> Void)?

    init(key: PairingKey) { self.key = key }

    func start() {
        stop()
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(name: key.mailbox, type: serviceType)
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    // Usually the network changed; come back shortly.
                    self?.queue.asyncAfter(deadline: .now() + 3) { self?.start() }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            print("LocalSignalServer: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func updateKey(_ key: PairingKey) {
        self.key = key
        if listener != nil { start() }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        // Never let a silent client hold a connection open.
        queue.asyncAfter(deadline: .now() + 30) { connection.cancel() }
        let key = self.key
        Task {
            defer { connection.cancel() }
            do {
                let data = try await Framing.receive(on: connection)
                let offer = try key.open(SignalMessage.self, from: data)
                if offer.kind == .goodbye {
                    onGoodbye?(offer)
                    try await Framing.send(try key.seal(offer), on: connection)
                    try? await Task.sleep(for: .milliseconds(300))
                    return
                }
                guard offer.kind == .offer, let onOffer else { return }
                let answer = await onOffer(offer)
                try await Framing.send(try key.seal(answer), on: connection)
                // Give the peer a moment to read before we close.
                try? await Task.sleep(for: .milliseconds(300))
            } catch {
                // Wrong key or garbage: drop silently.
            }
        }
    }
}

// MARK: - Viewer side

/// Watches the local network for cameras and delivers offers to them directly.
@MainActor
final class LocalSignalBrowser: ObservableObject {
    @Published private(set) var visibleMailboxes: Set<String> = []
    private var endpoints: [String: NWEndpoint] = [:]
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var map: [String: NWEndpoint] = [:]
            for result in results {
                if case let .service(name, _, _, _) = result.endpoint { map[name] = result.endpoint }
            }
            Task { @MainActor in
                self?.endpoints = map
                self?.visibleMailboxes = Set(map.keys)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor in
                    self?.browser = nil
                    try? await Task.sleep(for: .seconds(3))
                    self?.start()
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        endpoints = [:]
        visibleMailboxes = []
    }

    func isVisible(_ key: PairingKey) -> Bool { visibleMailboxes.contains(key.mailbox) }

    /// Sends a sealed offer to a camera on this network and waits for its reply.
    func exchange(_ offer: SignalMessage, key: PairingKey, timeout: TimeInterval = 15) async throws -> SignalMessage {
        guard let endpoint = endpoints[key.mailbox] else { throw URLError(.cannotFindHost) }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: parameters)
        // A dead endpoint (camera app restarted) parks in .waiting forever; treat that as failure.
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .waiting: connection.cancel()
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "mm.local-signal-client"))
        defer { connection.cancel() }
        return try await withTimeout(timeout) {
            // Cancelling the connection completes any pending send/receive, so the timeout can't hang.
            try await withTaskCancellationHandler {
                try await Framing.send(try key.seal(offer), on: connection)
                let reply = try await Framing.receive(on: connection)
                return try key.open(SignalMessage.self, from: reply)
            } onCancel: {
                connection.cancel()
            }
        }
    }
}

struct TimeoutError: Error {}

func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
