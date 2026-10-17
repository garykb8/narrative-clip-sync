import Foundation
import ImageIO

/// The photo library on the Mac. Each photo is stored once:
///
///   Photos/<yyyy-MM-dd HHmmss>.jpg   the JPEG with EXIF date + orientation (see PhotoOrganizer);
///                                    EXIF ImageUniqueID holds the photo ID (its camera event name)
///   Metadata/<photo ID>.meta.json    the camera's sensor data for that photo
///   Metadata/<photo ID>.meta.snap    the camera's opaque blob for that photo
///   Metadata/deleted.txt             IDs deleted by the user, so sync won't bring them back
///   Metadata/Other/                  anything else kept from older layouts
public final class PhotoLibrary {
    public let root: URL
    public var photosFolder: URL { root.appendingPathComponent("Photos", isDirectory: true) }
    public var metadataFolder: URL { root.appendingPathComponent("Metadata", isDirectory: true) }
    var otherFolder: URL { metadataFolder.appendingPathComponent("Other", isDirectory: true) }
    private var tombstoneFile: URL { metadataFolder.appendingPathComponent("deleted.txt") }

    let organizer: PhotoOrganizer
    private let fm = FileManager.default
    /// How files are removed: moved to the Trash, so a mistake can be undone in Finder.
    var discard: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    public init(root: URL, timeZone: TimeZone = .current) {
        self.root = root
        organizer = PhotoOrganizer(photosFolder: root.appendingPathComponent("Photos", isDirectory: true), timeZone: timeZone)
    }

    // MARK: Browsing

    public struct Photo: Identifiable, Hashable, Sendable {
        public let url: URL
        public let date: Date
        /// `yyyy-MM-dd` in the library's time zone.
        public let day: String
        public var id: String { url.lastPathComponent }
    }

    /// All photos, oldest first. Dates come from the file names, so this needs no file reads.
    public func allPhotos() -> [Photo] {
        let names = (try? fm.contentsOfDirectory(atPath: photosFolder.path)) ?? []
        let parser = organizer.fileNameDateParser()
        return names.compactMap { name -> Photo? in
            guard name.lowercased().hasSuffix(".jpg"), let date = parser(name) else { return nil }
            return Photo(url: photosFolder.appendingPathComponent(name), date: date, day: String(name.prefix(10)))
        }
        .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
    }

    /// Moves photos and their metadata to the Trash and remembers their IDs so a later sync
    /// doesn't download them again from the camera. Returns how many photos were removed.
    @discardableResult
    public func delete(_ photos: [Photo]) throws -> Int {
        var ids: [String] = []
        for photo in photos {
            let id = PhotoOrganizer.photoID(of: photo.url)
            try discard(photo.url)
            if let id {
                ids.append(id)
                for url in metadataURLs(for: id) where fm.fileExists(atPath: url.path) {
                    try discard(url)
                }
            }
        }
        try addTombstones(ids)
        return photos.count
    }

    // MARK: Sync support

    func metadataURLs(for id: String) -> [URL] {
        ["meta.json", "meta.snap"].map { metadataFolder.appendingPathComponent("\(id).\($0)") }
    }

    func isDeleted(_ id: String) -> Bool {
        tombstones().contains(id)
    }

    func existingPhoto(id: String, shotDate: Date) -> URL? {
        organizer.existing(photoID: id, shotDate: shotDate)
    }

    /// Stores a photo downloaded from the camera.
    func add(jpeg: Data, meta: Data?, snap: Data?, id: String, shotDate: Date) throws -> URL {
        try fm.createDirectory(at: metadataFolder, withIntermediateDirectories: true)
        if let meta { try meta.write(to: metadataURLs(for: id)[0], options: .atomic) }
        if let snap { try snap.write(to: metadataURLs(for: id)[1], options: .atomic) }

        let staged = metadataFolder.appendingPathComponent(".\(id).jpg")
        try jpeg.write(to: staged, options: .atomic)
        defer { try? fm.removeItem(at: staged) }
        switch try organizer.organize(original: staged, meta: meta == nil ? nil : metadataURLs(for: id)[0],
                                      photoID: id, shotDate: shotDate) {
        case .created(let url), .alreadyPresent(let url): return url
        }
    }

    /// Whether the Mac holds a faithful copy of this camera photo: same decoded pixels (the stored
    /// JPEG only differs in its EXIF block) and byte-identical metadata files.
    func verify(id: String, shotDate: Date, jpeg: Data, meta: Data?, snap: Data?) -> Bool {
        guard let stored = existingPhoto(id: id, shotDate: shotDate),
              let storedPixels = Self.pixels(of: stored), storedPixels == Self.pixels(of: jpeg) else { return false }
        let urls = metadataURLs(for: id)
        return (meta == nil || (try? Data(contentsOf: urls[0])) == meta)
            && (snap == nil || (try? Data(contentsOf: urls[1])) == snap)
    }

