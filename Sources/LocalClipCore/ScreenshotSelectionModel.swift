import CoreGraphics
import Foundation

/// Window bounds and pointer positions use Quartz desktop coordinates:
/// the main display's top-left is the origin and y increases downwards.
public struct ScreenshotWindowCandidate: Equatable, Sendable {
    public let id: UInt32
    public let frame: CGRect

    public init(id: UInt32, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

public enum ScreenshotSelectionHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

/// Owns selection geometry independently of the capture overlay and AppKit.
public struct ScreenshotSelectionModel {
    public private(set) var selection: CGRect?
    public private(set) var isLocked = false

    public var confirmableRect: CGRect? {
        selection.flatMap { Self.isUsable($0) ? $0 : nil }
    }

    private static let minimumSize: CGFloat = 2
    private static let dragThreshold: CGFloat = 3
    private let desktopBounds: CGRect
    private let windows: [ScreenshotWindowCandidate]
    private var lastHover: CGPoint?
    private var activeDrag: Drag?

    private enum Drag {
        case pending(start: CGPoint, hover: CGRect?, wasLocked: Bool)
        case create(start: CGPoint)
        case move(start: CGPoint, original: CGRect)
        case resize(start: CGPoint, original: CGRect, handle: ScreenshotSelectionHandle)
    }

    public init(desktopBounds: CGRect, windows: [ScreenshotWindowCandidate]) {
        let bounds = desktopBounds.standardized
        let usableBounds = Self.isUsable(bounds) ? bounds : .zero
        self.desktopBounds = usableBounds
        self.windows = windows.compactMap { window in
            guard Self.isFinite(window.frame), !window.frame.isNull else { return nil }
            let frame = window.frame.standardized.intersection(usableBounds)
            guard Self.isUsable(frame) else { return nil }
            return ScreenshotWindowCandidate(id: window.id, frame: frame)
        }
    }

    public mutating func updateHover(at point: CGPoint) {
        guard !isLocked, activeDrag == nil else { return }
        lastHover = point
        selection = windowFrame(at: point)
    }

    public mutating func beginDrag(at point: CGPoint) {
        guard Self.isFinite(point), Self.isUsable(desktopBounds) else { return }
        if isLocked, let selection {
            if let handle = handle(at: point) {
                activeDrag = .resize(start: point, original: selection, handle: handle)
                return
            }
            if selection.contains(point) {
                activeDrag = .move(start: point, original: selection)
                return
            }
            // A click outside retains the selection; dragging starts a new one.
            activeDrag = .pending(start: point, hover: nil, wasLocked: true)
            return
        }
        updateHover(at: point)
        activeDrag = .pending(start: point, hover: selection, wasLocked: false)
    }

    public mutating func drag(to point: CGPoint) {
        guard Self.isFinite(point), let activeDrag else { return }
        switch activeDrag {
        case .pending(let start, _, _):
            guard hypot(point.x - start.x, point.y - start.y) > Self.dragThreshold else { return }
            self.activeDrag = .create(start: clamped(start))
            updateFreeSelection(from: clamped(start), to: point)
        case .create(let start):
            updateFreeSelection(from: start, to: point)
        case .move(let start, let original):
            let x = min(max(original.minX + point.x - start.x, desktopBounds.minX), desktopBounds.maxX - original.width)
            let y = min(max(original.minY + point.y - start.y, desktopBounds.minY), desktopBounds.maxY - original.height)
            selection = CGRect(origin: CGPoint(x: x, y: y), size: original.size)
        case .resize(let start, let original, let handle):
            selection = resized(original, handle: handle, delta: CGPoint(x: point.x - start.x, y: point.y - start.y))
        }
    }

    public mutating func endDrag(at point: CGPoint) {
        drag(to: point)
        if case .pending(_, let hover, let wasLocked) = activeDrag, !wasLocked {
            selection = hover
            isLocked = hover != nil
        }
        activeDrag = nil
        lastHover = point
    }

    public mutating func reset() {
        activeDrag = nil
        isLocked = false
        selection = lastHover.flatMap { windowFrame(at: $0) }
    }

    public func handle(at point: CGPoint, tolerance: CGFloat = 7) -> ScreenshotSelectionHandle? {
        guard isLocked, let selection, Self.isFinite(point), tolerance.isFinite, tolerance >= 0 else { return nil }
        var nearest: ScreenshotSelectionHandle?
        var nearestDistance = CGFloat.infinity
        for handle in ScreenshotSelectionHandle.allCases {
            let position = handlePosition(handle, in: selection)
            let distance = hypot(position.x - point.x, position.y - point.y)
            if distance <= tolerance, distance < nearestDistance {
                nearest = handle
                nearestDistance = distance
            }
        }
        if let nearest { return nearest }
        // Control points take priority; the rest of each border remains draggable.
        let edges: [(ScreenshotSelectionHandle, CGFloat, Bool)] = [
            (.top, abs(point.y - selection.minY), point.x >= selection.minX && point.x <= selection.maxX),
            (.right, abs(point.x - selection.maxX), point.y >= selection.minY && point.y <= selection.maxY),
            (.bottom, abs(point.y - selection.maxY), point.x >= selection.minX && point.x <= selection.maxX),
            (.left, abs(point.x - selection.minX), point.y >= selection.minY && point.y <= selection.maxY)
        ]
        for (handle, distance, isAlongEdge) in edges where isAlongEdge {
            if distance <= tolerance, distance < nearestDistance {
                nearest = handle
                nearestDistance = distance
            }
        }
        return nearest
    }

    private func windowFrame(at point: CGPoint) -> CGRect? {
        guard Self.isFinite(point), desktopBounds.contains(point) else { return nil }
        return windows.first(where: { $0.frame.contains(point) })?.frame
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, desktopBounds.minX), desktopBounds.maxX),
                y: min(max(point.y, desktopBounds.minY), desktopBounds.maxY))
    }

    private mutating func updateFreeSelection(from start: CGPoint, to point: CGPoint) {
        let end = clamped(point)
        let frame = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                           width: abs(start.x - end.x), height: abs(start.y - end.y))
        selection = Self.isUsable(frame) ? frame : nil
        isLocked = selection != nil
    }

    private func resized(_ original: CGRect, handle: ScreenshotSelectionHandle, delta: CGPoint) -> CGRect {
        var left = original.minX
        var right = original.maxX
        var top = original.minY
        var bottom = original.maxY
        switch handle {
        case .topLeft, .left, .bottomLeft:
            left = min(max(left + delta.x, desktopBounds.minX), right - Self.minimumSize)
        case .topRight, .right, .bottomRight:
            right = min(max(right + delta.x, left + Self.minimumSize), desktopBounds.maxX)
        case .top, .bottom:
            break
        }
        switch handle {
        case .topLeft, .top, .topRight:
            top = min(max(top + delta.y, desktopBounds.minY), bottom - Self.minimumSize)
        case .bottomLeft, .bottom, .bottomRight:
            bottom = min(max(bottom + delta.y, top + Self.minimumSize), desktopBounds.maxY)
        case .left, .right:
            break
        }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private func handlePosition(_ handle: ScreenshotSelectionHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        isFinite(rect) && !rect.isNull && rect.width >= minimumSize && rect.height >= minimumSize
    }

    private static func isFinite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        isFinite(rect.origin) && rect.width.isFinite && rect.height.isFinite
            && rect.maxX.isFinite && rect.maxY.isFinite
    }
}
