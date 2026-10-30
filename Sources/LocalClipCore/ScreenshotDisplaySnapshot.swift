import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Frozen display content, with Quartz (top-left) and AppKit (bottom-left)
/// screen frames kept together. Image dimensions determine the Retina scale.
public struct ScreenshotDisplaySnapshot: @unchecked Sendable {
    public let frame: CGRect
    public let screenFrame: CGRect
    public let image: CGImage

    public init(frame: CGRect, screenFrame: CGRect, image: CGImage) {
        self.frame = frame
        self.screenFrame = screenFrame
        self.image = image
    }
}

public enum ScreenshotSnapshotRenderer {
    /// Crop the frozen content, never the selection overlay, then paint pen
    /// strokes and hollow rectangles. Mixed-scale displays are composed at the
    /// highest participating pixel density. Mark geometry uses the same Quartz
    /// coordinates as the region.
    public static func pngData(
        for requestedRegion: CGRect,
        snapshots: [ScreenshotDisplaySnapshot],
        marks: [ScreenshotMark] = []
    ) -> Data? {
        guard requestedRegion.width > 0, requestedRegion.height > 0,
              requestedRegion.minX.isFinite, requestedRegion.minY.isFinite,
              requestedRegion.width.isFinite, requestedRegion.height.isFinite else { return nil }
        let participating = snapshots.filter {
            $0.frame.width > 0 && $0.frame.height > 0
                && !$0.frame.intersection(requestedRegion).isNull
                && !$0.frame.intersection(requestedRegion).isEmpty
        }
        guard let first = participating.first else { return nil }
        let desktop = participating.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        let region = requestedRegion.intersection(desktop).integral
        guard !region.isNull, !region.isEmpty else { return nil }
        let scale = participating.map {
            max(CGFloat($0.image.width) / $0.frame.width, CGFloat($0.image.height) / $0.frame.height)
        }.max() ?? 1
        let pixelWidth = ceil(region.width * scale)
        let pixelHeight = ceil(region.height * scale)
        guard pixelWidth > 0, pixelHeight > 0,
              pixelWidth < CGFloat(Int.max), pixelHeight < CGFloat(Int.max),
              let context = CGContext(
                data: nil,
                width: Int(pixelWidth),
                height: Int(pixelHeight),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.interpolationQuality = .high

        for snapshot in participating {
            let intersection = region.intersection(snapshot.frame)
            guard !intersection.isEmpty, !intersection.isNull else { continue }
            let scaleX = CGFloat(snapshot.image.width) / snapshot.frame.width
            let scaleY = CGFloat(snapshot.image.height) / snapshot.frame.height
            let pixels = CGRect(
                x: (intersection.minX - snapshot.frame.minX) * scaleX,
                y: (intersection.minY - snapshot.frame.minY) * scaleY,
                width: intersection.width * scaleX,
                height: intersection.height * scaleY
            ).integral.intersection(CGRect(
                x: 0, y: 0, width: snapshot.image.width, height: snapshot.image.height
            ))
            guard let cropped = snapshot.image.cropping(to: pixels) else { return nil }
            let covered = CGRect(
                x: snapshot.frame.minX + pixels.minX / scaleX,
                y: snapshot.frame.minY + pixels.minY / scaleY,
                width: pixels.width / scaleX,
                height: pixels.height / scaleY
            )
            // CGContext is bottom-left based; image cropping is top-left based.
            let destination = CGRect(
                x: (covered.minX - region.minX) * scale,
                y: (region.maxY - covered.maxY) * scale,
                width: covered.width * scale,
                height: covered.height * scale
            )
            context.draw(cropped, in: destination)
        }
        if !marks.isEmpty {
            draw(marks, in: context, region: region, scale: scale)
        }

        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        let properties = [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Quartz y grows downward; the bitmap context's y grows upward.
    private static func draw(
        _ marks: [ScreenshotMark],
        in context: CGContext,
        region: CGRect,
        scale: CGFloat
    ) {
        guard scale > 0, scale.isFinite,
              let color = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [
                ScreenshotInkStyle.red, ScreenshotInkStyle.green, ScreenshotInkStyle.blue, 1
              ]) else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(color)
        context.setFillColor(color)
        let radius = ScreenshotInkStyle.lineWidth * scale / 2
        for mark in marks {
            switch mark {
            case .pen(let stroke):
                context.setLineWidth(ScreenshotInkStyle.lineWidth * scale)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                let points = stroke.points.map { map($0, region: region, scale: scale) }
                var hasPath = false
                for element in ScreenshotInkPath.elements(for: points) {
                    switch element {
                    case .dot(let center):
                        context.fillEllipse(in: CGRect(
                            x: center.x - radius,
                            y: center.y - radius,
                            width: radius * 2,
                            height: radius * 2
                        ))
                    case .move(let point):
                        context.beginPath()
                        context.move(to: point)
                        hasPath = true
                    case .line(let point):
                        context.addLine(to: point)
                    case .quad(let point, let control):
                        context.addQuadCurve(to: point, control: control)
                    }
                }
                if hasPath {
                    context.strokePath()
                }
            case .rectangle(let rect):
                let topLeft = map(CGPoint(x: rect.minX, y: rect.minY), region: region, scale: scale)
                let bottomRight = map(CGPoint(x: rect.maxX, y: rect.maxY), region: region, scale: scale)
                let box = CGRect(
                    x: min(topLeft.x, bottomRight.x),
                    y: min(topLeft.y, bottomRight.y),
                    width: abs(topLeft.x - bottomRight.x),
                    height: abs(topLeft.y - bottomRight.y)
                )
                guard box.width > 0, box.height > 0 else { continue }
                context.setLineWidth(ScreenshotInkStyle.lineWidth * scale)
                context.setLineCap(.butt)
                context.setLineJoin(.miter)
                context.stroke(box)
            }
        }
    }

    private static func map(_ point: CGPoint, region: CGRect, scale: CGFloat) -> CGPoint {
        CGPoint(
            x: (point.x - region.minX) * scale,
            y: (region.maxY - point.y) * scale
        )
    }
}
