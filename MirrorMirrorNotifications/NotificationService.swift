import CloudKit
import UserNotifications

/// Turns the generic CloudKit push ("New activity detected") into the real event
/// ("Baby crying", "Person detected") by decrypting it on the device. The event is sealed with
/// the camera's pairing key, so iCloud and Apple's push service only ever carry ciphertext.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?
    private var task: Task<Void, Never>?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        bestAttempt = content

        guard let notification = CKNotification(fromRemoteNotificationDictionary: request.content.userInfo) as? CKQueryNotification,
              let subscriptionID = notification.subscriptionID,
              let entry = NotificationKeyStore.load()[subscriptionID] else {
            contentHandler(content)
            return
        }
        content.threadIdentifier = entry.key.cameraID
        content.userInfo["cameraID"] = entry.key.cameraID

        task = Task {
            if let info = await Self.eventInfo(from: notification, key: entry.key) {
                Self.apply(info, cameraName: entry.cameraName, to: content)
            }
            self.deliver()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        task?.cancel()
        deliver()
    }

    private func deliver() {
        guard let contentHandler, let bestAttempt else { return }
        self.contentHandler = nil
        contentHandler(bestAttempt)
    }

    /// The sealed event normally arrives inside the push; if the push was trimmed, fetch the record.
    private static func eventInfo(from notification: CKQueryNotification, key: PairingKey) async -> CloudEventInfo? {
        if let text = notification.recordFields?[sealedEventField] as? String,
           let data = Data(base64Encoded: text),
           let info = try? key.open(CloudEventInfo.self, from: data) {
            return info
        }
        guard let recordID = notification.recordID,
              let record = try? await CKContainer(identifier: "iCloud.com.sriramph.mirrormirror").publicCloudDatabase.record(for: recordID) else { return nil }
        if let data = record["payload"] as? Data { return try? key.open(CloudEventInfo.self, from: data) }
        return nil
    }

    private static func apply(_ info: CloudEventInfo, cameraName: String, to content: UNMutableNotificationContent) {
        let event = info.event
        content.title = event.label
        content.subtitle = info.cameraName.isEmpty ? cameraName : info.cameraName
        content.body = "\(event.date.formatted(date: .omitted, time: .shortened)) · Tap to watch live or replay it."
        content.userInfo["eventDate"] = event.date.timeIntervalSince1970
        content.userInfo["eventKind"] = event.kind.rawValue
        content.relevanceScore = event.kind.isUrgent ? 1 : 0.5
        content.interruptionLevel = event.kind.isUrgent ? .timeSensitive : .active
    }
}
