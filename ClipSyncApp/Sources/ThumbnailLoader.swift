import AppKit
import ImageIO

/// Decodes downscaled, orientation-corrected images with ImageIO (which lets the JPEG decoder
/// skip most of the work), caching small thumbnails in memory.
final class ThumbnailLoader: @unchecked Sendable {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, NSImage>()

    init() {
        // Thumbnails are ~0.3-1 MB decoded, full-size viewer images ~20 MB; bound by bytes.
        cache.totalCostLimit = 400 * 1024 * 1024
    }

    func cached(_ url: URL, maxPixels: Int) -> NSImage? {
        cache.object(forKey: key(url, maxPixels))
    }

    func image(for url: URL, maxPixels: Int) async -> NSImage? {
        if let hit = cached(url, maxPixels: maxPixels) { return hit }
        let image = await Task.detached(priority: .userInitiated) { Self.decode(url, maxPixels: maxPixels) }.value
        if let image {
            let cost = Int(image.size.width * image.size.height) * 4
            cache.setObject(image, forKey: key(url, maxPixels), cost: cost)
        }
        return image
    }

    private func key(_ url: URL, _ maxPixels: Int) -> NSString {
        "\(maxPixels)|\(url.path)" as NSString
    }

    private static func decode(_ url: URL, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // apply the EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
