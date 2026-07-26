import Foundation
import LocalClipCore

// Lightweight test runner (no XCTest — works with Command Line Tools only).
// Exercises shipped LocalClipCore types only.

@main
struct LocalClipTestRunner {
    static var failures = 0

    static func main() {
        runStoreTests()
        runPasteTests()
        runGuardTests()
        runHasherAndOrdering()
        runSelectionTests()
        if failures == 0 {
            print("ALL TESTS PASSED")
            exit(0)
        } else {
            print("FAILED: \(failures) assertion(s)")
            exit(1)
        }
    }

    static func expect(_ cond: Bool, _ msg: String, file: StaticString = #file, line: UInt = #line) {
        if !cond {
            failures += 1
            print("FAIL \(file):\(line): \(msg)")
        } else {
            print("ok: \(msg)")
        }
    }

    static func tinyPNG() -> Data {
        Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )!
    }

    static func withStore(_ body: (ClipboardStore, FixedClock, URL) throws -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LC-test-\(UUID().uuidString)", isDirectory: true)
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        do {
            let store = try ClipboardStore(
                rootURL: root,
                settings: AppSettings(maxItems: 200, maxAgeDays: 7),
                clock: clock
            )
            try body(store, clock, root)
        } catch {
            failures += 1
            print("FAIL store setup: \(error)")
        }
        try? FileManager.default.removeItem(at: root)
    }

    static func runStoreTests() {
        print("--- store ---")
        withStore { store, _, _ in
            _ = try store.insertText("Hello World")
            _ = try store.insertText("other")
            let found = try store.search("hello")
            expect(found.count == 1, "search case-insensitive")
            expect(found.first?.textContent == "Hello World", "search content")
        }

        withStore { store, _, _ in
            _ = try store.insertImage(data: tinyPNG())
            _ = try store.insertText("findme")
            expect(try store.allItems().count == 2, "all items count")
            let filtered = try store.search("find")
            expect(filtered.count == 1, "search hides images")
            expect(filtered.first?.kind == .text, "search text only")
        }

        withStore { store, _, _ in
            expect(try store.insertText("same") != nil, "first text insert")
            expect(try store.insertText("same") == nil, "adjacent text dedupe")
            expect(try store.allItems().count == 1, "dedupe count")
        }

        withStore { store, _, _ in
            let png = tinyPNG()
            expect(try store.insertImage(data: png) != nil, "first image")
            expect(try store.insertImage(data: png) == nil, "adjacent image dedupe")
        }

        withStore { store, _, _ in
            let capture = ClipboardCapture(text: "caption", imageData: tinyPNG(), sourceBundleId: "com.ex")
            let inserted = try store.ingest(capture)
            expect(inserted.count == 2, "dual insert count")
            expect(inserted[0].kind == .image, "ingest order image first")
            expect(inserted[1].kind == .text, "ingest order text second")
            let listed = try store.allItems()
            expect(listed.count == 2, "listed dual count")
            expect(listed[0].kind == .image, "list image before text")
            expect(listed[1].kind == .text, "list text second")
        }

        withStore { store, clock, _ in
            store.updateSettings(AppSettings(maxItems: 3, maxAgeDays: 7))
            for i in 0..<5 {
                clock.date = clock.date.addingTimeInterval(1)
                _ = try store.insertText("item-\(i)")
            }
            // Prune is async on ingest path; flush synchronously for the assertion.
            try store.prune()
            let items = try store.allItems()
            expect(items.count == 3, "prune by count keeps 3")
            expect(items.contains { $0.textContent == "item-4" }, "keeps newest")
            expect(!items.contains { $0.textContent == "item-0" }, "drops oldest")
        }

        withStore { store, clock, _ in
            store.updateSettings(AppSettings(maxItems: 200, maxAgeDays: 7))
            _ = try store.insertText("old")
            clock.date = clock.date.addingTimeInterval(8 * 24 * 60 * 60)
            _ = try store.insertText("new")
            try store.prune()
            let items = try store.allItems()
            expect(items.count == 1, "prune by age")
            expect(items.first?.textContent == "new", "age keeps new")
        }

        // Ingest returns before async prune must finish (hot-path performance).
        withStore { store, clock, _ in
            store.updateSettings(AppSettings(maxItems: 2, maxAgeDays: 7))
            clock.date = clock.date.addingTimeInterval(1)
            _ = try store.insertText("a")
            clock.date = clock.date.addingTimeInterval(1)
            _ = try store.insertText("b")
            clock.date = clock.date.addingTimeInterval(1)
            _ = try store.insertText("c")
            // Immediately after insert, rows may still be > max until prune runs.
            let before = try store.allItems().count
            expect(before >= 2, "insert completes without waiting for prune (\(before) rows)")
            try store.prune()
            expect(try store.allItems().count == 2, "sync prune enforces maxItems")
        }

        withStore { store, _, root in
            let item = try store.insertImage(data: tinyPNG())!
            let imageURL = root.appendingPathComponent(item.imagePath!)
            let thumbURL = root.appendingPathComponent(item.thumbPath!)
            expect(FileManager.default.fileExists(atPath: imageURL.path), "image file exists")
            expect(FileManager.default.fileExists(atPath: thumbURL.path), "thumb exists")
            try store.delete(id: item.id)
            expect(!FileManager.default.fileExists(atPath: imageURL.path), "image file deleted")
            expect(!FileManager.default.fileExists(atPath: thumbURL.path), "thumb deleted")
            expect(try store.allItems().isEmpty, "row deleted")
        }

        // Thumbnails must not be full-size dumps (root cause of list jank).
        withStore { store, _, root in
            // Synthetic "large" payload: repeat tiny PNG header+data to exceed maxThumbFileBytes
            // Real path uses ImageIO decode; for non-decodable bulk we still cap thumb size.
            var big = Data()
            let unit = tinyPNG()
            while big.count < ThumbnailMaker.maxThumbFileBytes + 50_000 {
                big.append(unit)
            }
            // If decode fails, preferredThumbData returns ≤1024; if it succeeds, JPEG is small.
            let item = try store.insertImage(data: big)!
            let thumbURL = root.appendingPathComponent(item.thumbPath!)
            let attrs = try FileManager.default.attributesOfItem(atPath: thumbURL.path)
            let thumbBytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
            expect(thumbBytes <= ThumbnailMaker.maxThumbFileBytes, "thumb not bloated (\(thumbBytes) bytes)")
            expect(thumbBytes > 0, "thumb non-empty")
        }

        // Off-main thumbnail generation must not crash (was NSImage.lockFocus on monitor queue).
        print("--- thumb off-main ---")
        let png = tinyPNG()
        let group = DispatchGroup()
        var offMainOK = false
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let thumb = ThumbnailMaker.preferredThumbData(from: png)
            offMainOK = !thumb.isEmpty && thumb.count <= ThumbnailMaker.maxThumbFileBytes
            // Concurrent stress: former lockFocus path crashed here under load.
            for _ in 0..<20 {
                _ = ThumbnailMaker.makeJPEG(from: png)
            }
            group.leave()
        }
        _ = group.wait(timeout: .now() + 5)
        expect(offMainOK, "ImageIO thumb works off main thread")
    }

    static func runPasteTests() {
        print("--- paste policy + service ---")
        let imgItem = ClipboardItem(kind: .image, contentHash: "h", imagePath: "images/x.png")
        let a1 = PastePolicy.resolve(item: imgItem, imageData: Data([0x89]), plainTextMode: true, accessibilityTrusted: true)
        if case .writeAndAutoPaste(.image) = a1 {
            expect(true, "plain-text mode still pastes image")
        } else {
            expect(false, "plain-text mode still pastes image")
        }

        let textItem = ClipboardItem(kind: .text, textContent: "hi", contentHash: "h")
        let a2 = PastePolicy.resolve(item: textItem, imageData: nil, plainTextMode: true, accessibilityTrusted: true)
        expect(a2 == .writeAndAutoPaste(.text("hi")), "text paste payload")

        // When attemptAutoPaste is false and untrusted → clipboard only
        let a3 = PastePolicy.resolve(
            item: textItem,
            imageData: nil,
            plainTextMode: false,
            accessibilityTrusted: false,
            attemptAutoPaste: false
        )
        expect(a3 == .writeClipboardOnly(.text("hi")), "degraded when auto-paste disabled")
        expect(!PastePolicy.requiresAccessibilityKeystroke(a3), "degraded no keystroke flag")

        // Default: attempt auto-paste even if API says untrusted (ad-hoc apps)
        let a3b = PastePolicy.resolve(
            item: textItem,
            imageData: nil,
            plainTextMode: false,
            accessibilityTrusted: false,
            attemptAutoPaste: true
        )
        expect(a3b == .writeAndAutoPaste(.text("hi")), "auto-paste despite untrusted flag")

        let trustedSteps = AutoPasteOrchestration.steps(accessibilityTrusted: true)
        expect(
            trustedSteps == [
                .writePasteboard, .dismissHostUI, .activatePreviousApp, .delay, .keystroke
            ],
            "trusted auto-paste leaves host before keystroke"
        )
        expect(
            AutoPasteOrchestration.steps(accessibilityTrusted: false) == [.writePasteboard],
            "orchestration clipboard-only steps when not attempting"
        )

        let board = MockPasteboard()
        let service = PasteService(
            accessibilityChecker: { false },
            attemptAutoPaste: { false },
            pasteboard: board,
            keystroke: { failures += 1; print("FAIL unexpected keystroke") },
            selfWriteGuard: SelfWriteGuard()
        )
        var beforeUntrusted = false
        let r = service.paste(item: textItem, imageData: nil, plainTextMode: false) {
            beforeUntrusted = true
        }
        expect(r == .wroteClipboardOnly, "service degraded result")
        expect(board.lastText == "hi", "service wrote text")
        expect(!beforeUntrusted, "beforeKeystroke not used when auto-paste off")

        let board2 = MockPasteboard()
        var events: [String] = []
        let service2 = PasteService(
            accessibilityChecker: { false },
            attemptAutoPaste: { true },
            pasteboard: board2,
            keystroke: { events.append("keystroke") },
            selfWriteGuard: SelfWriteGuard()
        )
        let data = Data([1, 2, 3, 4])
        let r2 = service2.paste(item: imgItem, imageData: data, plainTextMode: true) {
            events.append("beforeKeystroke")
        }
        expect(r2 == .wroteAndAutoPasted, "auto paste even when API untrusted")
        expect(board2.lastImage == data, "image written")
        expect(events == ["beforeKeystroke", "keystroke"], "dismiss/activate before keystroke")

        let board3 = MockPasteboard()
        board3.changeCount = 10
        let guard_ = SelfWriteGuard()
        let service3 = PasteService(
            accessibilityChecker: { false },
            attemptAutoPaste: { true },
            pasteboard: board3,
            keystroke: {},
            selfWriteGuard: guard_
        )
        _ = service3.paste(
            item: ClipboardItem(kind: .text, textContent: "x", contentHash: "h"),
            imageData: nil,
            plainTextMode: false
        )
        expect(guard_.shouldIgnore(changeCount: board3.changeCount), "self-write suppress after paste")
    }

    static func runGuardTests() {
        print("--- self-write guard ---")
        let g = SelfWriteGuard()
        g.beginSelfWrite(expectedChangeCountAfter: 42, duration: 2)
        expect(g.shouldIgnore(changeCount: 42), "ignore expected count")
        expect(!g.shouldIgnore(changeCount: 42, now: Date().addingTimeInterval(3)), "after window not ignore")
    }

    static func runHasherAndOrdering() {
        print("--- hasher / ordering ---")
        expect(ContentHasher.sha256Hex(ofText: "abc") == ContentHasher.sha256Hex(ofText: "abc"), "hash stable")
        expect(ContentHasher.sha256Hex(ofText: "abc") != ContentHasher.sha256Hex(ofText: "abd"), "hash differs")
        let both = ClipboardCapture(text: "t", imageData: Data([1, 2, 3]))
        expect(CaptureOrdering.plannedRows(for: both).map(\.kind) == [.image, .text], "order image then text")
    }

    static func runSelectionTests() {
        print("--- list selection (keyboard) ---")
        expect(HistoryListSelection.moveIndex(current: nil, count: 0, delta: 1) == nil, "empty no move")
        expect(HistoryListSelection.moveIndex(current: nil, count: 5, delta: 1) == 0, "down from nil → 0")
        expect(HistoryListSelection.moveIndex(current: nil, count: 5, delta: -1) == 4, "up from nil → last")
        expect(HistoryListSelection.moveIndex(current: 0, count: 5, delta: -1) == 0, "clamp top")
        expect(HistoryListSelection.moveIndex(current: 4, count: 5, delta: 1) == 4, "clamp bottom")
        expect(HistoryListSelection.moveIndex(current: 2, count: 5, delta: 1) == 3, "down step")
        expect(HistoryListSelection.moveIndex(current: 2, count: 5, delta: -1) == 1, "up step")
        let ids = ["a", "b", "c"]
        expect(HistoryListSelection.itemID(at: 1, in: ids) == "b", "id at index")
        expect(HistoryListSelection.index(of: "c", in: ids) == 2, "index of id")
        expect(HistoryListSelection.index(of: "z", in: ids) == nil, "missing id")
        // Return paste targets selected id (same entry as click on that row).
        expect(
            HistoryListSelection.pasteTargetID(selected: "b", in: ids) == "b",
            "Return paste targets selected id"
        )
        expect(
            HistoryListSelection.pasteTargetID(selected: "gone", in: ids) == "a",
            "stale selection falls back to first"
        )
        expect(
            HistoryListSelection.pasteTargetID(selected: nil, in: ids) == "a",
            "nil selection pastes first"
        )
        expect(
            HistoryListSelection.pasteTargetID(selected: nil, in: []) == nil,
            "empty list no paste target"
        )
    }
}
