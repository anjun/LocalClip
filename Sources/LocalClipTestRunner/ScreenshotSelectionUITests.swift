import AppKit
import CoreGraphics
import Foundation
import LocalClipCore

private final class ScreenshotUIRunState: @unchecked Sendable {
    var finished = false
    var cleanedUp = false
    var spaceChangeCount = 0
    var selectionTask: Task<ScreenshotSelectionResult?, Never>?
}

extension LocalClipTestRunner {
    /// Explicit local verification only; never included in the default test run.
    static func runScreenshotSelectionUITests() {
        let state = ScreenshotUIRunState()
        let deadline = Date().addingTimeInterval(8)
        let task = Task { @MainActor in
            let previousApp = NSWorkspace.shared.frontmostApplication
            let workspaceNotifications = NSWorkspace.shared.notificationCenter
            let spaceObserver = workspaceNotifications.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
                state.spaceChangeCount += 1
            }
            defer {
                workspaceNotifications.removeObserver(spaceObserver)
                state.selectionTask?.cancel()
                state.finished = true
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                    previousApp?.activate(options: .activateIgnoringOtherApps)
                }
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let screen = NSScreen.screens.first,
                  let context = CGContext(data: nil, width: 480, height: 320, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                expect(false, "UI test creates synthetic display")
                return
            }
            context.setFillColor(CGColor(red: 0.24, green: 0.34, blue: 0.48, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 320))
            context.setFillColor(CGColor(red: 0.34, green: 0.52, blue: 0.67, alpha: 1))
            context.fill(CGRect(x: 40, y: 120, width: 240, height: 160))
            guard let image = context.makeImage() else { expect(false, "UI test creates frozen image"); return }
            let screenFrame = CGRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.maxY - 360, width: 480, height: 320)
            let snapshot = ScreenshotDisplaySnapshot(frame: CGRect(x: 0, y: 0, width: 480, height: 320), screenFrame: screenFrame, image: image)
            let candidate = ScreenshotWindowCandidate(id: 1, frame: CGRect(x: 40, y: 40, width: 240, height: 160))
            var sessionFrontmostPID: pid_t?

