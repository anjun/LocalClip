import CoreGraphics
import Foundation

/// One freehand mark in Quartz global coordinates, where y grows downward.
public struct ScreenshotInkStroke: Equatable, Sendable {
    public let points: [CGPoint]

    public init(points: [CGPoint]) {
        self.points = points
    }
}

/// One annotation on a locked screenshot selection, in Quartz global coordinates.
public enum ScreenshotMark: Equatable, Sendable {
    case pen(ScreenshotInkStroke)
    /// A hollow rectangle. The stroke is centered on this frame.
    case rectangle(CGRect)
}

/// Region confirmed by the selection overlay, including pen and rectangle marks.
public struct ScreenshotSelectionResult: Equatable, Sendable {
    public let region: CGRect
    public let marks: [ScreenshotMark]

    public init(region: CGRect, marks: [ScreenshotMark]) {
        self.region = region
        self.marks = marks
    }
}

public enum ScreenshotInkStyle {
    /// Logical points. Pixel renderers multiply by the capture scale.
    public static let lineWidth: CGFloat = 4
    public static let red: CGFloat = 0.98
    public static let green: CGFloat = 0.23
    public static let blue: CGFloat = 0.19
}

public enum ScreenshotInkElement: Equatable, Sendable {
    case dot(center: CGPoint)
    case move(CGPoint)
    case line(CGPoint)
    case quad(to: CGPoint, control: CGPoint)
}

public enum ScreenshotInkPath {
    /// Smooth a freehand polyline through segment midpoints. One point becomes
    /// a dot, so a click still leaves a mark. Non-finite points are dropped.
    public static func elements(for points: [CGPoint]) -> [ScreenshotInkElement] {
        let clean = points.filter { $0.x.isFinite && $0.y.isFinite }
        guard let first = clean.first else { return [] }
        if clean.count == 1 {
            return [.dot(center: first)]
        }
        var elements: [ScreenshotInkElement] = [.move(first)]
        if clean.count == 2 {
            elements.append(.line(clean[1]))
            return elements
        }
        for index in 1..<(clean.count - 1) {
            let control = clean[index]
            let next = clean[index + 1]
            let midpoint = CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2)
            elements.append(.quad(to: midpoint, control: control))
        }
        elements.append(.line(clean[clean.count - 1]))
        return elements
    }
}
