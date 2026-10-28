import AppKit
import CoreGraphics
import Foundation

/// One selection session spanning the frozen images of every connected display.
/// All selection geometry stays in Quartz global points; each view translates
/// from its own flipped local coordinate system using that display's frame.
@MainActor
public final class ScreenshotSelectionController: NSObject, NSWindowDelegate {
    private let snapshots: [ScreenshotDisplaySnapshot]
    fileprivate var model: ScreenshotSelectionModel
    private var overlayWindows: [ScreenshotSelectionWindow] = []
    private var overlayViews: [ScreenshotSelectionView] = []
    private var continuation: CheckedContinuation<ScreenshotSelectionResult?, Never>?
    private var activeSession: UUID?
    private var screenObserver: NSObjectProtocol?
    private var appSwitchObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var previousApplication: NSRunningApplication?
    private var doubleClickStart: CGPoint?
    private var lastPointer: CGPoint?
    fileprivate var isDragging = false
    fileprivate var isPenEnabled = false
    fileprivate var isInking = false

    public init(snapshots: [ScreenshotDisplaySnapshot], windows: [ScreenshotWindowCandidate]) {
        self.snapshots = snapshots
        let desktopBounds = snapshots.reduce(CGRect.null) { $0.union($1.frame) }
        self.model = ScreenshotSelectionModel(desktopBounds: desktopBounds, windows: windows)
        super.init()
    }

