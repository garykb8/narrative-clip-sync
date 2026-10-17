import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ClipKit

@Test func orientationQuadrants() {
    #expect(PhotoOrganizer.orientation(x: -953, y: 171) == 1)   // worn upright
    #expect(PhotoOrganizer.orientation(x: -62, y: 906) == 6)
    #expect(PhotoOrganizer.orientation(x: 0, y: -1000) == 8)
    #expect(PhotoOrganizer.orientation(x: 900, y: 50) == 3)     // upside down
}

@Test func orientationFromMetaJSON() {
    let json = #"{ "acc_data": { "samples":[[828, -484, -171]] }, "trigger": "timer" }"#
    #expect(PhotoOrganizer.orientation(fromMetaJSON: Data(json.utf8)) == 3)
    #expect(PhotoOrganizer.orientation(fromMetaJSON: Data("{}".utf8)) == nil)
}

@Test func parsesShotDates() {
    let utc = ISO8601DateFormatter()
    #expect(PhotoOrganizer.date(fromEventName: "event_261009_124509_0123456789abcdef0123456789abcdef")
            == utc.date(from: "2026-10-09T12:45:09Z"))
    #expect(PhotoOrganizer.date(fromUploaderName: "20231228_075951_000") == utc.date(from: "2023-12-28T07:59:51Z"))
    #expect(PhotoOrganizer.date(fromEventName: "cid") == nil)
}

@Test func offsetStrings() {
    #expect(PhotoOrganizer.offsetString(8 * 3600) == "+08:00")
    #expect(PhotoOrganizer.offsetString(-(3 * 3600 + 1800)) == "-03:30")
}

@Test func organizeWritesExifLosslesslyAndIsIdempotent() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let original = dir.appendingPathComponent("original.jpg")
    try makeJPEG(at: original)
    let meta = dir.appendingPathComponent("original.meta.json")
    try Data(#"{ "acc_data": { "samples":[[-62, 906, -750]] } }"#.utf8).write(to: meta)

    let organizer = PhotoOrganizer(photosFolder: dir.appendingPathComponent("Photos"),
                                   timeZone: TimeZone(identifier: "Asia/Taipei")!)
    let shot = ISO8601DateFormatter().date(from: "2026-10-09T12:45:09Z")!
    let result = try organizer.organize(original: original, meta: meta, photoID: "event_A", shotDate: shot)
    guard case .created(let url) = result else { Issue.record("expected .created"); return }
    #expect(url.lastPathComponent == "2026-10-09 204509.jpg")

    let props = try #require(CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)
                                as? [String: Any])
    let exif = try #require(props[kCGImagePropertyExifDictionary as String] as? [String: Any])
    #expect(props[kCGImagePropertyOrientation as String] as? Int == 6)
    #expect(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String == "2026:10:09 20:45:09")
    #expect(exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String == "+08:00")
    #expect(PhotoOrganizer.photoID(of: url) == "event_A")
    #expect(try pixels(of: url) == pixels(of: original))
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect(attrs[.modificationDate] as? Date == shot)

    // Same photo again: recognised. A different photo shot in the same second: gets a suffix.
    #expect(try organizer.organize(original: original, meta: meta, photoID: "event_A", shotDate: shot) == .alreadyPresent(url))
    let second = try organizer.organize(original: original, meta: nil, photoID: "event_B", shotDate: shot)
    #expect(second == .created(dir.appendingPathComponent("Photos/2026-10-09 204509 (2).jpg")))
}

private func makeJPEG(at url: URL) throws {
    let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    for i in 0..<8 {
        ctx.setFillColor(CGColor(red: Double(i) / 8, green: 0.5, blue: 1 - Double(i) / 8, alpha: 1))
        ctx.fill(CGRect(x: i * 8, y: 0, width: 8, height: 48))
    }
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(dest))
}

/// Decoded pixels with orientation ignored, so a re-encode (lossy) would show up as a difference.
private func pixels(of url: URL) throws -> Data {
    let image = try #require(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil))
    return try #require(image.dataProvider?.data as Data?)
}
