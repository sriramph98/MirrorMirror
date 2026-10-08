import Combine
import SwiftUI
import MirrorUI
import TVServices

// MARK: - Navigation

/// Which screen the TV shows. One screen at a time; the Menu button walks back to the wall.
enum TVScreen: Equatable {
    case wall
    case full(cameraID: String)
    case pair
    case settings
}

/// App-wide navigation and the alert banner. Lives for the whole app.
@MainActor
final class TVRouter: ObservableObject {
    @Published var screen: TVScreen = .wall
    struct Replay: Equatable {
        var cameraID: String
        var date: Date
    }
    /// Replay request for the full-screen view to pick up once connected.
    @Published var pendingReplay: Replay?
    /// Keeps one connection alive across the wall → full screen handoff.
    var keepConnected: String?

    struct Alert: Equatable {
        var event: CameraEvent
        var camera: PairedCamera
    }
    @Published var alert: Alert?
    private var alertTask: Task<Void, Never>?
    private var eventWatchers: [String: AnyCancellable] = [:]
    private var cameraWatcher: AnyCancellable?

    #if DEBUG
    /// Screenshot hooks (`mirrormirror://debug/...`), see `handle`.
    @Published var debugCommand: String?
    #endif

    func open(_ camera: PairedCamera, replayFrom date: Date? = nil) {
        if let date { pendingReplay = Replay(cameraID: camera.id, date: date) }
        keepConnected = camera.id
        screen = .full(cameraID: camera.id)
    }

    func raise(_ event: CameraEvent, from camera: PairedCamera) {
        alertTask?.cancel()
        alert = Alert(event: event, camera: camera)
        TopShelfFeed.shared.noteEvent()
        alertTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.alert = nil
        }
    }

    /// Raises a banner whenever any connection reports a fresh event, on whichever screen is up.
    func watchEvents(of hub: ViewerHub) {
        cameraWatcher = hub.$cameras
            .receive(on: RunLoop.main)
            .sink { [weak self, weak hub] cameras in
                guard let self, let hub else { return }
                let ids = Set(cameras.map(\.id))
                eventWatchers = eventWatchers.filter { ids.contains($0.key) }
                for camera in cameras where eventWatchers[camera.id] == nil {
                    let connection = hub.connection(for: camera)
                    eventWatchers[camera.id] = connection.$latestEvent
                        .compactMap { $0 }
                        .removeDuplicates()
                        .receive(on: RunLoop.main)
                        .sink { [weak self] event in
                            // Only things happening now; a reconnect replaying an old event isn't news.
                            guard Date().timeIntervalSince(event.date) < 90 else { return }
                            self?.raise(event, from: connection.camera)
                        }
                }
            }
    }

    func dismissAlert() {
        alertTask?.cancel()
        alert = nil
    }

    /// The banner's Replay: open that camera a few seconds before the event.
    func replayAlert() {
        guard let alert else { return }
        dismissAlert()
        open(alert.camera, replayFrom: alert.event.date.addingTimeInterval(-5))
    }

    /// `mirrormirror://camera/<id>` (Top Shelf), `mirrormirror://pair?...` (invite) and debug hooks.
    func handle(_ url: URL, hub: ViewerHub) {
        if let invite = PairingInvite(string: url.absoluteString) {
            let camera = hub.add(invite)
            open(camera)
            return
        }
        guard url.scheme == "mirrormirror" else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host {
        case "camera":
            if let id = parts.first, let camera = hub.camera(id: id) { open(camera) }
        #if DEBUG
        case "debug":
            debugCommand = parts.joined(separator: "/")
        #endif
        default:
            break
        }
    }
}

// MARK: - Debug hooks

/// Launch arguments for screenshots: `-MMScreen wall|full|pair|settings|timeline|events`.
enum TVDebug {
    #if DEBUG
    static let screen: String? = UserDefaults.standard.string(forKey: "MMScreen")
    #else
    static let screen: String? = nil
    #endif
}

// MARK: - Readout helpers

