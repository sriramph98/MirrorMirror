import Foundation
import Combine
import os

/// Owns the on-disk recordings library: MP4 segments, event thumbnails and an `index.json`
/// describing both. All mutations are thread-safe; `@Published` properties update on main.
final class RecordingStore: ObservableObject {
    static let shared = RecordingStore()

    let directory: URL

    @Published private(set) var segments: [RecordingSegment] = []
    @Published private(set) var events: [CameraEvent] = []
    @Published private(set) var totalBytes: Int64 = 0

    private struct Index: Codable {
        var segments: [RecordingSegment]
        var events: [CameraEvent]
    }

    private static let log = Logger(subsystem: "Mira", category: "RecordingStore")
    private static let maxEvents = 5000
    private static let orphanAge: TimeInterval = 10 * 60
    /// Status events don't describe anything in the scene, so they don't keep footage alive.
    private static let nonSceneKinds: Set<EventKind> = [.lowBattery, .overheating]

    private let fileManager = FileManager.default
    private let indexURL: URL
    private let ioQueue = DispatchQueue(label: "RecordingStore.io", qos: .utility)

    // Guarded by `lock`.
    private let lock = NSLock()
    private var storedSegments: [RecordingSegment] = []
    private var storedEvents: [CameraEvent] = []
    private var saveScheduled = false
    private var publishScheduled = false

