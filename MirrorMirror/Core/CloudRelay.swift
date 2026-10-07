import Foundation
import CloudKit
import MachO

/// Uses the app's CloudKit *public* database as a mailbox so two devices that are not on the
/// same network can complete a WebRTC handshake, see each other's presence, and so viewers
/// get push notifications for camera events. No server of our own is involved, and every
/// payload is sealed with the pairing key, so the public records are opaque blobs under
/// hashed mailbox names. Video never goes through CloudKit; it flows peer-to-peer.
final class CloudRelay {
    static let shared = CloudRelay()
    static let containerID = "iCloud.sriramph.MirrorMirror"

    private enum RecordType {
        static let signal = "Signal"
        static let event = "Event"
        static let presence = "Presence"
    }

    /// False when the build has no iCloud entitlement (e.g. an unsigned simulator build).
    /// Touching CKContainer without the entitlement crashes, so everything checks this first.
    let isConfigured: Bool = Entitlements.hasCloudKit
    private lazy var database: CKDatabase = CKContainer(identifier: Self.containerID).publicCloudDatabase

    func accountAvailable() async -> Bool {
        guard isConfigured else { return false }
        return (try? await CKContainer(identifier: Self.containerID).accountStatus()) == .available
    }

    // MARK: Signaling mailboxes

    func post(_ payload: Data, to mailbox: String) async throws -> CKRecord.ID {
        try requireConfigured()
        let record = CKRecord(recordType: RecordType.signal)
        record["mailbox"] = mailbox
        record["payload"] = payload
        return try await database.save(record).recordID
    }

    /// Newest-first messages in a mailbox, created within the last `maxAge` seconds.
    func fetch(mailbox: String, maxAge: TimeInterval = 90) async throws -> [(id: CKRecord.ID, payload: Data)] {
        try requireConfigured()
        let query = CKQuery(recordType: RecordType.signal, predicate: NSPredicate(format: "mailbox == %@", mailbox))
        let (results, _) = try await database.records(matching: query, desiredKeys: ["payload"], resultsLimit: 25)
        let cutoff = Date().addingTimeInterval(-maxAge)
        return results.compactMap { id, result in
            guard let record = try? result.get(),
                  (record.creationDate ?? .distantPast) > cutoff,
                  let payload = record["payload"] as? Data else { return nil }
            return (id, payload)
        }
    }

    /// Records can only be deleted by the device that created them (public DB default roles).
    func delete(_ ids: [CKRecord.ID]) async {
        guard isConfigured, !ids.isEmpty else { return }
        _ = try? await database.modifyRecords(saving: [], deleting: ids)
    }

    // MARK: Presence

    func publishPresence(_ payload: Data, recordName: String) async {
        guard isConfigured else { return }
        let record = CKRecord(recordType: RecordType.presence, recordID: CKRecord.ID(recordName: recordName))
        record["payload"] = payload
        _ = try? await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }

    func presence(recordName: String) async -> (payload: Data, updated: Date)? {
        guard isConfigured,
              let record = try? await database.record(for: CKRecord.ID(recordName: recordName)),
              let payload = record["payload"] as? Data else { return nil }
        return (payload, record.modificationDate ?? .distantPast)
    }

    // MARK: Events & push

    func postEvent(_ payload: Data, mailbox: String) async {
        guard isConfigured else { return }
        let record = CKRecord(recordType: RecordType.event)
        record["mailbox"] = mailbox
        record["payload"] = payload
        _ = try? await database.save(record)
    }

    func events(mailbox: String, limit: Int = 30) async -> [Data] {
        guard isConfigured else { return [] }
        let query = CKQuery(recordType: RecordType.event, predicate: NSPredicate(format: "mailbox == %@", mailbox))
        guard let (results, _) = try? await database.records(matching: query, desiredKeys: ["payload"], resultsLimit: limit) else { return [] }
        return results.compactMap { try? $0.1.get()["payload"] as? Data }
    }

    /// Push notifications for new events on one camera. The alert text is chosen here, on the
    /// viewer, so nothing readable has to be stored in the public record.
    func subscribeToEvents(mailbox: String, subscriptionID: String, cameraName: String) async {
        guard isConfigured else { return }
        let subscription = CKQuerySubscription(recordType: RecordType.event,
                                               predicate: NSPredicate(format: "mailbox == %@", mailbox),
                                               subscriptionID: subscriptionID,
                                               options: [.firesOnRecordCreation])
        let info = CKSubscription.NotificationInfo()
        info.title = cameraName
        info.alertBody = "New activity detected. Tap to watch live."
        info.soundName = "default"
        info.shouldSendContentAvailable = true
        info.category = "camera-event"
        subscription.notificationInfo = info
        _ = try? await database.modifySubscriptions(saving: [subscription], deleting: [])
    }

    func unsubscribe(subscriptionID: String) async {
        guard isConfigured else { return }
        _ = try? await database.modifySubscriptions(saving: [], deleting: [subscriptionID])
    }

    private func requireConfigured() throws {
        if !isConfigured { throw CKError(.notAuthenticated) }
    }
}

/// Reads this build's own entitlements so CloudKit is never touched in builds that lack them.
enum Entitlements {
    static let hasCloudKit: Bool = {
        guard let plist = load() else { return false }
        return (plist["com.apple.developer.icloud-services"] as? [String])?.contains("CloudKit") == true
            || plist["com.apple.developer.icloud-container-identifiers"] != nil
    }()

    private static func load() -> [String: Any]? {
        #if targetEnvironment(simulator)
        // Simulator builds embed the entitlements plist in a Mach-O section.
        guard let header = _dyld_get_image_header(0) else { return nil }
        var size: UInt = 0
        let mh = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
        guard let bytes = getsectiondata(mh, "__TEXT", "__entitlements", &size), size > 0 else { return nil }
        return try? PropertyListSerialization.propertyList(from: Data(bytes: bytes, count: Int(size)), format: nil) as? [String: Any]
        #else
        // Device builds: the provisioning profile lists what the signature was allowed to claim.
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)),
              let profile = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]
        else {
            // App Store builds have no embedded profile but always carry the entitlements.
            return Bundle.main.appStoreReceiptURL?.lastPathComponent == "receipt"
                ? ["com.apple.developer.icloud-services": ["CloudKit"]] : nil
        }
        return profile["Entitlements"] as? [String: Any]
        #endif
    }
}
