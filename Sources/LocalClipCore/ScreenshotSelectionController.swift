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
    fileprivate var markupTool: ScreenshotMarkupTool = .none
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
        markupTool = .none
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
        guard markupTool == .pen else { return }
        lastPointer = point
        if model.beginStroke(at: point) {
            isInking = true
        } else {
            model.endActiveMark()
            isInking = false
        }
        refreshOverlays()
        updateCursor(at: point)
    }

    fileprivate func beginRectangle(at point: CGPoint) {
        guard markupTool == .rectangle else { return }
        lastPointer = point
        if model.beginRectangle(at: point) {
            isInking = true
        } else {
            model.endActiveMark()
            isInking = false
        }
        refreshOverlays()
        updateCursor(at: point)
    }

    fileprivate func extendRectangle(to point: CGPoint) {
        guard isInking, markupTool == .rectangle else { return }
        lastPointer = point
        model.extendRectangle(to: point)
        refreshOverlays()
    }

    fileprivate func endRectangle(at point: CGPoint) {
        guard isInking, markupTool == .rectangle else { return }
        lastPointer = point
        model.extendRectangle(to: point)
        model.endRectangle()
        isInking = false
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
            markupTool = .none
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
        markupTool = .none
        doubleClickStart = nil
        lastPointer = point
        model.reset()
        model.updateHover(at: point)
        refreshOverlays()
        updateCursor(at: point)
    }

    @objc fileprivate func confirmSelection() {
        guard let rectangle = model.confirmableRect else { return }
        model.endActiveMark()
        isInking = false
        finish(with: ScreenshotSelectionResult(region: rectangle, marks: model.marks))
    }

    @objc fileprivate func cancelSelection() {
        finish(with: nil)
    }

    @objc fileprivate func selectRectangleTool() {
        selectMarkupTool(.rectangle)
    }

    @objc fileprivate func selectPenTool() {
        selectMarkupTool(.pen)
    }

    private func selectMarkupTool(_ tool: ScreenshotMarkupTool) {
        guard model.isLocked else {
            markupTool = .none
            refreshOverlays()
            return
        }
        if isInking {
            model.endActiveMark()
            isInking = false
        }
        markupTool = markupTool == tool ? .none : tool
        refreshOverlays()
        if let lastPointer {
            updateCursor(at: lastPointer)
        } else if markupTool != .none {
            NSCursor.crosshair.set()
        }
        focusCaptureSurface()
    }

    @objc fileprivate func undoInk() {
        model.undoMark()
        isInking = false
        refreshOverlays()
        if let lastPointer {
            updateCursor(at: lastPointer)
        }
        focusCaptureSurface()
    }

    fileprivate func exitMarkupTool() {
        guard markupTool != .none || isInking else { return }
        if isInking {
            model.endActiveMark()
            isInking = false
        }
        markupTool = .none
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
        markupTool = .none
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
            view.invalidateOverlay()
        }
    }

    private func updateCursor(at point: CGPoint) {
        if markupTool != .none {
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

fileprivate enum ScreenshotMarkupTool: Equatable {
    case none
    case pen
    case rectangle
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
    private let toolbar = NSView()
    private let sizeChip = NSView()
    private let sizeLabel = NSTextField(labelWithString: "")
    private let divider = NSView()
    private let rectangleButton: NSButton
    private let penButton: NSButton
    private let undoButton: NSButton
    private let cancelButton: NSButton
    private let confirmButton: NSButton
    private let toolbarWidth: CGFloat = 195
    private let toolbarHeight: CGFloat = 40
    private var paintedOverlay: CGRect = .null
    private var didPaintFullFrame = false
    private var chromeToken = ""
    private var dragMonitor: Any?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    init(snapshot: ScreenshotDisplaySnapshot, controller: ScreenshotSelectionController) {
        self.snapshot = snapshot
        self.backgroundImage = NSImage(cgImage: snapshot.image, size: snapshot.frame.size)
        self.controller = controller
        self.rectangleButton = Self.iconButton(
            symbol: "rectangle", label: "方框",
            action: #selector(ScreenshotSelectionController.selectRectangleTool), target: controller
        )
        self.penButton = Self.iconButton(
            symbol: "pencil.tip", label: "画笔",
            action: #selector(ScreenshotSelectionController.selectPenTool), target: controller
        )
        self.undoButton = Self.iconButton(
            symbol: "arrow.uturn.backward", label: "撤销",
            action: #selector(ScreenshotSelectionController.undoInk), target: controller
        )
        self.cancelButton = Self.iconButton(
            symbol: "xmark", label: "取消",
            action: #selector(ScreenshotSelectionController.cancelSelection), target: controller
        )
        self.confirmButton = Self.iconButton(
            symbol: "checkmark", label: "完成",
            action: #selector(ScreenshotSelectionController.confirmSelection), target: controller
        )
        super.init(frame: CGRect(origin: .zero, size: snapshot.screenFrame.size))
        autoresizingMask = [.width, .height]
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.96).cgColor
        toolbar.layer?.cornerRadius = 10
        toolbar.layer?.borderWidth = 1
        toolbar.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        toolbar.appearance = NSAppearance(named: .darkAqua)
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 1, alpha: 0.22).cgColor
        let buttons = [rectangleButton, penButton, undoButton, cancelButton, confirmButton]
        for button in buttons {
            toolbar.addSubview(button)
        }
        toolbar.addSubview(divider)
        confirmButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
        // Toolbar coordinates stay unflipped; only its frame is placed in the flipped screenshot view.
        let buttonY: CGFloat = 4
        rectangleButton.frame = CGRect(x: 6, y: buttonY, width: 32, height: 32)
        penButton.frame = CGRect(x: 40, y: buttonY, width: 32, height: 32)
        divider.frame = CGRect(x: 80, y: 12, width: 1, height: 16)
        undoButton.frame = CGRect(x: 89, y: buttonY, width: 32, height: 32)
        cancelButton.frame = CGRect(x: 123, y: buttonY, width: 32, height: 32)
        confirmButton.frame = CGRect(x: 157, y: buttonY, width: 32, height: 32)
        toolbar.isHidden = true
        addSubview(toolbar)

        sizeChip.wantsLayer = true
        sizeChip.layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.96).cgColor
        sizeChip.layer?.cornerRadius = 6
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        sizeLabel.textColor = .white
        sizeLabel.alignment = .center
        sizeLabel.lineBreakMode = .byClipping
        sizeChip.addSubview(sizeLabel)
        sizeChip.isHidden = true
        addSubview(sizeChip)
    }

    private static func iconButton(symbol: String, label: String, action: Selector, target: AnyObject) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(config)
        button.contentTintColor = .white
        button.target = target
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.refusesFirstResponder = true
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        return button
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { endDragMonitor() }
    }

    override func layout() {
        super.layout()
        guard let controller, let selection = controller.model.selection else {
            toolbar.isHidden = true
            sizeChip.isHidden = true
            return
        }
        let local = localRect(selection)
        let chipHeight: CGFloat = 22
        let chipWidth: CGFloat = 92
        sizeLabel.frame = CGRect(x: 0, y: 2, width: chipWidth, height: 18)
        var chipX = local.minX
        var chipY = local.minY - chipHeight - 6
        if chipY < 8 { chipY = local.minY + 6 }
        chipX = min(max(8, chipX), max(8, bounds.width - chipWidth - 8))
        sizeChip.frame = CGRect(x: chipX, y: chipY, width: chipWidth, height: chipHeight)

        var toolX = local.maxX - toolbarWidth
        var toolY = local.maxY + 8
        if toolY + toolbarHeight > bounds.height - 8 {
            toolY = local.minY - toolbarHeight - 8
        }
        if toolY < 8 { toolY = 8 }
        toolX = min(max(8, toolX), max(8, bounds.width - toolbarWidth - 8))
        toolbar.frame = CGRect(x: toolX, y: toolY, width: toolbarWidth, height: toolbarHeight)
        updateChromeVisibility()
    }

    fileprivate func refreshControls() {
        guard let controller else { return }
        let model = controller.model
        let ink = NSColor(
            srgbRed: ScreenshotInkStyle.red,
            green: ScreenshotInkStyle.green,
            blue: ScreenshotInkStyle.blue,
            alpha: 1
        )
        style(rectangleButton, selected: controller.markupTool == .rectangle, accent: ink)
        style(penButton, selected: controller.markupTool == .pen, accent: ink)
        rectangleButton.isEnabled = model.isLocked
        penButton.isEnabled = model.isLocked
        confirmButton.isEnabled = model.confirmableRect != nil
        undoButton.isEnabled = model.canUndoInk
        confirmButton.contentTintColor = .white
        cancelButton.contentTintColor = .white
        // While a markup tool is active, Esc leaves that tool. The cancel button
        // would otherwise consume Esc before the selection view sees it.
        cancelButton.keyEquivalent = controller.markupTool == .none ? "\u{1b}" : ""
        updateChromeVisibility()
        // Relayout only when the chrome actually moves. A pen point must not
        // slide the toolbar under the cursor and drop the drag.
        let token = "\(model.selection?.debugDescription ?? "-")|\(model.isLocked)|\(controller.markupTool)|\(controller.isDragging)|\(controller.isInking)|\(sizeLabel.stringValue)"
        if token != chromeToken {
            chromeToken = token
            needsLayout = true
        }
    }

    fileprivate func invalidateOverlay() {
        refreshControls()
        let next = overlayDirtyRect()
        let dirty = paintedOverlay.isNull ? next : paintedOverlay.union(next)
        paintedOverlay = next
        guard didPaintFullFrame else {
            needsDisplay = true
            return
        }
        guard !dirty.isNull, !dirty.isEmpty else { return }
        setNeedsDisplay(dirty)
    }

    /// Hide the toolbar and size chip while the button is down. They follow the
    /// selection, and a view sliding under the pointer can end the drag early.
    private func updateChromeVisibility() {
        guard let controller else { return }
        let selection = controller.model.selection
        if controller.isDragging || controller.isInking || selection == nil {
            sizeChip.isHidden = true
            toolbar.isHidden = true
            if let selection {
                sizeLabel.stringValue = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))"
            } else {
                sizeLabel.stringValue = ""
            }
            return
        }
        sizeLabel.stringValue = "\(Int(selection!.width.rounded())) × \(Int(selection!.height.rounded()))"
        sizeChip.isHidden = !owns(selection!, atTopLeft: true)
        toolbar.isHidden = !controller.model.isLocked || !owns(selection!, atTopLeft: false)
    }

    private func overlayDirtyRect() -> CGRect {
        guard let controller else { return .null }
        var rect = CGRect.null
        if let selection = controller.model.selection {
            rect = rect.union(localRect(selection).insetBy(dx: -12, dy: -12))
        }
        for mark in controller.model.visibleMarks {
            switch mark {
            case .pen(let stroke):
                var box = CGRect.null
                for point in stroke.points {
                    box = box.union(CGRect(origin: localPoint(point), size: .zero))
                }
                if !box.isNull {
                    rect = rect.union(box.insetBy(dx: -8, dy: -8))
                }
            case .rectangle(let frame):
                rect = rect.union(localRect(frame).insetBy(dx: -8, dy: -8))
            }
        }
        return rect
    }

    private func style(_ button: NSButton, selected: Bool, accent: NSColor) {
        button.contentTintColor = selected ? accent : .white
        button.layer?.backgroundColor = selected ? NSColor.white.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
    }

    /// Top-left owns the size chip; bottom-right owns the toolbar, so a selection
    /// that crosses displays does not draw two copies.
    private func owns(_ selection: CGRect, atTopLeft: Bool) -> Bool {
        let insetX = min(0.5, selection.width / 2)
        let insetY = min(0.5, selection.height / 2)
        let point = atTopLeft
            ? CGPoint(x: selection.minX + insetX, y: selection.minY + insetY)
            : CGPoint(x: selection.maxX - insetX, y: selection.maxY - insetY)
        return snapshot.frame.contains(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        pointerTracking = area
    }

    override func draw(_ dirtyRect: NSRect) {
        let covered = dirtyRect.intersection(bounds)
        if covered.width >= bounds.width - 1, covered.height >= bounds.height - 1 {
            didPaintFullFrame = true
        }
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
        if controller.model.isLocked, controller.markupTool == .none {
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
        guard let controller, !controller.model.visibleMarks.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: selection).setClip()
        let color = NSColor(
            srgbRed: ScreenshotInkStyle.red,
            green: ScreenshotInkStyle.green,
            blue: ScreenshotInkStyle.blue,
            alpha: 1
        )
        color.set()
        for mark in controller.model.visibleMarks {
            switch mark {
            case .pen(let stroke):
                draw(ScreenshotInkPath.elements(for: stroke.points.map { localPoint($0) }))
            case .rectangle(let rect):
                let path = NSBezierPath(rect: localRect(rect))
                path.lineWidth = ScreenshotInkStyle.lineWidth
                path.lineJoinStyle = .miter
                path.stroke()
            }
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
        // A drag that has entered another display's overlay reports that window's
        // coordinates. Events delivered here, including tests, keep locationInWindow.
        if let eventWindow = event.window, eventWindow !== window {
            return globalPoint(fromScreen: eventWindow.convertPoint(toScreen: event.locationInWindow))
        }
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: snapshot.frame.minX + point.x, y: snapshot.frame.minY + point.y)
    }

    private func globalPoint(fromScreen screenPoint: NSPoint) -> CGPoint {
        CGPoint(
            x: snapshot.frame.minX + (screenPoint.x - snapshot.screenFrame.minX),
            y: snapshot.frame.minY + (snapshot.screenFrame.maxY - screenPoint.y)
        )
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
        applyPress(at: globalPoint(for: event), clickCount: event.clickCount)
        // Keep tracking after the pointer leaves this window. A nonactivating
        // panel stops sending mouseDragged once the cursor crosses onto another
        // display or off the overlay, which drops both resizing and pen strokes.
        // Tests inject mouseDragged directly and do not hold the button.
        guard Self.leftMouseIsDown else { return }
        beginDragMonitor()
    }

    override func mouseDragged(with event: NSEvent) {
        applyDrag(at: globalPoint(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        applyRelease(at: globalPoint(for: event))
        endDragMonitor()
    }

    private func applyPress(at point: CGPoint, clickCount: Int) {
        switch controller?.markupTool {
        case .pen:
            controller?.beginStroke(at: point)
        case .rectangle:
            controller?.beginRectangle(at: point)
        default:
            controller?.beginDrag(at: point, clickCount: clickCount)
        }
    }

    private func applyDrag(at point: CGPoint) {
        guard controller?.isInking == true else {
            controller?.drag(to: point)
            return
        }
        if controller?.markupTool == .rectangle {
            controller?.extendRectangle(to: point)
        } else {
            controller?.extendStroke(to: point)
        }
    }

    private func applyRelease(at point: CGPoint) {
        guard controller?.isInking == true else {
            controller?.endDrag(at: point)
            return
        }
        if controller?.markupTool == .rectangle {
            controller?.endRectangle(at: point)
        } else {
            controller?.endStroke(at: point)
        }
    }

    private func beginDragMonitor() {
        endDragMonitor()
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            // Events still inside this window go through mouseDragged / mouseUp.
            // Events that hit another overlay, or no window, would otherwise end the gesture.
            guard event.window !== self.window else { return event }
            let point = event.window == nil
                ? self.globalPoint(fromScreen: NSEvent.mouseLocation)
                : self.globalPoint(for: event)
            if event.type == .leftMouseUp {
                self.applyRelease(at: point)
                self.endDragMonitor()
                return nil
            }
            self.applyDrag(at: point)
            self.window?.displayIfNeeded()
            return nil
        }
    }

    private func endDragMonitor() {
        if let dragMonitor {
            NSEvent.removeMonitor(dragMonitor)
            self.dragMonitor = nil
        }
    }

    private static var leftMouseIsDown: Bool {
        NSEvent.pressedMouseButtons & 1 != 0
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
            if controller?.markupTool != ScreenshotMarkupTool.none {
                controller?.exitMarkupTool()
            } else {
                controller?.cancelSelection()
            }
        default: super.keyDown(with: event)
        }
    }
}
