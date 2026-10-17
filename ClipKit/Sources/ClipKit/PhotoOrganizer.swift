import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Produces the browsable copy of a photo: one flat folder, named by local shooting time, with
/// EXIF date/time and orientation written in (losslessly - the JPEG data is not re-encoded).
///
/// The camera writes plain JFIF without EXIF, so without this every viewer would fall back to the
/// file's copy time and show worn-sideways shots unrotated.
public struct PhotoOrganizer {
    public let photosFolder: URL
    public var timeZone: TimeZone

    public init(photosFolder: URL, timeZone: TimeZone = .current) {
        self.photosFolder = photosFolder
        self.timeZone = timeZone
    }

    public enum Result: Equatable {
        case created(URL)
        case alreadyPresent(URL)
    }

    /// - Parameters:
    ///   - original: the camera's JPEG (left untouched).
    ///   - meta: the photo's `.meta.json`, used for orientation; nil leaves the image unrotated.
    ///   - photoID: a stable ID for the photo (its event name), stored in EXIF ImageUniqueID so a
    ///     second run recognises photos it already produced.
    ///   - shotDate: when the photo was taken.
    @discardableResult
    public func organize(original: URL, meta: URL?, photoID: String, shotDate: Date) throws -> Result {
        try FileManager.default.createDirectory(at: photosFolder, withIntermediateDirectories: true)
        let (existing, destination) = lookup(photoID: photoID, shotDate: shotDate)
        if let existing { return .alreadyPresent(existing) }

        let orientation = meta.flatMap { try? Data(contentsOf: $0) }.flatMap(Self.orientation(fromMetaJSON:)) ?? 1
        try writeJPEG(from: original, to: destination, photoID: photoID, shotDate: shotDate, orientation: orientation)
        try FileManager.default.setAttributes([.creationDate: shotDate, .modificationDate: shotDate],
                                              ofItemAtPath: destination.path)
        return .created(destination)
    }

    /// The stored copy of a photo, if any.
    public func existing(photoID: String, shotDate: Date) -> URL? {
        lookup(photoID: photoID, shotDate: shotDate).existing
    }

    /// Photos shot in the same second share a base name and get " (2)", " (3)"... suffixes;
    /// the EXIF photo ID tells them apart.
    private func lookup(photoID: String, shotDate: Date) -> (existing: URL?, free: URL) {
        let baseName = Self.fileNameFormatter(timeZone).string(from: shotDate)
        var candidate = photosFolder.appendingPathComponent("\(baseName).jpg")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            if Self.photoID(of: candidate) == photoID { return (candidate, candidate) }
            candidate = photosFolder.appendingPathComponent("\(baseName) (\(n)).jpg")
            n += 1
        }
        return (nil, candidate)
    }

    /// Parses the shooting time back out of a Photos/ file name.
    func fileNameDateParser() -> (String) -> Date? {
        let f = Self.fileNameFormatter(timeZone)
        return { name in name.count >= 17 ? f.date(from: String(name.prefix(17))) : nil }
    }

    private func writeJPEG(from source: URL, to destination: URL, photoID: String, shotDate: Date, orientation: Int) throws {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ClipError.protocolError("cannot read JPEG \(source.lastPathComponent)")
        }
        let exifDate = Self.exifDateFormatter(timeZone).string(from: shotDate)
        let offset = Self.offsetString(timeZone.secondsFromGMT(for: shotDate))
        let metadata: [String: Any] = [
            kCGImagePropertyOrientation as String: orientation,
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFOrientation as String: orientation,
                kCGImagePropertyTIFFDateTime as String: exifDate,
                kCGImagePropertyTIFFMake as String: "Narrative",
                kCGImagePropertyTIFFModel as String: "Narrative Clip",
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: exifDate,
                kCGImagePropertyExifDateTimeDigitized as String: exifDate,
                kCGImagePropertyExifOffsetTimeOriginal as String: offset,
                kCGImagePropertyExifOffsetTimeDigitized as String: offset,
                kCGImagePropertyExifImageUniqueID as String: photoID,
            ],
        ]

        let tmp = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).jpg")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ClipError.protocolError("cannot create \(tmp.path)")
        }
        let options: [String: Any] = [
            kCGImageDestinationMetadata as String: Self.imageMetadata(from: metadata),
            kCGImageDestinationMergeMetadata as String: true,
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, &error) else {
            try? FileManager.default.removeItem(at: tmp)
            throw ClipError.protocolError("cannot write EXIF for \(source.lastPathComponent): \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        try FileManager.default.moveItem(at: tmp, to: destination)
    }

    // MARK: Orientation

    /// EXIF orientation from the accelerometer sample in `.meta.json`. With θ = atan2(y, -x), the
    /// official Narrative app tagged its exports 1 / 6 / 3 / 8 by quadrant - this reproduces all
    /// 561 of its exports in this library exactly.
    static func orientation(fromMetaJSON data: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let acc = json["acc_data"] as? [String: Any],
              let sample = (acc["samples"] as? [[Double]])?.first, sample.count >= 2 else { return nil }
        return orientation(x: sample[0], y: sample[1])
    }

    static func orientation(x: Double, y: Double) -> Int {
        let theta = atan2(y, -x) * 180 / .pi
        switch theta {
        case -45...45: return 1
        case 45...135: return 6
        case -135 ... -45: return 8
        default: return 3
        }
    }

    // MARK: Helpers

    static func photoID(of url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] else { return nil }
        return exif[kCGImagePropertyExifImageUniqueID as String] as? String
    }

    private static func imageMetadata(from properties: [String: Any]) -> CGImageMetadata {
        let metadata = CGImageMetadataCreateMutable()
        func set(_ dict: CFString, _ key: CFString, _ value: Any) {
            CGImageMetadataSetValueMatchingImageProperty(metadata, dict, key, value as CFTypeRef)
        }
        for (dictKey, value) in properties {
            if let dict = value as? [String: Any] {
                for (key, v) in dict { set(dictKey as CFString, key as CFString, v) }
            }
        }
        let orientation = properties[kCGImagePropertyOrientation as String] ?? 1
        set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation)
        return metadata
    }

    private static func fileNameFormatter(_ tz: TimeZone) -> DateFormatter {
        formatter("yyyy-MM-dd HHmmss", tz)
    }

    private static func exifDateFormatter(_ tz: TimeZone) -> DateFormatter {
        formatter("yyyy:MM:dd HH:mm:ss", tz)
    }

    private static func formatter(_ format: String, _ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = tz
        f.dateFormat = format
        return f
    }

    static func offsetString(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let m = abs(seconds) / 60
        return String(format: "%@%02d:%02d", sign, m / 60, m % 60)
    }
}

// MARK: - Event names

extension PhotoOrganizer {
    /// Shooting time (UTC) from a camera event name, e.g. `event_261009_124509_<serial>`.
    static func date(fromEventName name: String) -> Date? {
        guard let m = name.firstMatch(of: /^event_(\d{6})_(\d{6})_/) else { return nil }
        return utcFormatter("yyMMddHHmmss").date(from: "\(m.1)\(m.2)")
    }

    /// Shooting time (UTC) from a Narrative Uploader export name, e.g. `20231228_075951_000`.
    static func date(fromUploaderName name: String) -> Date? {
        guard let m = name.firstMatch(of: /^(\d{8})_(\d{6})_\d{3}/) else { return nil }
        return utcFormatter("yyyyMMddHHmmss").date(from: "\(m.1)\(m.2)")
    }

    private static func utcFormatter(_ format: String) -> DateFormatter {
        formatter(format, TimeZone(identifier: "UTC")!)
    }
}
