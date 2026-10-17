import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ClipKit

private let taipei = TimeZone(identifier: "Asia/Taipei")!
private let shot = ISO8601DateFormatter().date(from: "2026-10-09T12:45:09Z")!
private let eventID = "event_261009_124509_0123456789abcdef0123456789abcdef"

/// A library in a temp folder whose "Trash" is a folder we can inspect.
private final class Fixture {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let library: PhotoLibrary
    var trashed: [String] = []

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        library = PhotoLibrary(root: dir.appendingPathComponent("Library"), timeZone: taipei)
        library.discard = { [unowned self] url in
            trashed.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }
    }

    deinit { try? FileManager.default.removeItem(at: dir) }
}

@Test func addVerifyListAndDelete() throws {
    let f = try Fixture()
    let jpeg = try jpegData(hue: 0.2)
    let meta = Data(#"{ "acc_data": { "samples":[[-953, 171, 156]] } }"#.utf8)
    let snap = Data([1, 2, 3])

    let url = try f.library.add(jpeg: jpeg, meta: meta, snap: snap, id: eventID, shotDate: shot)
    #expect(url.lastPathComponent == "2026-10-09 204509.jpg")
    #expect(f.library.verify(id: eventID, shotDate: shot, jpeg: jpeg, meta: meta, snap: snap))
    #expect(!f.library.verify(id: eventID, shotDate: shot, jpeg: try jpegData(hue: 0.7), meta: meta, snap: snap))
    #expect(!f.library.verify(id: eventID, shotDate: shot, jpeg: jpeg, meta: meta, snap: Data([9])))

    let photos = f.library.allPhotos()
    #expect(photos.map(\.day) == ["2026-10-09"])
    #expect(photos.first?.date == shot)

    try f.library.delete(photos)
    #expect(Set(f.trashed) == ["2026-10-09 204509.jpg", "\(eventID).meta.json", "\(eventID).meta.snap"])
    #expect(f.library.allPhotos().isEmpty)
    #expect(f.library.isDeleted(eventID))
    #expect(!f.library.isDeleted("event_other"))
}

@Test func importsBothOldLayoutsKeepingOneCopy() throws {
    let f = try Fixture()
    let originals = f.dir.appendingPathComponent("Originals", isDirectory: true)
    let fm = FileManager.default

    // The app's earlier layout: files side by side.
    let clipDay = originals.appendingPathComponent("clip_89abcdef/2026/10/09", isDirectory: true)
    try fm.createDirectory(at: clipDay, withIntermediateDirectories: true)
    try jpegData(hue: 0.1).write(to: clipDay.appendingPathComponent("\(eventID).jpg"))
    try Data("{}".utf8).write(to: clipDay.appendingPathComponent("\(eventID).meta.json"))
    try Data([7]).write(to: clipDay.appendingPathComponent("\(eventID).meta.snap"))
    try Data("{}".utf8).write(to: clipDay.appendingPathComponent("event_261009_124400_0123456789abcdef0123456789abcdef.time.json"))

    // Narrative Uploader export: metadata in meta/.
    let upDay = originals.appendingPathComponent("Uploader/clip_89abcdef/2023/12/28", isDirectory: true)
    try fm.createDirectory(at: upDay.appendingPathComponent("meta"), withIntermediateDirectories: true)
    try jpegData(hue: 0.5).write(to: upDay.appendingPathComponent("20231228_075951_000.jpg"))
    try Data("{}".utf8).write(to: upDay.appendingPathComponent("meta/20231228_075951_000.meta.json"))
    try Data("{}".utf8).write(to: upDay.appendingPathComponent("meta/20231228_080000_000.meta.json")) // photo discarded by old app

    let report = f.library.importOriginals(at: originals)
    #expect(report.failed.isEmpty)
    #expect(report.imported == 2)
    #expect(report.otherFilesKept == 2)
    #expect(f.library.allPhotos().map(\.id) == ["2023-12-28 155951.jpg", "2026-10-09 204509.jpg"])
    #expect(fm.fileExists(atPath: f.library.metadataFolder.appendingPathComponent("\(eventID).meta.snap").path))
    #expect(fm.fileExists(atPath: f.library.metadataFolder.appendingPathComponent("20231228_075951_000.meta.json").path))
    #expect(f.trashed.contains("\(eventID).jpg") && f.trashed.contains("20231228_075951_000.jpg"))
    #expect(f.trashed.last == "Originals")
}

private func jpegData(hue: Double) throws -> Data {
    let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: hue, green: 1 - hue, blue: 0.5, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(dest))
    return data as Data
}
