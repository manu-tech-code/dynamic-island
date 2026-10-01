import AppKit
import ImageIO

/// Pictures decoded at the size they're shown, not their full size: a photo
/// on the shelf or a 6K desktop picture is tens of megabytes once decoded.
enum Thumbnail {
    /// The image at `url`, no bigger than `maxPixels` on its longer side.
    static func image(at url: URL, maxPixels: Int) -> NSImage? {
        CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary).flatMap { image(from: $0, maxPixels: maxPixels) }
    }

    /// The same, for an encoded image in memory.
    static func image(data: Data, maxPixels: Int) -> NSImage? {
        CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary).flatMap { image(from: $0, maxPixels: maxPixels) }
    }

    private static func image(from source: CGImageSource, maxPixels: Int) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}