    private static let fileNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        self.directory = dir
        indexURL = dir.appendingPathComponent("index.json")

        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            var mutableDir = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try mutableDir.setResourceValues(values)
        } catch {
            Self.log.error("Could not prepare recordings directory: \(error.localizedDescription)")
        }

        let (loadedSegments, loadedEvents, dirty) = loadAndReconcile()
        storedSegments = loadedSegments
        storedEvents = loadedEvents
        segments = loadedSegments
        events = loadedEvents
        totalBytes = Self.sum(loadedSegments)
        if dirty { scheduleSave() }
    }

    // MARK: - Snapshots & paths

    func segmentsSnapshot() -> [RecordingSegment] {
        lock.withLock { storedSegments }
    }

    func eventsSnapshot() -> [CameraEvent] {
        lock.withLock { storedEvents }
    }

    func url(for segment: RecordingSegment) -> URL {
        directory.appendingPathComponent(segment.fileName)
    }

    func thumbnailURL(for event: CameraEvent) -> URL? {
        event.thumbnailFile.map { directory.appendingPathComponent($0) }
    }

    func newSegmentURL(start: Date) -> URL {
        let stamp = Self.fileNameFormatter.string(from: start)
        let short = UUID().uuidString.prefix(8).lowercased()
        return directory.appendingPathComponent("seg-\(stamp)-\(short).mp4")
    }

    // MARK: - Mutations

    func add(_ segment: RecordingSegment) {
        lock.withLock {
            if let existing = storedSegments.firstIndex(where: { $0.id == segment.id }) {
                storedSegments.remove(at: existing)
            }
            let index = storedSegments.firstIndex(where: { $0.start > segment.start }) ?? storedSegments.endIndex
            storedSegments.insert(segment, at: index)
        }
        didMutate()
    }

    @discardableResult
    func addEvent(_ event: CameraEvent, thumbnailJPEG: Data?) -> CameraEvent {
        var event = event
        if let jpeg = thumbnailJPEG {
            let name = "thumb-\(event.id.uuidString.lowercased()).jpg"
            do {
                try jpeg.write(to: directory.appendingPathComponent(name), options: .atomic)
                event.thumbnailFile = name
            } catch {
                Self.log.error("Could not write event thumbnail: \(error.localizedDescription)")
                event.thumbnailFile = nil
            }
        }
        lock.withLock {
            if let existing = storedEvents.firstIndex(where: { $0.id == event.id }) {
                storedEvents.remove(at: existing)
            }
            let index = storedEvents.firstIndex(where: { $0.date > event.date }) ?? storedEvents.endIndex
            storedEvents.insert(event, at: index)
        }
        didMutate()
        return event
    }

    func delete(_ segment: RecordingSegment) {
        let removed: Bool = lock.withLock {
            guard let i = storedSegments.firstIndex(where: { $0.id == segment.id }) else { return false }
            storedSegments.remove(at: i)
            return true
        }
        guard removed else { return }
        removeFiles([url(for: segment)])
        didMutate()
    }

    func deleteEvent(_ event: CameraEvent) {
        let removed: CameraEvent? = lock.withLock {
            guard let i = storedEvents.firstIndex(where: { $0.id == event.id }) else { return nil }
            return storedEvents.remove(at: i)
        }
        guard let removed else { return }
        removeFiles([thumbnailURL(for: removed)].compactMap { $0 })
        didMutate()
    }

    /// Deletes every indexed segment and event. A segment that is still being written is not in
    /// the index and is left alone; it gets added when the recorder finishes it.
    func deleteAll() {
        let (oldSegments, oldEvents) = lock.withLock { () -> ([RecordingSegment], [CameraEvent]) in
            defer { storedSegments = []; storedEvents = [] }
            return (storedSegments, storedEvents)
        }
        removeFiles(oldSegments.map(url(for:)) + oldEvents.compactMap(thumbnailURL(for:)))
        didMutate()
    }

    func enforceRetention(capBytes: Int64, mode: RecordingMode) {
        let now = Date()
        let (droppedSegments, droppedEvents) = lock.withLock { () -> ([RecordingSegment], [CameraEvent]) in
            var dropped: [RecordingSegment] = []

            if mode == .events {
                let eventDates = storedEvents.filter { !Self.nonSceneKinds.contains($0.kind) }.map(\.date)
                let ageCutoff = now.addingTimeInterval(-120)
                storedSegments.removeAll { segment in
                    guard segment.end < ageCutoff else { return false }
                    let lower = segment.start.addingTimeInterval(-5)
                    let upper = segment.end.addingTimeInterval(15)
                    let i = Self.firstIndex(in: eventDates) { $0 >= lower }
                    let keep = i < eventDates.count && eventDates[i] <= upper
                    if !keep { dropped.append(segment) }
                    return !keep
                }
            }

            var total = Self.sum(storedSegments)
            var overflow = 0
            while overflow < storedSegments.count, total > max(0, capBytes) {
                total -= storedSegments[overflow].byteSize
                overflow += 1
            }
            dropped += storedSegments.prefix(overflow)
            storedSegments.removeFirst(overflow)

            var droppedEvents: [CameraEvent] = []
            if let oldest = storedSegments.first {
                let cutoff = oldest.start.addingTimeInterval(-3600)
                let count = Self.firstIndex(in: storedEvents) { $0.date >= cutoff }
                droppedEvents += storedEvents.prefix(count)
                storedEvents.removeFirst(count)
            }
            if storedEvents.count > Self.maxEvents {
                let excess = storedEvents.count - Self.maxEvents
                droppedEvents += storedEvents.prefix(excess)
                storedEvents.removeFirst(excess)
            }
            return (dropped, droppedEvents)
        }

        guard !droppedSegments.isEmpty || !droppedEvents.isEmpty else { return }
        removeFiles(droppedSegments.map(url(for:)) + droppedEvents.compactMap(thumbnailURL(for:)))
        didMutate()
    }

    func locate(_ date: Date) -> (segment: RecordingSegment, offset: TimeInterval)? {
        let all = segmentsSnapshot()
        let i = Self.firstIndex(in: all) { $0.end > date }
        guard i < all.count else { return nil }
        let segment = all[i]
        return (segment, max(0, date.timeIntervalSince(segment.start)))
    }

    /// Writes the index immediately (e.g. when the app is about to be suspended).
    func flush() {
        ioQueue.sync { save() }
    }

    // MARK: - Private

    private func didMutate() {
        scheduleSave()
        schedulePublish()
    }

    /// Coalesces publishes; the main-thread block always reads the latest state, so updates
    /// arriving from several threads can't be published out of order.
    private func schedulePublish() {
        let shouldDispatch: Bool = lock.withLock {
            guard !publishScheduled else { return false }
            publishScheduled = true
            return true
        }
        guard shouldDispatch else { return }
        DispatchQueue.main.async { [self] in
            let (segs, evts) = lock.withLock { () -> ([RecordingSegment], [CameraEvent]) in
                publishScheduled = false
                return (storedSegments, storedEvents)
            }
            segments = segs
            events = evts
            totalBytes = Self.sum(segs)
        }
    }

    private func scheduleSave() {
        let shouldSchedule: Bool = lock.withLock {
            guard !saveScheduled else { return false }
            saveScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        ioQueue.asyncAfter(deadline: .now() + 1) { [self] in save() }
    }

    /// Runs on `ioQueue`.
    private func save() {
        let index = lock.withLock { () -> Index in
            saveScheduled = false
            return Index(segments: storedSegments, events: storedEvents)
        }
        do {
            let data = try JSONEncoder().encode(index)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            Self.log.error("Could not save recordings index: \(error.localizedDescription)")
        }
    }

    private func removeFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        ioQueue.async { [fileManager] in
            for url in urls {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// Loads `index.json` and reconciles it with the directory contents.
    /// Returns `dirty == true` when the index needs rewriting.
    private func loadAndReconcile() -> ([RecordingSegment], [CameraEvent], Bool) {
        var index = Index(segments: [], events: [])
        var dirty = false
        if let data = try? Data(contentsOf: indexURL) {
            do {
                index = try JSONDecoder().decode(Index.self, from: data)
            } catch {
                Self.log.error("Recordings index is unreadable, starting fresh: \(error.localizedDescription)")
                dirty = true
            }
        }

        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let files = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var onDisk: [String: (size: Int64, modified: Date)] = [:]
        for file in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            onDisk[file.lastPathComponent] = (Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }

        var segments: [RecordingSegment] = []
        for var segment in index.segments {
            guard let file = onDisk[segment.fileName] else { dirty = true; continue }
            if file.size != segment.byteSize {
                segment.byteSize = file.size
                dirty = true
            }
            segments.append(segment)
        }
        segments.sort { $0.start < $1.start }

        var events = index.events
        for i in events.indices {
            if let thumb = events[i].thumbnailFile, onDisk[thumb] == nil {
                events[i].thumbnailFile = nil
                dirty = true
            }
        }
        events.sort { $0.date < $1.date }

        let knownSegments = Set(segments.map(\.fileName))
        let knownThumbs = Set(events.compactMap(\.thumbnailFile))
        let orphanCutoff = Date().addingTimeInterval(-Self.orphanAge)
        for (name, file) in onDisk {
            let ext = (name as NSString).pathExtension.lowercased()
            let isOrphan: Bool
            switch ext {
            case "mp4": isOrphan = !knownSegments.contains(name) && file.modified < orphanCutoff
            case "jpg": isOrphan = !knownThumbs.contains(name)
            default: isOrphan = false
            }
            if isOrphan {
                try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            }
        }

        return (segments, events, dirty)
    }

    private static func sum(_ segments: [RecordingSegment]) -> Int64 {
        segments.reduce(0) { $0 + $1.byteSize }
    }

    /// Binary search: index of the first element satisfying a predicate that is monotonic
    /// (false…false, true…true) over the array. Returns `array.count` when none does.
    private static func firstIndex<T>(in array: [T], where predicate: (T) -> Bool) -> Int {
        var low = 0, high = array.count
        while low < high {
            let mid = (low + high) / 2
            if predicate(array[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