    /// Returns the confirmed region and pen strokes, or nil when cancelled.
    public func select() async -> ScreenshotSelectionResult? {
        guard activeSession == nil, !snapshots.isEmpty, !Task.isCancelled else { return nil }
        let session = UUID()
        activeSession = session
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard self.activeSession == session, !Task.isCancelled else {
                    if self.activeSession == session { self.activeSession = nil }
                    continuation.resume(returning: nil)
                    return
                }
                self.continuation = continuation
                self.presentOverlays()
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.finish(with: nil, session: session)
            }
        }
    }

    private func presentOverlays() {
        previousApplication = NSWorkspace.shared.frontmostApplication
        model.reset()
        isDragging = false
        isInking = false
        isPenEnabled = false
        doubleClickStart = nil
        lastPointer = nil
        let session = activeSession
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish(with: nil, session: session) }
        }
        let previousPID = previousApplication?.processIdentifier
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        appSwitchObserver = workspaceNotifications.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.processIdentifier != previousPID else { return }
            Task { @MainActor [weak self] in self?.finish(with: nil, session: session) }
        }
        spaceObserver = workspaceNotifications.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish(with: nil, session: session) }
        }

        for snapshot in snapshots {
            let window = ScreenshotSelectionWindow(
                contentRect: snapshot.screenFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.hidesOnDeactivate = false
            window.becomesKeyOnlyIfNeeded = false
            window.animationBehavior = .none
            window.acceptsMouseMovedEvents = true
            window.isMovable = false
            window.sharingType = .none
            window.delegate = self
            let view = ScreenshotSelectionView(snapshot: snapshot, controller: self)
            window.contentView = view
            window.setFrame(snapshot.screenFrame, display: false)
            overlayWindows.append(window)
            overlayViews.append(view)
        }

        let mouse = NSEvent.mouseLocation
        let activeIndex = snapshots.firstIndex(where: { $0.screenFrame.contains(mouse) }) ?? 0
        let snapshot = snapshots[activeIndex]
        let initialPoint = CGPoint(
            x: snapshot.frame.minX + mouse.x - snapshot.screenFrame.minX,
            y: snapshot.frame.minY + snapshot.screenFrame.maxY - mouse.y
        )
        lastPointer = initialPoint
        model.updateHover(at: initialPoint)
        refreshOverlays()
        // The capture surface takes keyboard focus without activating LocalClip.
        // Activating the app here can change Spaces or the frozen window's appearance.
        for window in overlayWindows { window.orderFrontRegardless() }
        let activeWindow = overlayWindows[activeIndex]
        activeWindow.makeKeyAndOrderFront(nil)
        activeWindow.makeFirstResponder(overlayViews[activeIndex])
        NSCursor.crosshair.set()
    }

    fileprivate func movePointer(to point: CGPoint) {
        lastPointer = point
        model.updateHover(at: point)
        refreshOverlays()
        updateCursor(at: point)
    }

    fileprivate func beginStroke(at point: CGPoint) {
        guard isPenEnabled else { return }
        lastPointer = point
        if model.beginStroke(at: point) {
            isInking = true
        } else {
            model.endStroke()
            isInking = false
        }
        refreshOverlays()
        updateCursor(at: point)
    }

    fileprivate func extendStroke(to point: CGPoint) {
        guard isInking else { return }
        lastPointer = point
        model.extendStroke(to: point)
        refreshOverlays()
    }

    fileprivate func endStroke(at point: CGPoint) {
        guard isInking else { return }
        lastPointer = point
        model.extendStroke(to: point)
        model.endStroke()
        isInking = false
        refreshOverlays()
        updateCursor(at: point)
    }

    fileprivate func beginDrag(at point: CGPoint, clickCount: Int) {
        // A rapid second press can still start a drag. Complete a double-click
        // only on release, after ruling out movement.
        doubleClickStart = clickCount >= 2 && model.confirmableRect?.contains(point) == true ? point : nil
        model.updateHover(at: point)
        model.beginDrag(at: point)
        isDragging = true
        refreshOverlays()
        updateCursor(at: point)
    }

    fileprivate func drag(to point: CGPoint) {
        guard isDragging else { return }
        if let start = doubleClickStart, hypot(point.x - start.x, point.y - start.y) > 3 {
            doubleClickStart = nil
        }
        model.drag(to: point)
        refreshOverlays()
        updateCursor(at: point)
    }

    fileprivate func endDrag(at point: CGPoint) {
        guard isDragging else { return }
        let shouldConfirm = doubleClickStart.map { hypot(point.x - $0.x, point.y - $0.y) <= 3 } ?? false
        doubleClickStart = nil
        model.endDrag(at: point)
        isDragging = false
        if !model.isLocked {
            isPenEnabled = false
        }
        if shouldConfirm, model.confirmableRect?.contains(point) == true {
            confirmSelection()
            return
        }
        refreshOverlays()
        updateCursor(at: point)
    }

    fileprivate func resetSelection(at point: CGPoint) {
        isDragging = false
        isInking = false
        isPenEnabled = false
        doubleClickStart = nil
        lastPointer = point
        model.reset()
        model.updateHover(at: point)
        refreshOverlays()
        updateCursor(at: point)
    }

    @objc fileprivate func confirmSelection() {
        guard let rectangle = model.confirmableRect else { return }
        model.endStroke()
        isInking = false
        finish(with: ScreenshotSelectionResult(region: rectangle, strokes: model.strokes))
    }

    @objc fileprivate func cancelSelection() {
        finish(with: nil)
    }

    @objc fileprivate func togglePenMode() {
        guard model.isLocked else {
            isPenEnabled = false
            refreshOverlays()
            return
        }
        if isInking {
            model.endStroke()
            isInking = false
        }
        isPenEnabled.toggle()
        refreshOverlays()
        if let lastPointer {
            updateCursor(at: lastPointer)
        } else if isPenEnabled {
            NSCursor.crosshair.set()
        }
        focusCaptureSurface()
    }

    @objc fileprivate func undoInk() {
        model.undoStroke()
        isInking = false
        refreshOverlays()
        if let lastPointer {
            updateCursor(at: lastPointer)
        }
        focusCaptureSurface()
    }

    fileprivate func exitPenMode() {
        guard isPenEnabled || isInking else { return }
        if isInking {
            model.endStroke()
            isInking = false
        }
        isPenEnabled = false
        refreshOverlays()
        if let lastPointer {
            updateCursor(at: lastPointer)
        }
    }

    public func windowWillClose(_ notification: Notification) {
        finish(with: nil)
    }

    private func finish(with result: ScreenshotSelectionResult?, session: UUID? = nil) {
        guard let activeSession, session == nil || session == activeSession else { return }
        self.activeSession = nil
        let pending = continuation
        continuation = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        if let appSwitchObserver {
            workspaceNotifications.removeObserver(appSwitchObserver)
            self.appSwitchObserver = nil
        }
        if let spaceObserver {
            workspaceNotifications.removeObserver(spaceObserver)
            self.spaceObserver = nil
        }
        self.previousApplication = nil
        isDragging = false
        isInking = false
        isPenEnabled = false
        doubleClickStart = nil
        lastPointer = nil
        let windows = overlayWindows
        overlayWindows.removeAll()
        overlayViews.removeAll()
        for window in windows {
            window.delegate = nil
            window.contentView?.discardCursorRects()
            window.orderOut(nil)
            window.close()
        }
        NSCursor.arrow.set()
        pending?.resume(returning: result)
    }

    private func focusCaptureSurface() {
        let index = overlayWindows.firstIndex(where: { $0.isKeyWindow }) ?? 0
        guard overlayWindows.indices.contains(index) else { return }
        overlayWindows[index].makeFirstResponder(overlayViews[index])
    }

    private func refreshOverlays() {
        for view in overlayViews {
            view.refreshControls()
            view.needsDisplay = true
        }
    }

    private func updateCursor(at point: CGPoint) {
        if isPenEnabled {
            NSCursor.crosshair.set()
            return
        }
        guard model.isLocked else {
            NSCursor.crosshair.set()
            return
        }
        if let handle = model.handle(at: point) {
            switch handle {
            case .top, .bottom: NSCursor.resizeUpDown.set()
            case .left, .right: NSCursor.resizeLeftRight.set()
            case .topLeft, .topRight, .bottomLeft, .bottomRight: NSCursor.crosshair.set()
            }
        } else if model.selection?.contains(point) == true {
            (isDragging ? NSCursor.closedHand : NSCursor.openHand).set()
        } else {
            NSCursor.crosshair.set()
        }
    }
}