            @MainActor func startSession() async -> NSWindow? {
                let controller = ScreenshotSelectionController(snapshots: [snapshot], windows: [candidate])
                let previousPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                sessionFrontmostPID = previousPID
                let wasActive = app.isActive
                let spaceChangesBefore = state.spaceChangeCount
                state.selectionTask = Task { await controller.select() }
                while Date() < deadline, !Task.isCancelled {
                    if let window = app.windows.first(where: {
                        $0.isVisible
                            && ($0.contentView.map { String(describing: type(of: $0)).contains("ScreenshotSelectionView") } ?? false)
                    }) {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                        print("UI entry trace: frontmost \(String(describing: previousPID)) -> \(String(describing: currentPID)); isActive \(wasActive) -> \(app.isActive)")
                        expect(currentPID == previousPID, "UI selector entry preserves frontmost application")
                        expect(state.spaceChangeCount == spaceChangesBefore, "UI selector entry does not change active Space")
                        expect(window.frame == screenFrame, "UI selector entry preserves display frame")
                        expect(window.contentView?.bounds == CGRect(origin: .zero, size: screenFrame.size), "UI selector entry preserves content bounds")
                        expect(window is NSPanel && window.styleMask.contains(.nonactivatingPanel), "UI selector uses a nonactivating panel")
                        expect(window.animationBehavior == .none, "UI selector disables window animation")
                        expect(window.isKeyWindow && app.keyWindow === window, "UI nonactivating panel receives keyboard focus")
                        expect(window.firstResponder === window.contentView, "UI selection view is the panel first responder")
                        return window
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                state.selectionTask?.cancel()
                expect(false, "UI test finds screenshot overlay before deadline")
                return nil
            }
            @MainActor func verifyClosed(_ window: NSWindow, _ message: String) {
                expect(!window.isVisible, message)
                expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == sessionFrontmostPID, "UI selector exit preserves frontmost application")
            }
            guard let window = await startSession(), let view = window.contentView else { return }
            @MainActor func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, clicks: Int = 1, targetWindow: NSWindow? = nil) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 320 - y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: (targetWindow ?? window).windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
            }
            @MainActor func findButton(_ title: String, in root: NSView) -> NSButton? {
                if let button = root as? NSButton,
                   button.title == title || button.toolTip == title || button.accessibilityLabel() == title {
                    return button
                }
                for subview in root.subviews {
                    if let found = findButton(title, in: subview) { return found }
                }
                return nil
            }
            @MainActor func clickButton(_ title: String, in root: NSView) {
                guard let button = findButton(title, in: root), button.isEnabled, button.superview?.isHidden == false else {
                    expect(false, "UI finds enabled \(title) button")
                    return
                }
                button.performClick(nil)
            }
            @MainActor func toolIsSelected(_ title: String, in root: NSView) -> Bool {
                guard let color = findButton(title, in: root)?.contentTintColor?.usingColorSpace(.sRGB) else { return false }
                return color.redComponent > 0.8 && color.greenComponent < 0.5
            }
            @MainActor func labels(_ view: NSView) -> [String] {
                (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap { labels($0) }
            }
            @MainActor func bitmap() -> NSBitmapImageRep? {
                view.layoutSubtreeIfNeeded()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
                view.cacheDisplay(in: view.bounds, to: rep)
                return rep
            }
            view.mouseMoved(with: mouse(.mouseMoved, 80, 80))
            expect(labels(view).contains("240 × 160"), "UI hover previews candidate window")
            expect(findButton("方框", in: view)?.superview?.isHidden == true, "UI hides the markup toolbar before the selection is locked")
            view.mouseDown(with: mouse(.leftMouseDown, 80, 80))
            view.mouseUp(with: mouse(.leftMouseUp, 80, 80))
            expect(labels(view).contains("240 × 160") && findButton("方框", in: view)?.superview?.isHidden == false,
                   "UI click locks candidate selection and shows the markup toolbar")
            if let rep = bitmap() {
                let handles = [CGPoint(x: 40, y: 40), CGPoint(x: 160, y: 40), CGPoint(x: 280, y: 40), CGPoint(x: 280, y: 120),
                               CGPoint(x: 280, y: 200), CGPoint(x: 160, y: 200), CGPoint(x: 40, y: 200), CGPoint(x: 40, y: 120)]
                let whiteHandles = handles.filter { point in
                    guard let color = rep.colorAt(x: Int(point.x * CGFloat(rep.pixelsWide) / 480), y: Int(point.y * CGFloat(rep.pixelsHigh) / 320))?.usingColorSpace(.deviceRGB) else { return false }
                    return color.redComponent > 0.85 && color.greenComponent > 0.85 && color.blueComponent > 0.85
                }
                expect(whiteHandles.count == 8, "UI locked selection draws all eight white resize handles")
            } else { expect(false, "UI locked selection renders bitmap") }
            view.mouseDown(with: mouse(.leftMouseDown, 280, 120, clicks: 2))
            view.mouseDragged(with: mouse(.leftMouseDragged, 340, 120))
            view.mouseUp(with: mouse(.leftMouseUp, 340, 120, clicks: 2))
            expect(window.isVisible && labels(view).contains("300 × 160"), "UI second-click edge drag resizes without confirming")
            do {
                guard let png = bitmap()?.representation(using: .png, properties: [:]) else {
                    expect(false, "UI resized selection renders PNG"); return
                }
                try png.write(to: URL(fileURLWithPath: "/private/tmp/localclip-screenshot-selector-ui.png"))
                expect(true, "UI snapshot saved for visual verification")
            } catch { expect(false, "UI snapshot write failed: \(error)") }
            view.mouseDown(with: mouse(.leftMouseDown, 100, 100, clicks: 2))
            view.mouseDragged(with: mouse(.leftMouseDragged, 120, 115))
            view.mouseUp(with: mouse(.leftMouseUp, 120, 115, clicks: 2))
            expect(window.isVisible, "UI second-click interior drag moves without confirming")
            clickButton("方框", in: view)
            expect(toolIsSelected("方框", in: view), "UI rectangle tool shows as the active markup tool")
            view.mouseDown(with: mouse(.leftMouseDown, 220, 80))
            view.mouseDragged(with: mouse(.leftMouseDragged, 280, 140))
            view.mouseUp(with: mouse(.leftMouseUp, 280, 140))
            if let rep = bitmap() {
                let scaleX = CGFloat(rep.pixelsWide) / 480
                let scaleY = CGFloat(rep.pixelsHigh) / 320
                func marked(_ x: CGFloat, _ y: CGFloat) -> Bool {
                    guard let color = rep.colorAt(x: Int(x * scaleX), y: Int(y * scaleY))?.usingColorSpace(.deviceRGB) else { return false }
                    return color.redComponent > 0.55
                        && color.redComponent > color.greenComponent
                        && color.redComponent > color.blueComponent
                }
                expect(marked(250, 80) || marked(250, 81) || marked(248, 80), "UI rectangle draws a red edge")
                expect(!marked(250, 110), "UI rectangle does not fill its interior")
            } else { expect(false, "UI rectangle renders bitmap") }
            clickButton("画笔", in: view)
            expect(toolIsSelected("画笔", in: view) && !toolIsSelected("方框", in: view), "UI pen replaces the rectangle tool")
            view.mouseDown(with: mouse(.leftMouseDown, 100, 120))
            view.mouseDragged(with: mouse(.leftMouseDragged, 200, 120))
            view.mouseUp(with: mouse(.leftMouseUp, 200, 120))
            if let rep = bitmap() {
                let scaleX = CGFloat(rep.pixelsWide) / 480
                let scaleY = CGFloat(rep.pixelsHigh) / 320
                func marked(_ x: CGFloat, _ y: CGFloat) -> Bool {
                    guard let color = rep.colorAt(x: Int(x * scaleX), y: Int(y * scaleY))?.usingColorSpace(.deviceRGB) else { return false }
                    return color.redComponent > 0.55
                        && color.redComponent > color.greenComponent
                        && color.redComponent > color.blueComponent
                }
                var found = false
                for y in [CGFloat(119), 120, 121] {
                    for x in stride(from: CGFloat(140), through: 170, by: 2) where marked(x, y) {
                        found = true
                    }
                }
                expect(found, "UI pen stroke is visible on the frozen selection")
            } else { expect(false, "UI pen stroke renders bitmap") }
            window.sendEvent(screenshotUIKey(36, "\r", window: window))
            let selection = await state.selectionTask?.value
            expect(selection?.region == CGRect(x: 60, y: 55, width: 300, height: 160), "UI move and Enter return adjusted Quartz rectangle")
            expect(selection?.marks.count == 2
                   && selection?.marks.first == .rectangle(CGRect(x: 220, y: 80, width: 60, height: 60)),
                   "UI rectangle is returned in Quartz coordinates")
            if case .pen(let stroke) = selection?.marks.last {
                expect(stroke.points.first == CGPoint(x: 100, y: 120) && stroke.points.last == CGPoint(x: 200, y: 120),
                       "UI pen stroke is returned in Quartz coordinates")
            } else {
                expect(false, "UI pen stroke is returned in Quartz coordinates")
            }
            verifyClosed(window, "UI confirmation closes overlay")

            guard !Task.isCancelled, let doubleWindow = await startSession(), let doubleView = doubleWindow.contentView else { return }
            doubleView.mouseMoved(with: mouse(.mouseMoved, 80, 80, targetWindow: doubleWindow))
            doubleView.mouseDown(with: mouse(.leftMouseDown, 80, 80, targetWindow: doubleWindow))
            doubleView.mouseUp(with: mouse(.leftMouseUp, 80, 80, targetWindow: doubleWindow))
            doubleView.mouseDown(with: mouse(.leftMouseDown, 80, 80, clicks: 2, targetWindow: doubleWindow))
            expect(doubleWindow.isVisible, "UI double-click confirmation waits for mouse release")
            doubleView.mouseUp(with: mouse(.leftMouseUp, 80, 80, clicks: 2, targetWindow: doubleWindow))
            let doubleSelection = await state.selectionTask?.value
            expect(doubleSelection?.region == candidate.frame && doubleSelection?.marks.isEmpty == true,
                   "UI double-click release confirms selected window")
            verifyClosed(doubleWindow, "UI double-click confirmation closes overlay")

            guard !Task.isCancelled, let penWindow = await startSession(), let penView = penWindow.contentView else { return }
            penView.mouseMoved(with: mouse(.mouseMoved, 80, 80, targetWindow: penWindow))
            penView.mouseDown(with: mouse(.leftMouseDown, 80, 80, targetWindow: penWindow))
            penView.mouseUp(with: mouse(.leftMouseUp, 80, 80, targetWindow: penWindow))
            clickButton("画笔", in: penView)
            penView.mouseDown(with: mouse(.leftMouseDown, 100, 100, clicks: 2, targetWindow: penWindow))
            penView.mouseUp(with: mouse(.leftMouseUp, 100, 100, clicks: 2, targetWindow: penWindow))
            expect(penWindow.isVisible, "UI double-click with the pen on draws a mark instead of finishing")
            penWindow.sendEvent(screenshotUIKey(53, "\u{1b}", window: penWindow))
            expect(penWindow.isVisible && !toolIsSelected("画笔", in: penView),
                   "UI Escape exits the pen and leaves the overlay open")
            expect(labels(penView).contains("240 × 160"), "UI Escape from the pen keeps the locked selection")
            penWindow.sendEvent(screenshotUIKey(53, "\u{1b}", window: penWindow))
            expect(await state.selectionTask?.value == nil, "UI second Escape cancels after leaving pen mode")
            verifyClosed(penWindow, "UI second Escape closes overlay")

            guard !Task.isCancelled, let escapeWindow = await startSession() else { return }
            escapeWindow.sendEvent(screenshotUIKey(53, "\u{1b}", window: escapeWindow))
            expect(await state.selectionTask?.value == nil, "UI Escape cancels selection")
            verifyClosed(escapeWindow, "UI Escape closes overlay")
            guard !Task.isCancelled, let cancelledWindow = await startSession() else { return }
            state.selectionTask?.cancel()
            expect(await state.selectionTask?.value == nil, "UI Task cancellation resumes selection with nil")
            verifyClosed(cancelledWindow, "UI Task cancellation closes overlay")

            guard !Task.isCancelled, let switchWindow = await startSession() else { return }
            guard sessionFrontmostPID != NSRunningApplication.current.processIdentifier else {
                expect(false, "UI application-switch fixture has an external foreground app"); return
            }
            workspaceNotifications.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
                                        userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
            expect(await state.selectionTask?.value == nil, "UI simulated application switch cancels selection")
            verifyClosed(switchWindow, "UI simulated application switch closes overlay")
            guard !Task.isCancelled, let spaceWindow = await startSession() else { return }
            workspaceNotifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
            expect(await state.selectionTask?.value == nil, "UI simulated Space switch cancels selection")
            verifyClosed(spaceWindow, "UI simulated Space switch closes overlay")
        }
        while !state.finished, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if !state.finished { expect(false, "UI integration completes within eight seconds") }
        task.cancel()
        state.selectionTask?.cancel()
        let cleanup = Task { @MainActor in
            _ = await state.selectionTask?.value
            state.cleanedUp = true
        }
        let cleanupDeadline = Date().addingTimeInterval(0.5)
        while !state.cleanedUp, Date() < cleanupDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        cleanup.cancel()
    }

    @MainActor private static func screenshotUIKey(_ code: UInt16, _ characters: String, window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: code)!
    }
}
