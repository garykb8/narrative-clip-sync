import Foundation

/// Copies photos from the camera into the PhotoLibrary and, when asked, clears the camera.
///
/// Files sharing an `event_YYMMDD_HHMMSS_<serial>` prefix form one event; a photo event is
/// .jpg + .meta.json + .meta.snap. An event is only deleted from the camera once the library's
/// copy has been checked against a fresh read from the camera (same decoded pixels, identical
/// metadata). Photos the user deleted on the Mac are not downloaded again. Other events (.boot
/// and .time.json clock records) are never copied; when clearing the camera they are removed.
public final class SyncEngine {
    public static let defaultDestination = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/Narrative Clip", isDirectory: true)

    public struct Options: Sendable {
        public var destination: URL
        public var deleteFromCamera: Bool
        public var setClock: Bool

        public init(destination: URL = SyncEngine.defaultDestination, deleteFromCamera: Bool = false, setClock: Bool = true) {
            self.destination = destination
            self.deleteFromCamera = deleteFromCamera
            self.setClock = setClock
        }
    }

    public enum Progress: Sendable {
        case clockSet(previousOffset: TimeInterval)
        case scanned(events: Int, photosToTransfer: Int)
        case transferred(photo: String, done: Int, total: Int)
        case mismatch(photo: String)
        case deleted(event: String, files: Int)
    }

    public struct Summary: Sendable {
        public var cameraIdentifier = ""
        public var newPhotos: [URL] = []
        public var deletedFiles = 0
        /// Events that are safely on the Mac (or were deleted there) but still on the camera.
        public var eventsReadyToDelete = 0
        /// The subset of `eventsReadyToDelete` that are photos (the rest are .boot/.time records).
        public var photosReadyToDelete = 0
        public var mismatches = 0
    }

    struct CameraFile {
        let cameraPath: String
        let name: String
    }

    struct Event {
        let name: String
        var files: [CameraFile]

        func file(withSuffix suffix: String) -> CameraFile? { files.first { $0.name.hasSuffix(suffix) } }
        var isPhoto: Bool { file(withSuffix: ".jpg") != nil }
    }

    private let device: ClipDevice

    public init(device: ClipDevice) {
        self.device = device
    }

    public func run(_ options: Options, progress: (Progress) -> Void = { _ in }) throws -> Summary {
        var summary = Summary()
        let info = try device.info()
        summary.cameraIdentifier = info.identifier
        if options.setClock {
            try device.setTime()
            progress(.clockSet(previousOffset: info.clockOffset))
        }

        let library = PhotoLibrary(root: options.destination)
        let events = try scan()

        // A photo needs a download if it isn't in the library yet, or - before deleting it from
        // the camera - to check the library's copy against the camera. Photos the user deleted
        // on the Mac are skipped either way.
        func needsDownload(_ event: Event) -> Bool {
            guard event.isPhoto, !library.isDeleted(event.name), let date = PhotoOrganizer.date(fromEventName: event.name)
            else { return false }
            return options.deleteFromCamera || library.existingPhoto(id: event.name, shotDate: date) == nil
        }
        let total = events.filter(needsDownload).count
        progress(.scanned(events: events.count, photosToTransfer: total))

        var done = 0
        for event in events {
            var verified = false
            if needsDownload(event) {
                let date = PhotoOrganizer.date(fromEventName: event.name)!
                let jpeg = try device.readFile(event.file(withSuffix: ".jpg")!.cameraPath)
                let meta = try event.file(withSuffix: ".meta.json").map { try device.readFile($0.cameraPath) }
                let snap = try event.file(withSuffix: ".meta.snap").map { try device.readFile($0.cameraPath) }

                if library.existingPhoto(id: event.name, shotDate: date) == nil {
                    summary.newPhotos.append(try library.add(jpeg: jpeg, meta: meta, snap: snap, id: event.name, shotDate: date))
                }
                done += 1
                progress(.transferred(photo: event.name, done: done, total: total))
                guard library.verify(id: event.name, shotDate: date, jpeg: jpeg, meta: meta, snap: snap) else {
                    summary.mismatches += 1
                    progress(.mismatch(photo: event.name))
                    continue
                }
                verified = true
            }
            // Last line of defence: a photo leaves the camera only if it was just verified
            // against the library, or the user deliberately deleted it on the Mac.
            if event.isPhoto && !verified && !library.isDeleted(event.name) && options.deleteFromCamera { continue }

            if options.deleteFromCamera {
                for file in event.files {
                    try device.deleteFile(file.cameraPath)
                    summary.deletedFiles += 1
                }
                progress(.deleted(event: event.name, files: event.files.count))
            } else {
                summary.eventsReadyToDelete += 1
                if event.isPhoto { summary.photosReadyToDelete += 1 }
            }
        }
        return summary
    }

    func scan() throws -> [Event] {
        var events: [String: Event] = [:]
        for dir in try device.listDirectory(ClipDevice.storageRoot) where dir.isDirectory {
            let dirPath = "\(ClipDevice.storageRoot)/\(dir.name)"
            for entry in try device.listDirectory(dirPath) where !entry.isDirectory {
                guard let parsed = Self.parseEventFileName(entry.name) else { continue }
                let file = CameraFile(cameraPath: "\(dirPath)/\(entry.name)", name: entry.name)
                events["\(dirPath)/\(parsed.event)", default: Event(name: parsed.event, files: [])].files.append(file)
            }
        }
        return events.values.sorted { $0.name < $1.name }
    }

    /// `event_240126_084935_<32 hex>.meta.json` -> ("event_240126_084935_<32 hex>", "2024/01/26")
    static func parseEventFileName(_ name: String) -> (event: String, datePath: String)? {
        guard let m = name.wholeMatch(of: /(event_(\d{2})(\d{2})(\d{2})_\d{6}_[0-9a-f]{32})\..+/) else { return nil }
        return (String(m.1), "20\(m.2)/\(m.3)/\(m.4)")
    }
}
