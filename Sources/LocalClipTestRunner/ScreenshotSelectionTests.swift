import CoreGraphics
import Foundation
import LocalClipCore

extension LocalClipTestRunner {
    static func runScreenshotSelectionTests() {
        print("--- screenshot window selection and resizing ---")
        runScreenshotWindowHoverTests()
        runScreenshotFreeSelectionTests()
        runScreenshotResizeTests()
        runScreenshotMoveAndResetTests()
    }

    private static func runScreenshotWindowHoverTests() {
        let desktop = CGRect(x: -200, y: -100, width: 600, height: 500)
        let front = ScreenshotWindowCandidate(id: 1, frame: CGRect(x: 20, y: 30, width: 100, height: 80))
        let back = ScreenshotWindowCandidate(id: 2, frame: CGRect(x: -50, y: -20, width: 300, height: 200))
        var model = ScreenshotSelectionModel(desktopBounds: desktop, windows: [front, back])
        model.updateHover(at: CGPoint(x: 30, y: 40))
        expect(model.selection == front.frame, "overlapping windows choose the frontmost candidate")
        expect(model.confirmableRect == front.frame && !model.isLocked, "hovered window is confirmable before locking")
        expect(model.handle(at: CGPoint(x: 20, y: 30)) == nil, "hover previews do not expose resize handles")
        model.updateHover(at: CGPoint(x: -30, y: -10))
        expect(model.selection == back.frame, "hover supports windows with negative desktop coordinates")
        model.updateHover(at: CGPoint(x: 350, y: 350))
        expect(model.selection == nil && model.confirmableRect == nil, "desktop without a window has no automatic selection")
        model.updateHover(at: CGPoint(x: -250, y: -120))
        expect(model.selection == nil, "pointer beyond desktop does not select a window")

        var reversed = ScreenshotSelectionModel(desktopBounds: desktop, windows: [back, front])
        reversed.updateHover(at: CGPoint(x: 30, y: 40))
        expect(reversed.selection == back.frame, "window order determines which overlapping window is selected")

        let offscreen = ScreenshotWindowCandidate(id: 3, frame: CGRect(x: -300, y: -150, width: 180, height: 130))
        var clipped = ScreenshotSelectionModel(desktopBounds: desktop, windows: [offscreen])
        clipped.updateHover(at: CGPoint(x: -180, y: -90))
        expect(clipped.selection == CGRect(x: -200, y: -100, width: 80, height: 80), "partially offscreen windows clip to the desktop")

        let narrow = ScreenshotWindowCandidate(id: 4, frame: CGRect(x: 25, y: 35, width: 1, height: 40))
        let clippedNarrow = ScreenshotWindowCandidate(id: 5, frame: CGRect(x: 399, y: 35, width: 50, height: 40))
        let nonfinite = ScreenshotWindowCandidate(id: 6, frame: CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100))
        var invalid = ScreenshotSelectionModel(desktopBounds: desktop, windows: [narrow, nonfinite, clippedNarrow, front])
        invalid.updateHover(at: CGPoint(x: 25.5, y: 40))
        expect(invalid.selection == front.frame, "invalid front candidates do not hide a valid window")
        invalid.updateHover(at: CGPoint(x: 399.5, y: 40))
        expect(invalid.confirmableRect == nil, "clipping below minimum width cannot create a confirmable window")