@MainActor
private final class ScreenshotSelectionWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class ScreenshotSelectionView: NSView {
    private let snapshot: ScreenshotDisplaySnapshot
    private let backgroundImage: NSImage
    private weak var controller: ScreenshotSelectionController?
    private var pointerTracking: NSTrackingArea?
    private let controls = NSView()
    private let statusLabel = NSTextField(labelWithString: "选择截图区域")
    private let hintLabel = NSTextField(labelWithString: "移动鼠标选窗口 · 拖动框选 · Esc 取消")
    private let confirmButton: NSButton
    private let cancelButton: NSButton
    private let penButton: NSButton
    private let undoButton: NSButton

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    init(snapshot: ScreenshotDisplaySnapshot, controller: ScreenshotSelectionController) {
        self.snapshot = snapshot
        self.backgroundImage = NSImage(cgImage: snapshot.image, size: snapshot.frame.size)
        self.controller = controller
        self.confirmButton = NSButton(title: "完成", target: controller, action: #selector(ScreenshotSelectionController.confirmSelection))
        self.cancelButton = NSButton(title: "取消", target: controller, action: #selector(ScreenshotSelectionController.cancelSelection))
        self.penButton = NSButton(title: "画笔", target: controller, action: #selector(ScreenshotSelectionController.togglePenMode))
        self.undoButton = NSButton(title: "撤销", target: controller, action: #selector(ScreenshotSelectionController.undoInk))
        super.init(frame: CGRect(origin: .zero, size: snapshot.screenFrame.size))
        autoresizingMask = [.width, .height]
        controls.wantsLayer = true
        controls.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.96).cgColor
        controls.layer?.cornerRadius = 10
        controls.layer?.borderWidth = 1
        controls.layer?.borderColor = NSColor(white: 1, alpha: 0.2).cgColor
        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = .white
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = NSColor(white: 0.85, alpha: 1)
        for label in [statusLabel, hintLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            controls.addSubview(label)
        }
        penButton.setButtonType(.toggle)
        penButton.toolTip = "圈出要标记的内容"
        undoButton.toolTip = "撤销最后一笔"
        penButton.refusesFirstResponder = true
        undoButton.refusesFirstResponder = true
        for button in [penButton, undoButton, cancelButton, confirmButton] {
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 13)
            controls.addSubview(button)
        }
        confirmButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
        controls.appearance = NSAppearance(named: .darkAqua)
        addSubview(controls)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let width = min(760, max(280, bounds.width - 32))
        controls.frame = CGRect(x: (bounds.width - width) / 2, y: max(16, bounds.height - 88), width: width, height: 68)
        // The ordinary controls view is unflipped, unlike the screenshot view.
        let buttons: [(NSButton, CGFloat)] = [
            (confirmButton, 72), (cancelButton, 64), (undoButton, 58), (penButton, 58)
        ]
        var buttonX = width - 12
        for (button, buttonWidth) in buttons {
            buttonX -= buttonWidth
            button.frame = CGRect(x: buttonX, y: 19, width: buttonWidth, height: 30)
            buttonX -= 6
        }
        let labelWidth = max(40, buttonX - 16)
        statusLabel.frame = CGRect(x: 16, y: 36, width: labelWidth, height: 18)
        hintLabel.frame = CGRect(x: 16, y: 14, width: labelWidth, height: 18)
    }

    fileprivate func refreshControls() {
        guard let controller else { return }
        let model = controller.model
        if let selection = model.selection {
            let dimensions = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))"
            statusLabel.stringValue = model.isLocked ? "已选择 \(dimensions)" : "单击选中窗口  \(dimensions)"
        } else {
            statusLabel.stringValue = "选择截图区域"
        }
        if controller.isPenEnabled {
            hintLabel.stringValue = "拖动圈出重点 · ⌘Z 撤销 · Enter 完成 · Esc 退出画笔"
        } else if model.isLocked {
            hintLabel.stringValue = model.canUndoInk
                ? "拖动调整 · ⌘Z 撤销标记 · 双击或 Enter 完成 · 右键重选"
                : "拖动调整 · 点画笔标记 · 双击或 Enter 完成 · 右键重选"
        } else {
            hintLabel.stringValue = "移动鼠标选窗口 · 拖动框选 · Esc 取消"
        }
        confirmButton.isEnabled = model.confirmableRect != nil
        penButton.isEnabled = model.isLocked
        penButton.state = controller.isPenEnabled ? .on : .off
        penButton.contentTintColor = controller.isPenEnabled ? .systemRed : nil
        undoButton.isEnabled = model.canUndoInk
        // While the pen is active, Esc leaves the pen. The cancel button would
        // otherwise consume Esc before the selection view sees it.
        cancelButton.keyEquivalent = controller.isPenEnabled ? "" : "\u{1b}"
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        pointerTracking = area
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        guard let controller else { return }
        let selection = controller.model.selection.map(localRect)
        let mask = NSBezierPath(rect: bounds)
        if let selection, !selection.isEmpty { mask.appendRect(selection) }
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.46).setFill()
        mask.fill()
        guard let selection, !selection.isEmpty else { return }

