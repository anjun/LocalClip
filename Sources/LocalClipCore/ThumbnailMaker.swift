import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downscales clipboard images for list previews — never store full-resolution as thumbs.
/// Uses ImageIO only (thread-safe). Never NSImage / lockFocus — those crash off the main thread
/// when ClipboardMonitor ingests screenshots on its background queue.
public enum ThumbnailMaker {
    /// Max edge in pixels for list thumbs (≈ 44pt @2x with room).
    public static let maxPixel: CGFloat = 176
    public static let jpegQuality: CGFloat = 0.72
    /// Existing “thumbs” larger than this are treated as full dumps and regenerated.
    public static let maxThumbFileBytes: Int = 120_000

    /// Thread-safe JPEG thumbnail via CGImageSource thumbnail API.
    public static func makeJPEG(from imageData: Data, maxPixel: CGFloat = maxPixel) -> Data? {
        guard !imageData.isEmpty else { return nil }
        guard let source = CGImageSourceCreateWithData(imageData as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { return nil }

        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }

        return jpegData(from: cgImage, quality: jpegQuality)
    }

    /// Best-effort: original bytes if already tiny, else downscaled JPEG, else capped fallback.
    public static func preferredThumbData(from imageData: Data) -> Data {
        if imageData.count <= maxThumbFileBytes,
           let pixel = maxPixelSize(of: imageData),
           pixel <= maxPixel * 1.5 {
            return imageData
        }
        if let jpeg = makeJPEG(from: imageData) {
            return jpeg
        }
        // Decode failed: never keep multi‑MB garbage as a “thumb”.
        if imageData.count > maxThumbFileBytes {
            return Data(imageData.prefix(min(imageData.count, 1024)))
        }
        return imageData
    }

    /// Convert any ImageIO-readable image bytes to PNG (thread-safe).
    public static func pngData(from imageData: Data) -> Data? {
        guard !imageData.isEmpty else { return nil }
        guard let source = CGImageSourceCreateWithData(imageData as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { return nil }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { return nil }

        let destData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            destData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return destData as Data
    }

    // MARK: - Private

    private static func maxPixelSize(of imageData: Data) -> CGFloat? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        guard w > 0, h > 0 else { return nil }
        return CGFloat(max(w, h))
    }

    private static func jpegData(from cgImage: CGImage, quality: CGFloat) -> Data? {
        let destData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            destData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return destData as Data
    }
}
