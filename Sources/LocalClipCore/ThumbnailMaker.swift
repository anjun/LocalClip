import AppKit
import Foundation

/// Downscales clipboard images for list previews — never store full-resolution as thumbs.
public enum ThumbnailMaker {
    /// Max edge in pixels for list thumbs (≈ 44pt @2x with room).
    public static let maxPixel: CGFloat = 176
    public static let jpegQuality: CGFloat = 0.72
    /// Existing “thumbs” larger than this are treated as full dumps and regenerated.
    public static let maxThumbFileBytes: Int = 120_000

    public static func makeJPEG(from imageData: Data, maxPixel: CGFloat = maxPixel) -> Data? {
        guard let source = NSImage(data: imageData) else { return nil }
        let size = source.size
        guard size.width > 0, size.height > 0 else { return nil }

        let scale = min(1, maxPixel / max(size.width, size.height))
        let target = NSSize(
            width: max(1, floor(size.width * scale)),
            height: max(1, floor(size.height * scale))
        )

        let out = NSImage(size: target)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .medium
        source.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1.0
        )
        out.unlockFocus()

        guard
            let tiff = out.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
        else { return nil }
        return jpeg
    }

    /// Best-effort: original bytes if already tiny, else downscaled JPEG, else original.
    public static func preferredThumbData(from imageData: Data) -> Data {
        if imageData.count <= maxThumbFileBytes,
           let img = NSImage(data: imageData),
           max(img.size.width, img.size.height) <= maxPixel * 1.5 {
            return imageData
        }
        if let jpeg = makeJPEG(from: imageData) {
            return jpeg
        }
        // Fallback: if decode failed, keep a tiny placeholder-sized write rather than multi‑MB.
        if imageData.count > maxThumbFileBytes {
            return Data(imageData.prefix(min(imageData.count, 1024)))
        }
        return imageData
    }
}