        drawInk(clippedTo: selection)
        NSColor.systemBlue.setStroke()
        let outline = NSBezierPath(rect: selection)
        outline.lineWidth = 2
        outline.stroke()
        if controller.model.isLocked, !controller.isPenEnabled {
            for point in handlePoints(for: selection) {
                let handle = NSBezierPath(roundedRect: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8), xRadius: 1, yRadius: 1)
                NSColor.white.setFill()
                handle.fill()
                NSColor.systemBlue.setStroke()
                handle.lineWidth = 1.5
                handle.stroke()
            }
        }
    }

    private func drawInk(clippedTo selection: CGRect) {
        guard let controller, !controller.model.inkStrokes.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: selection).setClip()
        NSColor(
            srgbRed: ScreenshotInkStyle.red,
            green: ScreenshotInkStyle.green,
            blue: ScreenshotInkStyle.blue,
            alpha: 1
        ).set()
        for stroke in controller.model.inkStrokes {
            draw(ScreenshotInkPath.elements(for: stroke.points.map { localPoint($0) }))
        }
    }

    private func draw(_ elements: [ScreenshotInkElement]) {
        let path = NSBezierPath()
        path.lineWidth = ScreenshotInkStyle.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        var hasPath = false
        var current = CGPoint.zero
        for element in elements {
            switch element {
            case .dot(let center):
                let radius = ScreenshotInkStyle.lineWidth / 2
                NSBezierPath(ovalIn: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )).fill()
            case .move(let point):
                path.move(to: point)
                current = point
                hasPath = true
            case .line(let point):
                path.line(to: point)
                current = point
            case .quad(let point, let control):
                // Quadratic curves arrived on NSBezierPath in macOS 14. The cubic
                // form below is the same curve and works on the supported OS.
                let first = CGPoint(
                    x: current.x + (control.x - current.x) * 2 / 3,
                    y: current.y + (control.y - current.y) * 2 / 3
                )
                let second = CGPoint(
                    x: point.x + (control.x - point.x) * 2 / 3,
                    y: point.y + (control.y - point.y) * 2 / 3
                )
                path.curve(to: point, controlPoint1: first, controlPoint2: second)
                current = point
            }
        }
        if hasPath {
            path.stroke()
        }
    }

    private func localRect(_ global: CGRect) -> CGRect {
        global.offsetBy(dx: -snapshot.frame.minX, dy: -snapshot.frame.minY)
    }

    private func localPoint(_ global: CGPoint) -> CGPoint {
        CGPoint(x: global.x - snapshot.frame.minX, y: global.y - snapshot.frame.minY)
    }

    private func globalPoint(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: snapshot.frame.minX + point.x, y: snapshot.frame.minY + point.y)
    }

    private func handlePoints(for rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)
        ]
    }

    override func mouseEntered(with event: NSEvent) {
        controller?.movePointer(to: globalPoint(for: event))
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.movePointer(to: globalPoint(for: event))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = globalPoint(for: event)
        if controller?.isPenEnabled == true {
            controller?.beginStroke(at: point)
            return
        }
        controller?.beginDrag(at: point, clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = globalPoint(for: event)
        if controller?.isInking == true {
            controller?.extendStroke(to: point)
            return
        }
        controller?.drag(to: point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = globalPoint(for: event)
        if controller?.isInking == true {
            controller?.endStroke(at: point)
            return
        }
        controller?.endDrag(at: point)
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.resetSelection(at: globalPoint(for: event))
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.shift),
           event.charactersIgnoringModifiers?.caseInsensitiveCompare("z") == .orderedSame {
            controller?.undoInk()
            return
        }
        switch event.keyCode {
        case 36, 76: controller?.confirmSelection()
        case 53:
            if controller?.isPenEnabled == true {
                controller?.exitPenMode()
            } else {
                controller?.cancelSelection()
            }
        default: super.keyDown(with: event)
        }
    }
}