    static func pixels(of url: URL) -> Data? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(pixels(of:))
    }

    static func pixels(of data: Data) -> Data? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(pixels(of:))
    }

    private static func pixels(of source: CGImageSource) -> Data? {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return image.dataProvider?.data as Data?
    }

    // MARK: Tombstones

    private func tombstones() -> Set<String> {
        guard let text = try? String(contentsOf: tombstoneFile, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map(String.init))
    }

    private func addTombstones(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try fm.createDirectory(at: metadataFolder, withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: tombstoneFile, encoding: .utf8)) ?? ""
        try (existing + ids.map { $0 + "\n" }.joined()).write(to: tombstoneFile, atomically: true, encoding: .utf8)
    }
}

// MARK: - Importing older layouts

extension PhotoLibrary {
    public struct ImportReport: Sendable {
        public var imported = 0
        public var alreadyPresent = 0
        public var otherFilesKept = 0
        public var failed: [String] = []
    }

    /// Moves a folder of camera originals into the library, keeping one copy of each photo.
    /// Understands the app's earlier `event_*.jpg` layout (+ sibling `.meta.json/.snap`) and
    /// Narrative Uploader exports (`YYYYMMDD_HHMMSS_000.jpg` + `meta/<same>.meta.json/.snap`).
    ///
    /// For each photo: write the EXIF copy into Photos/, check its decoded pixels match the
    /// original, move the metadata into Metadata/, and only then move the original JPEG to the
    /// Trash. Files that aren't part of a photo go to Metadata/Other/. Safe to re-run.
    ///
    /// - Parameter correctDate: adjusts a photo's (UTC) shooting time, e.g. for shots taken
    ///   while the camera clock was wrong.
    public func importOriginals(at originals: URL, correctDate: (Date) -> Date = { $0 },
                                progress: (String) -> Void = { _ in }) -> ImportReport {
        var report = ImportReport()
        let files = (fm.enumerator(at: originals, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL } ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.path < $1.path }

        for jpg in files where jpg.pathExtension.lowercased() == "jpg" {
            let stem = jpg.deletingPathExtension().lastPathComponent
            let dir = jpg.deletingLastPathComponent()
            let isEvent = stem.hasPrefix("event_")
            let metaDir = isEvent ? dir : dir.appendingPathComponent("meta", isDirectory: true)
            let sources = ["meta.json", "meta.snap"].map { metaDir.appendingPathComponent("\(stem).\($0)") }
            guard let date = isEvent ? PhotoOrganizer.date(fromEventName: stem) : PhotoOrganizer.date(fromUploaderName: stem) else {
                report.failed.append("\(jpg.path): no date in file name")
                continue
            }
            do {
                let meta = fm.fileExists(atPath: sources[0].path) ? sources[0] : nil
                let result = try organizer.organize(original: jpg, meta: meta, photoID: stem, shotDate: correctDate(date))
                let stored: URL
                switch result {
                case .created(let url): stored = url; report.imported += 1
                case .alreadyPresent(let url): stored = url; report.alreadyPresent += 1
                }
                guard let pixels = Self.pixels(of: stored), pixels == Self.pixels(of: jpg) else {
                    report.failed.append("\(jpg.path): stored copy does not match, original kept")
                    continue
                }
                try fm.createDirectory(at: metadataFolder, withIntermediateDirectories: true)
                for (source, destination) in zip(sources, metadataURLs(for: stem)) where fm.fileExists(atPath: source.path) {
                    if fm.fileExists(atPath: destination.path) {
                        guard fm.contentsEqual(atPath: source.path, andPath: destination.path) else {
                            throw ClipError.verificationFailed("\(destination.lastPathComponent) already exists with different content")
                        }
                        try fm.removeItem(at: source)
                    } else {
                        try fm.moveItem(at: source, to: destination)
                    }
                }
                try discard(jpg)
                progress("\(stored.lastPathComponent)  <-  \(jpg.lastPathComponent)")
            } catch {
                report.failed.append("\(jpg.path): \(error)")
            }
        }

        // Whatever is left (manifests, clock records, metadata of photos the old app discarded).
        for file in files where fm.fileExists(atPath: file.path) && file.lastPathComponent != ".DS_Store" {
            let relative = String(file.path.dropFirst(originals.path.count + 1))
            let destination = otherFolder.appendingPathComponent(originals.lastPathComponent).appendingPathComponent(relative)
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: destination.path) { try fm.moveItem(at: file, to: destination) }
                report.otherFilesKept += 1
            } catch {
                report.failed.append("\(file.path): \(error)")
            }
        }
        if report.failed.isEmpty { try? discard(originals) }
        return report
    }
}
