import TVServices

/// The Top Shelf: one "Cameras" section, a card per camera with its latest picture and event
/// (rendered into the image by the app), opening `mirrormirror://camera/<id>`. Reads the feed the
/// app writes into the App Group container; nothing here touches the network.
final class ContentProvider: TVTopShelfContentProvider {
    static let group = "group.com.sriramph.mirrormirror"
    static let fileName = "topshelf.json"

    /// Mirror of the app's `TopShelfSnapshot`.
    struct Snapshot: Codable {
        struct Camera: Codable {
            var id: String
            var name: String
            var eventLabel: String?
            var eventDate: Date?
            var thumbnailFile: String?
            var isLive: Bool
        }
        var cameras: [Camera]
        var updated: Date
    }

    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.group),
              let data = try? Data(contentsOf: container.appendingPathComponent(Self.fileName)) else {
            completionHandler(nil)
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data), !snapshot.cameras.isEmpty else {
            completionHandler(nil)
            return
        }

        let items = snapshot.cameras.map { camera -> TVTopShelfSectionedItem in
            let item = TVTopShelfSectionedItem(identifier: camera.id)
            item.title = Self.title(for: camera)
            item.imageShape = .hdtv
            if let file = camera.thumbnailFile {
                let url = container.appendingPathComponent(file)
                if FileManager.default.fileExists(atPath: url.path) {
                    item.setImageURL(url, for: [.screenScale1x, .screenScale2x])
                }
            }
            if let url = URL(string: "mirrormirror://camera/\(camera.id)") {
                item.displayAction = TVTopShelfAction(url: url)
                item.playAction = TVTopShelfAction(url: url)
            }
            return item
        }
        let section = TVTopShelfItemCollection(items: items)
        section.title = "Cameras"
        completionHandler(TVTopShelfSectionedContent(sections: [section]))
    }

    /// "Nursery · Motion 22:06" when something happened in the last day, otherwise just the name.
    private static func title(for camera: Snapshot.Camera) -> String {
        guard let label = camera.eventLabel, let date = camera.eventDate, Date().timeIntervalSince(date) < 24 * 3600 else {
            return camera.name
        }
        let time = date.formatted(.verbatim("\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                                            timeZone: .current, calendar: .current))
        return "\(camera.name) · \(label) \(time)"
    }
}