extension Date {
    /// "22:06:56": 24-hour clock for instrument readouts.
    var tvClock: String {
        formatted(.verbatim("\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
                            timeZone: .current, calendar: .current))
    }

    /// "22:06".
    var tvClockShort: String {
        formatted(.verbatim("\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                            timeZone: .current, calendar: .current))
    }

    /// Time only for today ("22:06:56"), otherwise "OCT 5 22:06".
    var tvStamp: String {
        Calendar.current.isDateInToday(self) ? tvClock : "\(formatted(.dateTime.month(.abbreviated).day())) \(tvClockShort)"
    }

    /// "Today" / "Yesterday" / "Oct 5".
    var tvDayLabel: String {
        if Calendar.current.isDateInToday(self) { return "Today" }
        if Calendar.current.isDateInYesterday(self) { return "Yesterday" }
        return formatted(.dateTime.month(.abbreviated).day())
    }
}

extension EventKind {
    /// LED / badge colour: urgent kinds are red, things seen are accent, things heard are info.
    var tvTint: Color {
        switch self {
        case .glassBreak, .alarm, .crying, .overheating: Palette.live
        case .lowBattery: Palette.warn
        case .sound, .barking: Palette.info
        case .motion, .person, .animal: Palette.accent
        }
    }
}

extension LinkStats.Path {
    var tvLabel: String {
        switch self {
        case .local: "Local"
        case .direct: "P2P"
        case .relay: "Relay"
        case .unknown: "Linking"
        }
    }
}

extension ViewerHub.Reachability {
    var label: String {
        switch self {
        case .localNetwork: "On network"
        case .online: "Online"
        case .offline: "Offline"
        case .unknown: "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .localNetwork, .online: Palette.ok
        case .offline, .unknown: Palette.textTertiary
        }
    }
}

extension CameraConnection {
    /// "1080 · 30 FPS · 4.1 MBPS" while connected.
    var tvStreamReadout: [String] {
        guard phase == .connected else { return [] }
        var items: [String] = []
        if let w = stats.width, let h = stats.height { items.append("\(min(w, h))") }
        if let fps = stats.fps { items.append("\(Int(fps.rounded())) fps") }
        if let bitrate = stats.bitrate {
            items.append(bitrate >= 1_000_000 ? String(format: "%.1f Mbps", bitrate / 1_000_000) : "\(Int(bitrate / 1000)) kbps")
        }
        return items
    }

    /// "LOCAL · 8 MS" / "Connecting" / "Offline".
    var tvPathReadout: [String] {
        switch phase {
        case .connected:
            var parts = [stats.path.tvLabel]
            if let rtt = stats.roundTrip { parts.append(rtt < 0.001 ? "<1 ms" : "\(Int(rtt * 1000)) ms") }
            return parts
        case .connecting: return ["Connecting"]
        case .failed: return ["Offline"]
        case .rejected: return ["Not allowed"]
        case .idle: return ["Idle"]
        }
    }

    /// "87%" plus a symbol, when the camera reports a battery.
    var tvBattery: (text: String, symbol: String, tint: Color)? {
        guard let status else { return nil }
        guard let level = status.batteryLevel ?? (status.isCharging ? 1 : nil) else { return nil }
        let text = status.batteryLevel.map { "\(Int($0 * 100))%" } ?? "Charging"
        let tint: Color = status.isCharging ? Palette.ok : (level < 0.2 ? Palette.warn : Palette.textPrimary)
        return (text, batterySymbol(status.batteryLevel, charging: status.isCharging), tint)
    }
}

extension Bundle {
    var tvVersionReadout: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

// MARK: - Top Shelf feed

/// What the Top Shelf extension shows: one card per camera. Mirrored in the extension target.
struct TopShelfSnapshot: Codable {
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

/// Writes `topshelf.json` and one JPEG per camera into the App Group container, so the Top Shelf
/// extension can show the latest picture and event without running any of the streaming stack.
@MainActor
final class TopShelfFeed {
    static let shared = TopShelfFeed()
    static let group = "group.com.sriramph.mirrormirror"
    static let fileName = "topshelf.json"

    private var hub: ViewerHub?
    private var task: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var lastWrite = Date.distantPast

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    func start(hub: ViewerHub) {
        self.hub = hub
        hub.$cameras.receive(on: RunLoop.main).sink { [weak self] _ in self?.write(force: true) }.store(in: &cancellables)
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.write(force: false)
            }
        }
    }

    /// Called on new events so the shelf shows them right away.
    func noteEvent() { write(force: true) }

    private func write(force: Bool) {
        guard let hub, let container = Self.container else { return }
        guard force || Date().timeIntervalSince(lastWrite) > 15 else { return }
        lastWrite = Date()
        var cameras: [TopShelfSnapshot.Camera] = []
        for camera in hub.cameras {
            let connection = hub.connection(for: camera)
            let event = connection.latestEvent ?? connection.events.last
            let fileName = "shelf-\(camera.id).jpg"
            let fileURL = container.appendingPathComponent(fileName)
            let hasFile = FileManager.default.fileExists(atPath: fileURL.path)
            var file: String? = hasFile ? fileName : nil
            // A card drawn from a real picture replaces the old one; the placeholder only fills a gap.
            if let image = Self.card(for: connection, event: event, placeholderAllowed: !hasFile) {
                try? image.write(to: fileURL, options: .atomic)
                file = fileName
            }
            cameras.append(.init(id: camera.id, name: camera.name, eventLabel: event?.label, eventDate: event?.date,
                                 thumbnailFile: file, isLive: connection.phase == .connected))
        }
        let snapshot = TopShelfSnapshot(cameras: cameras, updated: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: container.appendingPathComponent(Self.fileName), options: .atomic)
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    /// 16:9 card: the latest frame (or the event thumbnail), a dark base strip, the camera name
    /// in caps and the last event with its time. Rendered at 2× (1600×900).
    private static func card(for connection: CameraConnection, event: CameraEvent?, placeholderAllowed: Bool) -> Data? {
        let picture: UIImage? = {
            if connection.phase == .connected, let jpeg = connection.sink.snapshotJPEG(quality: 0.8), let image = UIImage(data: jpeg) {
                return image
            }
            if let event { return connection.thumbnail(for: event) }
            return nil
        }()
        guard picture != nil || placeholderAllowed else { return nil }
        let size = CGSize(width: 1600, height: 900)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            if let picture {
                // Aspect-fill.
                let scale = max(size.width / max(picture.size.width, 1), size.height / max(picture.size.height, 1))
                let drawSize = CGSize(width: picture.size.width * scale, height: picture.size.height * scale)
                let origin = CGPoint(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2)
                picture.draw(in: CGRect(origin: origin, size: drawSize))
            } else {
                // Lens ring placeholder when there's nothing to show yet.
                let ring = UIBezierPath(ovalIn: CGRect(x: size.width / 2 - 170, y: size.height / 2 - 230, width: 340, height: 340))
                ring.lineWidth = 26
                UIColor(red: 0xEE / 255, green: 0xED / 255, blue: 0x7C / 255, alpha: 0.9).setStroke()
                ring.stroke()
            }
            // Base strip.
            let strip = CGRect(x: 0, y: size.height - 220, width: size.width, height: 220)
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.withAlphaComponent(0.92).cgColor] as CFArray,
                                      locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(gradient, start: CGPoint(x: 0, y: strip.minY), end: CGPoint(x: 0, y: strip.maxY), options: [])
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let nameFont = UIFont(name: Fonts.groteskBold, size: 52) ?? .systemFont(ofSize: 52, weight: .bold)
            let name = NSAttributedString(string: connection.camera.name.uppercased(), attributes: [
                .font: nameFont, .kern: 6, .paragraphStyle: paragraph,
                .foregroundColor: UIColor(red: 0xF2 / 255, green: 0xF1 / 255, blue: 0xEC / 255, alpha: 1),
            ])
            name.draw(in: CGRect(x: 64, y: size.height - 170, width: size.width - 128, height: 64))
            let detail: String = {
                if let event {
                    let time = Calendar.current.isDateInToday(event.date) ? event.date.tvClockShort : event.date.tvStamp
                    return "\(event.label.uppercased())  ·  \(time)"
                }
                return connection.phase == .connected ? "LIVE" : "NO RECENT EVENTS"
            }()
            let detailFont = UIFont(name: Fonts.monoMedium, size: 40) ?? .monospacedSystemFont(ofSize: 40, weight: .medium)
            let detailColor = event != nil
                ? UIColor(red: 0xEE / 255, green: 0xED / 255, blue: 0x7C / 255, alpha: 1)
                : UIColor(red: 0xF2 / 255, green: 0xF1 / 255, blue: 0xEC / 255, alpha: 0.62)
            NSAttributedString(string: detail, attributes: [.font: detailFont, .kern: 2, .paragraphStyle: paragraph, .foregroundColor: detailColor])
                .draw(in: CGRect(x: 64, y: size.height - 96, width: size.width - 128, height: 52))
        }
        return image.jpegData(compressionQuality: 0.72)
    }
}

#if DEBUG
import Network

/// `-MMProbeBonjour`: logs what this Apple TV can see of `_mirror-mirror._tcp`, with and without
/// peer-to-peer, to tell simulator discovery problems from app problems.
enum TVBonjourProbe {
    private static var browsers: [NWBrowser] = []