        model.updateHover(at: CGPoint(x: 30, y: 40))
        model.beginDrag(at: CGPoint(x: 30, y: 40))
        model.endDrag(at: CGPoint(x: 31, y: 41))
        expect(model.selection == front.frame && model.isLocked, "click with small pointer movement locks the preview window")
        model.updateHover(at: CGPoint(x: -30, y: -10))
        expect(model.selection == front.frame, "moving over another window does not replace a locked selection")
        model.beginDrag(at: CGPoint(x: 350, y: 350))
        model.endDrag(at: CGPoint(x: 350, y: 350))
        expect(model.selection == front.frame && model.isLocked, "click outside preserves a locked selection")
    }

    private static func runScreenshotFreeSelectionTests() {
        let desktop = CGRect(x: -200, y: -100, width: 600, height: 500)
        let window = ScreenshotWindowCandidate(id: 1, frame: CGRect(x: -50, y: -20, width: 300, height: 200))
        var model = ScreenshotSelectionModel(desktopBounds: desktop, windows: [window])
        model.beginDrag(at: CGPoint(x: 100, y: 100))
        model.drag(to: CGPoint(x: 103, y: 100))
        expect(model.selection == window.frame && !model.isLocked, "movement of exactly three points retains the hover preview")
        model.drag(to: CGPoint(x: 20, y: 30))
        model.endDrag(at: CGPoint(x: 20, y: 30))
        expect(model.selection == CGRect(x: 20, y: 30, width: 80, height: 70) && model.isLocked,
               "dragging from inside an unlocked window creates a reverse-direction free selection")

        var clipped = ScreenshotSelectionModel(desktopBounds: desktop, windows: [])
        clipped.beginDrag(at: CGPoint(x: -180, y: -90))
        clipped.endDrag(at: CGPoint(x: 900, y: 900))
        expect(clipped.selection == CGRect(x: -180, y: -90, width: 580, height: 490), "free selection stays inside desktop bounds")

        var outsideStart = ScreenshotSelectionModel(desktopBounds: desktop, windows: [])
        outsideStart.beginDrag(at: CGPoint(x: -300, y: -200))
        outsideStart.endDrag(at: CGPoint(x: -150, y: -50))
        expect(outsideStart.selection == CGRect(x: -200, y: -100, width: 50, height: 50), "free selection also clamps a start outside the desktop")

        var tiny = ScreenshotSelectionModel(desktopBounds: desktop, windows: [])
        tiny.beginDrag(at: CGPoint(x: 0, y: 0))
        tiny.endDrag(at: CGPoint(x: 1, y: 20))
        expect(tiny.selection == nil && tiny.confirmableRect == nil && !tiny.isLocked, "long but subminimum-width drag cannot be captured")
        tiny.beginDrag(at: CGPoint(x: 0, y: 0))
        tiny.endDrag(at: CGPoint(x: 20, y: 1))
        expect(tiny.confirmableRect == nil, "subminimum-height drag cannot be captured")
        tiny.beginDrag(at: CGPoint(x: 0, y: 0))
        tiny.endDrag(at: CGPoint(x: 20, y: 0))
        expect(tiny.confirmableRect == nil, "horizontal line is not a screenshot selection")
        tiny.beginDrag(at: CGPoint(x: 0, y: 0))
        tiny.endDrag(at: CGPoint(x: 2, y: 4))
        expect(tiny.confirmableRect == CGRect(x: 0, y: 0, width: 2, height: 4), "minimum width of two points is accepted")

        var absent = ScreenshotSelectionModel(desktopBounds: desktop, windows: [])
        absent.beginDrag(at: CGPoint(x: 100, y: 100))
        absent.endDrag(at: CGPoint(x: 100, y: 100))
        expect(absent.selection == nil && !absent.isLocked, "click on desktop does not create a zero-size selection")

        var invalidDesktop = ScreenshotSelectionModel(desktopBounds: .zero, windows: [window])
        invalidDesktop.beginDrag(at: .zero)
        invalidDesktop.endDrag(at: CGPoint(x: 100, y: 100))
        expect(invalidDesktop.confirmableRect == nil, "empty desktop cannot create a valid selection")

        var replacement = lockedScreenshotFixture()
        replacement.beginDrag(at: CGPoint(x: 20, y: 20))
        replacement.endDrag(at: CGPoint(x: 80, y: 60))
        expect(replacement.selection == CGRect(x: 20, y: 20, width: 60, height: 40) && replacement.isLocked,
               "dragging outside a locked selection starts a new free selection")
    }

    private static func runScreenshotResizeTests() {
        // These are explicit edge outcomes rather than the resizing algorithm.
        let cases: [(ScreenshotSelectionHandle, CGPoint, CGPoint, CGRect)] = [
            (.topLeft, CGPoint(x: 100, y: 100), CGPoint(x: 80, y: 90), CGRect(x: 80, y: 90, width: 120, height: 110)),
            (.top, CGPoint(x: 150, y: 100), CGPoint(x: 150, y: 90), CGRect(x: 100, y: 90, width: 100, height: 110)),
            (.topRight, CGPoint(x: 200, y: 100), CGPoint(x: 230, y: 90), CGRect(x: 100, y: 90, width: 130, height: 110)),
            (.right, CGPoint(x: 200, y: 150), CGPoint(x: 230, y: 150), CGRect(x: 100, y: 100, width: 130, height: 100)),
            (.bottomRight, CGPoint(x: 200, y: 200), CGPoint(x: 230, y: 240), CGRect(x: 100, y: 100, width: 130, height: 140)),
            (.bottom, CGPoint(x: 150, y: 200), CGPoint(x: 150, y: 240), CGRect(x: 100, y: 100, width: 100, height: 140)),
            (.bottomLeft, CGPoint(x: 100, y: 200), CGPoint(x: 80, y: 240), CGRect(x: 80, y: 100, width: 120, height: 140)),
            (.left, CGPoint(x: 100, y: 150), CGPoint(x: 80, y: 150), CGRect(x: 80, y: 100, width: 120, height: 100))
        ]
        for (handle, start, end, expected) in cases {
            var model = lockedScreenshotFixture()
            expect(model.handle(at: start) == handle, "hit testing finds \(handle) handle")
            model.beginDrag(at: start)
            model.endDrag(at: end)
            expect(model.selection == expected && model.isLocked, "\(handle) resize changes only its corresponding edges")
        }

        let boundaryCases: [(CGPoint, CGPoint, CGRect)] = [
            (CGPoint(x: 100, y: 100), CGPoint(x: -999, y: -999), CGRect(x: 0, y: 0, width: 200, height: 200)),
            (CGPoint(x: 150, y: 100), CGPoint(x: 150, y: -999), CGRect(x: 100, y: 0, width: 100, height: 200)),
            (CGPoint(x: 200, y: 100), CGPoint(x: 999, y: -999), CGRect(x: 100, y: 0, width: 300, height: 200)),
            (CGPoint(x: 200, y: 150), CGPoint(x: 999, y: 150), CGRect(x: 100, y: 100, width: 300, height: 100)),
            (CGPoint(x: 200, y: 200), CGPoint(x: 999, y: 999), CGRect(x: 100, y: 100, width: 300, height: 200)),
            (CGPoint(x: 150, y: 200), CGPoint(x: 150, y: 999), CGRect(x: 100, y: 100, width: 100, height: 200)),
            (CGPoint(x: 100, y: 200), CGPoint(x: -999, y: 999), CGRect(x: 0, y: 100, width: 200, height: 200)),
            (CGPoint(x: 100, y: 150), CGPoint(x: -999, y: 150), CGRect(x: 0, y: 100, width: 200, height: 100))
        ]
        for (start, end, expected) in boundaryCases {
            var model = lockedScreenshotFixture()
            model.beginDrag(at: start)
            model.endDrag(at: end)
            expect(model.selection == expected, "resize at \(start) clamps to the desktop boundary")
        }

        let crossingCases: [(CGPoint, CGPoint, CGRect)] = [
            (CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 300), CGRect(x: 198, y: 198, width: 2, height: 2)),
            (CGPoint(x: 150, y: 100), CGPoint(x: 150, y: 300), CGRect(x: 100, y: 198, width: 100, height: 2)),
            (CGPoint(x: 200, y: 100), CGPoint(x: 0, y: 300), CGRect(x: 100, y: 198, width: 2, height: 2)),
            (CGPoint(x: 200, y: 150), CGPoint(x: 0, y: 150), CGRect(x: 100, y: 100, width: 2, height: 100)),
            (CGPoint(x: 200, y: 200), CGPoint(x: 0, y: 0), CGRect(x: 100, y: 100, width: 2, height: 2)),
            (CGPoint(x: 150, y: 200), CGPoint(x: 150, y: 0), CGRect(x: 100, y: 100, width: 100, height: 2)),
            (CGPoint(x: 100, y: 200), CGPoint(x: 300, y: 0), CGRect(x: 198, y: 100, width: 2, height: 2)),
            (CGPoint(x: 100, y: 150), CGPoint(x: 300, y: 150), CGRect(x: 198, y: 100, width: 2, height: 100))
        ]
        for (start, end, expected) in crossingCases {
            var model = lockedScreenshotFixture()
            model.beginDrag(at: start)
            model.endDrag(at: end)
            expect(model.confirmableRect == expected, "resize at \(start) cannot invert or collapse the selection")
        }

        var offset = lockedScreenshotFixture()
        expect(offset.handle(at: CGPoint(x: 106, y: 100)) == .topLeft, "handles allow pointer tolerance")
        expect(offset.handle(at: CGPoint(x: 125, y: 94)) == .top, "top border away from its midpoint also supports resize hit testing")
        expect(offset.handle(at: CGPoint(x: 106, y: 106), tolerance: 5) == nil, "caller can narrow handle and edge hit tolerance")
        offset.beginDrag(at: CGPoint(x: 106, y: 100))
        offset.endDrag(at: CGPoint(x: 96, y: 90))
        expect(offset.selection == CGRect(x: 90, y: 90, width: 110, height: 110), "near-handle clicks preserve the initial pointer offset during resize")
    }

    private static func runScreenshotMoveAndResetTests() {
        var model = lockedScreenshotFixture()
        model.beginDrag(at: CGPoint(x: 140, y: 140))
        model.endDrag(at: CGPoint(x: 170, y: 160))
        expect(model.selection == CGRect(x: 130, y: 120, width: 100, height: 100), "interior drag moves a locked selection without resizing")
        model.beginDrag(at: CGPoint(x: 160, y: 150))
        model.endDrag(at: CGPoint(x: 900, y: 900))
        expect(model.selection == CGRect(x: 300, y: 200, width: 100, height: 100), "moving clamps at the right and bottom desktop boundaries")
        model.beginDrag(at: CGPoint(x: 340, y: 240))
        model.endDrag(at: CGPoint(x: -900, y: -900))
        expect(model.selection == CGRect(x: 0, y: 0, width: 100, height: 100), "moving clamps at the left and top desktop boundaries")
        model.reset()
        expect(!model.isLocked && model.selection == nil, "reset drops the lock and previews at the most recent pointer position")
        model.updateHover(at: CGPoint(x: 150, y: 150))
        expect(model.selection == CGRect(x: 100, y: 100, width: 100, height: 100), "hovering resumes after resetting")
        model.beginDrag(at: CGPoint(x: 150, y: 150))
        model.endDrag(at: CGPoint(x: 150, y: 150))
        model.reset()
        expect(!model.isLocked && model.confirmableRect == CGRect(x: 100, y: 100, width: 100, height: 100), "reset restores automatic window preview beneath the pointer")
        model.beginDrag(at: CGPoint(x: 150, y: 150))
        model.drag(to: CGPoint(x: 250, y: 250))
        model.reset()
        model.endDrag(at: CGPoint(x: 300, y: 280))
        expect(!model.isLocked && model.selection == CGRect(x: 100, y: 100, width: 100, height: 100), "reset clears an active drag so a late mouse-up cannot mutate it")

        let negativeDesktop = CGRect(x: -300, y: -200, width: 700, height: 500)
        let negativeWindow = ScreenshotWindowCandidate(id: 7, frame: CGRect(x: -250, y: -150, width: 100, height: 100))
        var negative = ScreenshotSelectionModel(desktopBounds: negativeDesktop, windows: [negativeWindow])
        negative.beginDrag(at: CGPoint(x: -200, y: -100))
        negative.endDrag(at: CGPoint(x: -200, y: -100))
        negative.beginDrag(at: CGPoint(x: -200, y: -100))
        negative.endDrag(at: CGPoint(x: -999, y: -999))
        expect(negative.selection == CGRect(x: -300, y: -200, width: 100, height: 100), "moving on a negative-coordinate display uses its real bounds")
        negative.beginDrag(at: CGPoint(x: -200, y: -150))
        negative.endDrag(at: CGPoint(x: 999, y: -150))
        expect(negative.selection == CGRect(x: -300, y: -200, width: 700, height: 100), "right handle can resize across the desktop origin")
    }

    private static func lockedScreenshotFixture() -> ScreenshotSelectionModel {
        var model = ScreenshotSelectionModel(
            desktopBounds: CGRect(x: 0, y: 0, width: 400, height: 300),
            windows: [ScreenshotWindowCandidate(id: 1, frame: CGRect(x: 100, y: 100, width: 100, height: 100))]
        )
        model.beginDrag(at: CGPoint(x: 150, y: 150))
        model.endDrag(at: CGPoint(x: 150, y: 150))
        return model
    }
}
