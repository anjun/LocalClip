import CoreGraphics
import Foundation
import ImageIO
import LocalClipCore

extension LocalClipTestRunner {
    static func runScreenshotSnapshotTests() {
        typealias RGB = [UInt8]
        let red: RGB = [255, 0, 0], green: RGB = [0, 255, 0]
        let blue: RGB = [0, 0, 255], yellow: RGB = [255, 255, 0]
        let magenta: RGB = [255, 0, 255], cyan: RGB = [0, 255, 255]
        let gray: RGB = [80, 80, 80], orange: RGB = [255, 128, 0]

        // Provider rows are explicitly top-to-bottom, independent of CGContext's y-axis.
        func quadrants(width: Int, height: Int, colors: [RGB]) -> CGImage {
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let color = colors[(y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)]
                    let offset = (y * width + x) * 4
                    bytes[offset] = color[0]
                    bytes[offset + 1] = color[1]
                    bytes[offset + 2] = color[2]
                }
            }
            let provider = CGDataProvider(data: Data(bytes) as CFData)!
            return CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )!
        }

        func snapshot(_ frame: CGRect, _ image: CGImage) -> ScreenshotDisplaySnapshot {
            ScreenshotDisplaySnapshot(frame: frame, screenFrame: frame, image: image)
        }

        func decode(_ region: CGRect, _ snapshots: [ScreenshotDisplaySnapshot]) -> (CGImage, NSDictionary)? {
            guard let data = ScreenshotSnapshotRenderer.pngData(for: region, snapshots: snapshots),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) else {
                expect(false, "snapshot renders a decodable PNG for \(region)")
                return nil
            }
            return (image, properties as NSDictionary)
        }

        func expectPixel(_ image: CGImage, _ x: Int, _ y: Int, _ expected: RGB, _ message: String) {
            guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else {
                expect(false, message + " (pixel unavailable)")
                return
            }
            var bytes = [UInt8](repeating: 0, count: 4)
            let sampled = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                ) else { return false }
                context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return true
            }
            expect(sampled && zip(bytes.prefix(3), expected).allSatisfy {
                abs(Int($0.0) - Int($0.1)) <= 3
            } && bytes[3] == 255, message)
        }

        let frame = CGRect(x: 0, y: 0, width: 100, height: 80)
        let normal = snapshot(frame, quadrants(width: 100, height: 80, colors: [red, green, blue, yellow]))
        if let (image, _) = decode(frame, [normal]) {
            expect(image.width == 100 && image.height == 80, "1x display preserves full image dimensions")
            expectPixel(image, 10, 10, red, "full screenshot retains top-left red quadrant")
            expectPixel(image, 90, 10, green, "full screenshot retains top-right green quadrant")
            expectPixel(image, 10, 70, blue, "full screenshot retains bottom-left blue quadrant")
            expectPixel(image, 90, 70, yellow, "full screenshot retains bottom-right yellow quadrant")
        }
        if let (image, _) = decode(CGRect(x: 30, y: 20, width: 40, height: 40), [normal]) {
            expect(image.width == 40 && image.height == 40, "interior crop uses the selected logical size")
            expectPixel(image, 5, 5, red, "interior crop reads top-left source pixels")
            expectPixel(image, 35, 5, green, "interior crop reads top-right source pixels")
            expectPixel(image, 5, 35, blue, "interior crop does not flip the bottom-left pixels")
            expectPixel(image, 35, 35, yellow, "interior crop does not flip the bottom-right pixels")
        }
        let retina = snapshot(frame, quadrants(width: 200, height: 160, colors: [red, green, blue, yellow]))
        if let (image, properties) = decode(CGRect(x: 55, y: 45, width: 20, height: 15), [retina]) {
            expect(image.width == 40 && image.height == 30, "Retina crop preserves 2x pixel density")
            expectPixel(image, 20, 15, yellow, "Retina crop scales source coordinates before cropping")
            let dpiX = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 0
            let dpiY = (properties[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue ?? 0
            expect(abs(dpiX - 144) < 0.1 && abs(dpiY - 144) < 0.1, "Retina PNG records 144 DPI on both axes")
        }

        let left = snapshot(CGRect(x: -100, y: -20, width: 100, height: 80), normal.image)
        let right = snapshot(CGRect(x: 0, y: -20, width: 100, height: 80),
                             quadrants(width: 200, height: 160, colors: [magenta, cyan, gray, orange]))
        if let (image, _) = decode(CGRect(x: -30, y: -10, width: 60, height: 40), [left, right]) {
            expect(image.width == 120 && image.height == 80, "mixed displays compose at participating 2x density")
            expectPixel(image, 10, 10, green, "negative-coordinate 1x screen appears on the left")
            expectPixel(image, 58, 10, green, "1x screen scales to exactly half the composed width")
            expectPixel(image, 62, 10, magenta, "2x screen begins at the correct join")
            expectPixel(image, 110, 10, magenta, "2x screen retains its original relative size")
            expectPixel(image, 10, 70, yellow, "negative-coordinate screen retains vertical orientation")
            expectPixel(image, 110, 70, gray, "2x screen retains vertical orientation after composition")
        }
        if let (image, _) = decode(CGRect(x: -90, y: -10, width: 20, height: 15), [left, right]) {
            expect(image.width == 20 && image.height == 15, "nonparticipating Retina display does not upscale a 1x crop")
            expectPixel(image, 10, 5, red, "single negative-coordinate display crops correctly")
        }
        if let (image, _) = decode(CGRect(x: -10, y: -10, width: 40, height: 30), [normal]) {
            expect(image.width == 30 && image.height == 20, "offscreen selection clips to captured display content")
            expectPixel(image, 15, 10, red, "clipping preserves the first visible source pixels")
        }

        for region in [CGRect.zero, CGRect(x: 0, y: 0, width: 0, height: 10),
                       CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
                       CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10),
                       CGRect(x: 200, y: 200, width: 10, height: 10)] {
            expect(ScreenshotSnapshotRenderer.pngData(for: region, snapshots: [normal]) == nil,
                   "zero, invalid or wholly offscreen selection returns no PNG: \(region)")
        }
        expect(ScreenshotSnapshotRenderer.pngData(for: frame, snapshots: []) == nil,
               "missing frozen display content returns no PNG")
        let invalid = snapshot(.zero, normal.image)
        expect(ScreenshotSnapshotRenderer.pngData(for: frame, snapshots: [invalid]) == nil,
               "invalid display frame cannot produce a PNG")
        let distant = snapshot(CGRect(x: 100, y: -20, width: 100, height: 80), right.image)
        expect(ScreenshotSnapshotRenderer.pngData(
            for: CGRect(x: 20, y: 0, width: 40, height: 40), snapshots: [left, distant]
        ) == nil, "selection entirely in a gap between displays returns no PNG")
    }
}