    static func startIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-MMProbeBonjour") else { return }
        for p2p in [true, false] {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = p2p
            let browser = NWBrowser(for: .bonjour(type: "_mirror-mirror._tcp", domain: nil), using: parameters)
            browser.stateUpdateHandler = { state in DebugSupport.log("probe", "p2p=\(p2p) state \(state)") }
            browser.browseResultsChangedHandler = { results, _ in
                let names = results.compactMap { r -> String? in
                    if case let .service(name, _, _, _) = r.endpoint { return name }
                    return nil
                }
                DebugSupport.log("probe", "p2p=\(p2p) sees \(names.count): \(names.map { String($0.prefix(12)) })")
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }
}
#endif

#if DEBUG
extension TVRouter {
    /// Screenshot driver for the simulator, where there's no remote: polls
    /// `Documents/mm-debug.txt` in the app container and runs whatever one-line command it finds
    /// (`wall`, `pair`, `settings`, `open/<n>`, `alert`, or anything the screens handle through
    /// `debugCommand`: `focus/<n>`, `overlay`, `hide`, `timeline`, `events`, `next`, `prev`,
    /// `rewind`, `live`, `bar/<control>`).
    func startDebugChannel(hub: ViewerHub) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let file = documents.appendingPathComponent("mm-debug.txt")
        DebugSupport.log("tv", "debug channel at \(file.path)")
        Task { @MainActor [weak self, weak hub] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, let hub else { return }
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty else { continue }
                try? "".write(to: file, atomically: true, encoding: .utf8)
                DebugSupport.log("tv", "debug command \(command)")
                dispatchDebug(command, hub: hub)
            }
        }
    }

    private func dispatchDebug(_ command: String, hub: ViewerHub) {
        let parts = command.split(separator: "/").map(String.init)
        switch parts.first {
        case "wall": screen = .wall
        case "pair": screen = .pair
        case "settings": screen = .settings
        case "open":
            if parts.count > 1, let index = Int(parts[1]), hub.cameras.indices.contains(index) { open(hub.cameras[index]) }
        case "alert":
            if let camera = hub.cameras.first {
                raise(CameraEvent(date: Date(), kind: .person, label: "Person at the door", confidence: 0.92), from: camera)
            }
        case "alert-replay": replayAlert()
        default:
            debugCommand = nil
            DispatchQueue.main.async { self.debugCommand = command }
        }
    }
}
#endif
