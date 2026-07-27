import Combine
import Foundation
import LocalClipCore
import SQLite3

private struct PersistedSettingsFixture: Codable {
    var pollIntervalMs: Int
    var maxItems: Int
    var maxAgeDays: Int
    var plainTextPaste: Bool
    var launchAtLogin: Bool
}

// Lightweight test runner (no XCTest — works with Command Line Tools only).
// Exercises shipped LocalClipCore types only.

@main
struct LocalClipTestRunner {
    static var failures = 0

    static func main() {
        runRetentionPolicyTests()
        runStoreTests()
        runPasteTests()
        runGuardTests()
        runHasherAndOrdering()
        runSelectionTests()
        runUpdateCheckerTests()
        runAppModelRetentionTests()
        runAppModelSearchTests()
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

    static func uniquePNG(_ marker: UInt8) -> Data {
        var data = tinyPNG()
        data.append(marker)
        return data
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
            store.pruneExecutor = { _ in }
            try body(store, clock, root)
        } catch {
            failures += 1
            print("FAIL store setup: \(error)")
        }
        try? FileManager.default.removeItem(at: root)
    }

    static func runRetentionPolicyTests() {
        print("--- retention policy ---")
        expect(AppSettings.retentionMaxItemOptions == [50, 100, 200, 500, 1000], "retention item presets")
        expect(AppSettings.retentionMaxAgeDayOptions == [1, 3, 7, 14, 30, 0], "retention age presets")
        expect(AppSettings.isValidRetention(maxItems: 200, maxAgeDays: 0), "permanent retention valid")
        expect(!AppSettings.isValidRetention(maxItems: 0, maxAgeDays: 7), "zero item limit invalid")
        expect(!AppSettings.isValidRetention(maxItems: 200, maxAgeDays: -1), "negative age invalid")
        expect(AppSettings.isRetentionReduction(
            fromMaxItems: 200, fromMaxAgeDays: 7,
            toMaxItems: 100, toMaxAgeDays: 7
        ), "lower item limit is reduction")
        expect(AppSettings.isRetentionReduction(
            fromMaxItems: 200, fromMaxAgeDays: 0,
            toMaxItems: 200, toMaxAgeDays: 30
        ), "permanent to finite age is reduction")
        expect(!AppSettings.isRetentionReduction(
            fromMaxItems: 200, fromMaxAgeDays: 7,
            toMaxItems: 500, toMaxAgeDays: 0
        ), "raising count and selecting permanent is not reduction")

        withStore { store, clock, _ in
            store.pruneExecutor = { _ in }
            _ = try store.insertText("permanent")
            clock.date = clock.date.addingTimeInterval(31 * 24 * 60 * 60)
            store.updateSettings(AppSettings(maxItems: 200, maxAgeDays: 0))
            try store.prune()
            let items = try store.allItems()
            expect(items.count == 1, "permanent retention skips age pruning")
            expect(items.first?.textContent == "permanent", "permanent retention keeps old item")
        }
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

        withStore { store, _, root in
            store.pruneExecutor = { _ in }
            guard let item = try store.insertText("locked lookup") else {
                expect(false, "locked lookup fixture inserted")
                return
            }
            expect(try store.item(id: item.id)?.id == item.id, "locked lookup statement is warmed")

            var lockingDB: OpaquePointer?
            let databasePath = root.appendingPathComponent("db.sqlite").path
            guard sqlite3_open_v2(databasePath, &lockingDB, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
                expect(false, "locked lookup opens independent SQLite connection")
                return
            }
            defer {
                if let lockingDB {
                    _ = sqlite3_exec(lockingDB, "ROLLBACK;", nil, nil, nil)
                    sqlite3_close(lockingDB)
                }
            }
            guard sqlite3_exec(lockingDB, "BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK else {
                expect(false, "locked lookup acquires exclusive SQLite lock")
                return
            }

            var threwStepError = false
            do {
                _ = try store.item(id: item.id)
            } catch let error as ClipboardStoreError {
                if case .execFailed = error {
                    threwStepError = true
                }
            }
            expect(threwStepError, "locked public item lookup reports SQLite step failure")

            expect(
                sqlite3_exec(lockingDB, "ROLLBACK;", nil, nil, nil) == SQLITE_OK,
                "locked lookup releases exclusive SQLite lock"
            )
            sqlite3_close(lockingDB)
            lockingDB = nil
            expect(try store.item(id: item.id)?.id == item.id, "locked lookup preserves the existing row")
        }

        withStore { store, _, _ in
            let inFlightImageURL = store.imagesURL.appendingPathComponent("in-flight.png")
            let inFlightThumbURL = store.thumbsURL.appendingPathComponent("in-flight.jpg")
            try uniquePNG(9).write(to: inFlightImageURL)
            try Data("in-flight-thumb".utf8).write(to: inFlightThumbURL)

            try store.prune()
            expect(
                FileManager.default.fileExists(atPath: inFlightImageURL.path)
                    && FileManager.default.fileExists(atPath: inFlightThumbURL.path),
                "prune does not delete untracked in-flight assets"
            )
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

        withStore { store, clock, _ in
            store.pruneExecutor = { _ in }
            store.updateSettings(AppSettings(maxItems: 2, maxAgeDays: 7))
            _ = try store.insertText("old-1")
            clock.date = clock.date.addingTimeInterval(1)
            _ = try store.insertText("old-2")
            clock.date = clock.date.addingTimeInterval(8 * 24 * 60 * 60)
            _ = try store.insertText("recent-1")
            clock.date = clock.date.addingTimeInterval(1)
            _ = try store.insertText("recent-2")
            clock.date = clock.date.addingTimeInterval(1)
            _ = try store.insertText("recent-3")

            try store.prune()
            let items = try store.allItems()
            expect(items.count == 2, "combined prune applies count to age-filtered records")
            expect(
                items.map(\.textContent) == ["recent-3", "recent-2"],
                "combined prune preserves the newest records remaining after age pruning"
            )
        }

        // Insert must not wait for prune: hold pruneExecutor until we flush.
        withStore { store, clock, _ in
            store.updateSettings(AppSettings(maxItems: 2, maxAgeDays: 7))
            var held: [() -> Void] = []
            store.pruneExecutor = { work in held.append(work) }

            clock.date = clock.date.addingTimeInterval(1)
            _ = try store.insertText("a")
            clock.date = clock.date.addingTimeInterval(1)
            _ = try store.insertText("b")
            clock.date = clock.date.addingTimeInterval(1)
            _ = try store.insertText("c")

            // Three inserts scheduled prune thrice but none ran yet → still 3 rows.
            let before = try store.allItems().count
            expect(before == 3, "third insert returns before prune runs (count=\(before))")
            expect(held.count >= 1, "prune was scheduled (not inlined on insert stack)")

            for work in held { work() }
            expect(try store.allItems().count == 2, "flushing scheduled prune enforces maxItems")
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

        withStore { store, clock, root in
            store.pruneExecutor = { _ in }
            store.updateSettings(AppSettings(maxItems: 1, maxAgeDays: 0))
            var inserted: [ClipboardItem] = []
            for marker: UInt8 in 1...3 {
                clock.date = clock.date.addingTimeInterval(1)
                inserted.append(try store.insertImage(data: uniquePNG(marker))!)
            }
            let assetURLs = inserted.flatMap { item in
                [
                    root.appendingPathComponent(item.imagePath!),
                    root.appendingPathComponent(item.thumbPath!)
                ]
            }

            var faultDB: OpaquePointer?
            let databasePath = root.appendingPathComponent("db.sqlite").path
            guard sqlite3_open_v2(databasePath, &faultDB, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
                expect(false, "atomic prune fault opens independent SQLite connection")
                return
            }
            defer { sqlite3_close(faultDB) }
            let faultSQL = """
            CREATE TABLE prune_fault (attempts INTEGER NOT NULL);
            INSERT INTO prune_fault (attempts) VALUES (0);
            CREATE TRIGGER abort_second_prune_delete
            BEFORE DELETE ON items
            BEGIN
              UPDATE prune_fault SET attempts = attempts + 1;
              SELECT CASE WHEN (SELECT attempts FROM prune_fault) = 2
                THEN RAISE(ABORT, 'forced second prune delete failure')
              END;
            END;
            """
            guard sqlite3_exec(faultDB, faultSQL, nil, nil, nil) == SQLITE_OK else {
                expect(false, "atomic prune installs a real second-delete SQLite fault")
                return
            }

            var pruneThrew = false
            do {
                try store.prune()
            } catch let error as ClipboardStoreError {
                if case .execFailed = error {
                    pruneThrew = true
                }
            }
            expect(pruneThrew, "second candidate SQLite failure is reported")
            expect(try store.allItems().count == 3, "failed batch prune rolls back every candidate row")
            expect(
                assetURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                "failed batch prune preserves every referenced image and thumbnail"
            )
        }

        withStore { store, clock, root in
            store.pruneExecutor = { _ in }
            store.updateSettings(AppSettings(maxItems: 1, maxAgeDays: 0))
            var inserted: [ClipboardItem] = []
            for marker: UInt8 in 4...6 {
                clock.date = clock.date.addingTimeInterval(1)
                inserted.append(try store.insertImage(data: uniquePNG(marker))!)
            }

            try store.prune()
            let remaining = try store.allItems()
            expect(remaining.map(\.id) == [inserted[2].id], "successful batch prune keeps only the newest row")
            for item in inserted.dropLast() {
                expect(
                    !FileManager.default.fileExists(
                        atPath: root.appendingPathComponent(item.imagePath!).path
                    ),
                    "successful batch prune removes candidate image \(item.id)"
                )
                expect(
                    !FileManager.default.fileExists(
                        atPath: root.appendingPathComponent(item.thumbPath!).path
                    ),
                    "successful batch prune removes candidate thumbnail \(item.id)"
                )
            }
            expect(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(inserted[2].imagePath!).path
                ),
                "successful batch prune preserves retained image"
            )
            expect(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(inserted[2].thumbPath!).path
                ),
                "successful batch prune preserves retained thumbnail"
            )
        }

        withStore { store, clock, root in
            store.pruneExecutor = { _ in }
            store.updateSettings(AppSettings(maxItems: 1, maxAgeDays: 0))
            clock.date = clock.date.addingTimeInterval(1)
            let obsolete = try store.insertImage(data: uniquePNG(7))!
            clock.date = clock.date.addingTimeInterval(1)
            _ = try store.insertImage(data: uniquePNG(8))!
            let obsoleteImageURL = root.appendingPathComponent(obsolete.imagePath!)
            let obsoleteThumbURL = root.appendingPathComponent(obsolete.thumbPath!)

            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: store.imagesURL.path
                )
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: store.thumbsURL.path
                )
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o500],
                ofItemAtPath: store.imagesURL.path
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o500],
                ofItemAtPath: store.thumbsURL.path
            )

            try store.prune()
            expect(try store.item(id: obsolete.id) == nil, "database prune commits despite asset cleanup failure")
            expect(
                FileManager.default.fileExists(atPath: obsoleteImageURL.path)
                    && FileManager.default.fileExists(atPath: obsoleteThumbURL.path),
                "failed asset cleanup leaves retryable image and thumbnail orphans"
            )

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: store.imagesURL.path
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: store.thumbsURL.path
            )
            try store.prune()
            expect(
                !FileManager.default.fileExists(atPath: obsoleteImageURL.path)
                    && !FileManager.default.fileExists(atPath: obsoleteThumbURL.path),
                "later prune retries and removes orphaned image and thumbnail assets"
            )
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

    static func runUpdateCheckerTests() {
        print("--- update checker ---")
        expect(UpdateChecker.normalizeTag("v1.2.3") == "1.2.3", "strip v prefix")
        expect(UpdateChecker.normalizeTag("1.0.0") == "1.0.0", "plain version")
        expect(UpdateChecker.compareVersions("1.0.0", "1.0.1") == .orderedAscending, "1.0.0 < 1.0.1")
        expect(UpdateChecker.compareVersions("1.10.0", "1.2.0") == .orderedDescending, "1.10 > 1.2")
        expect(UpdateChecker.compareVersions("1.0.0", "1.0.0") == .orderedSame, "equal versions")
        expect(UpdateChecker.compareVersions("2.0", "2.0.0") == .orderedSame, "pad missing segments")
        expect(UpdateChecker.parseVersion("v1.2.3-beta") == [1, 2, 3], "parse ignores prerelease suffix")
        expect(AppIdentity.githubOwner == "anjun", "github owner")
        expect(AppIdentity.githubRepo == "LocalClip", "github repo")

        // Asset preference for in-app install (zip only)
        let assets: [[String: Any]] = [
            ["name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"],
            [
                "name": "LocalClip-1.0.1-universal-macos.dmg",
                "browser_download_url": "https://example.com/a.dmg"
            ],
            [
                "name": "LocalClip-1.0.1-universal-macos.zip",
                "browser_download_url": "https://example.com/a.zip"
            ],
            [
                "name": "other.zip",
                "browser_download_url": "https://example.com/o.zip"
            ]
        ]
        let pick = UpdateChecker.preferZipAsset(from: assets)
        expect(pick?.name == "LocalClip-1.0.1-universal-macos.zip", "prefer universal zip asset")
        expect(pick?.url.absoluteString == "https://example.com/a.zip", "zip download url")

        let dest = UpdateChecker.installDestination(
            bundle: Bundle(path: "/tmp/not-an-app") ?? .main,
            home: URL(fileURLWithPath: "/Users/demo")
        )
        expect(
            dest.path.hasSuffix("Applications/LocalClip.app")
                || dest.path.contains("LocalClip.app"),
            "install destination is LocalClip.app"
        )

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("LC-findapp-\(UUID().uuidString)", isDirectory: true)
        let nested = work.appendingPathComponent("LocalClip.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let found = UpdateChecker.findAppBundle(in: work)
        expect(found?.lastPathComponent == "LocalClip.app", "findAppBundle locates app")
        try? FileManager.default.removeItem(at: work)
    }

    static func runAppModelRetentionTests() {
        print("--- appmodel retention update ---")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LC-retention-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "LocalClipTests.Retention.\(UUID().uuidString)"
        guard let initialDefaults = UserDefaults(suiteName: suiteName) else {
            expect(false, "appmodel retention defaults suite created")
            return
        }
        initialDefaults.removePersistentDomain(forName: suiteName)
        defer {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        final class State: @unchecked Sendable {
            var setupError: String?
            var finished = false
        }
        let state = State()

        DispatchQueue.main.async {
            Task { @MainActor in
                guard let userDefaults = UserDefaults(suiteName: suiteName) else {
                    state.setupError = "could not recreate defaults suite"
                    state.finished = true
                    return
                }
                do {
                    let defaultsKey = "LocalClip.AppSettings.v1"
                    let invalidPersisted = PersistedSettingsFixture(
                        pollIntervalMs: 725,
                        maxItems: 0,
                        maxAgeDays: 23,
                        plainTextPaste: true,
                        launchAtLogin: false
                    )
                    userDefaults.set(
                        try JSONEncoder().encode(invalidPersisted),
                        forKey: defaultsKey
                    )
                    let sanitized = try AppModel(storeRoot: root, userDefaults: userDefaults)
                    expect(
                        sanitized.settings.maxItems == 200
                            && sanitized.settings.maxAgeDays == 23,
                        "invalid persisted item limit is sanitized without replacing valid non-preset age"
                    )
                    expect(
                        sanitized.store.settings.maxItems == 200
                            && sanitized.store.settings.maxAgeDays == 23,
                        "store is constructed with sanitized retention"
                    )
                    expect(
                        sanitized.settings.pollIntervalMs == 725
                            && sanitized.settings.plainTextPaste
                            && !sanitized.settings.launchAtLogin,
                        "sanitizing retention preserves unrelated persisted settings"
                    )
                    let rewrittenData = userDefaults.data(forKey: defaultsKey)
                    let rewritten = try rewrittenData.map {
                        try JSONDecoder().decode(PersistedSettingsFixture.self, from: $0)
                    }
                    expect(
                        rewritten?.maxItems == 200 && rewritten?.maxAgeDays == 23,
                        "sanitized retention is rewritten to defaults"
                    )
                    expect(
                        rewritten?.pollIntervalMs == 725
                            && rewritten?.plainTextPaste == true
                            && rewritten?.launchAtLogin == false,
                        "rewritten defaults preserve unrelated settings"
                    )

                    let invalidAgePersisted = PersistedSettingsFixture(
                        pollIntervalMs: 725,
                        maxItems: 321,
                        maxAgeDays: -1,
                        plainTextPaste: true,
                        launchAtLogin: false
                    )
                    userDefaults.set(
                        try JSONEncoder().encode(invalidAgePersisted),
                        forKey: defaultsKey
                    )
                    let ageSanitized = try AppModel(storeRoot: root, userDefaults: userDefaults)
                    expect(
                        ageSanitized.settings.maxItems == 321
                            && ageSanitized.settings.maxAgeDays == 7,
                        "invalid persisted age is sanitized without replacing valid non-preset item limit"
                    )
                    expect(
                        ageSanitized.store.settings.maxItems == 321
                            && ageSanitized.store.settings.maxAgeDays == 7,
                        "store is constructed with sanitized age"
                    )
                    expect(
                        ageSanitized.settings.pollIntervalMs == 725
                            && ageSanitized.settings.plainTextPaste
                            && !ageSanitized.settings.launchAtLogin,
                        "sanitizing age preserves unrelated persisted settings"
                    )
                    let rewrittenAgeData = userDefaults.data(forKey: defaultsKey)
                    let rewrittenAge = try rewrittenAgeData.map {
                        try JSONDecoder().decode(PersistedSettingsFixture.self, from: $0)
                    }
                    expect(
                        rewrittenAge?.maxItems == 321 && rewrittenAge?.maxAgeDays == 7,
                        "sanitized age is rewritten to persisted settings"
                    )

                    let validNonPreset = PersistedSettingsFixture(
                        pollIntervalMs: 725,
                        maxItems: 321,
                        maxAgeDays: 9,
                        plainTextPaste: true,
                        launchAtLogin: false
                    )
                    userDefaults.set(
                        try JSONEncoder().encode(validNonPreset),
                        forKey: defaultsKey
                    )
                    let model = try AppModel(storeRoot: root, userDefaults: userDefaults)
                    expect(
                        model.settings.maxItems == 321 && model.settings.maxAgeDays == 9,
                        "valid non-preset retention is preserved"
                    )
                    model.store.pruneExecutor = { _ in }
                    _ = try model.store.insertText("retention-one")
                    _ = try model.store.insertText("retention-two")
                    _ = try model.store.insertText("retention-three")
                    model.refresh()
                    expect(model.items.count == 3, "retention test seeds three model items")

                    let updated = await model.updateRetention(maxItems: 2, maxAgeDays: 0)
                    expect(updated, "valid retention update succeeds")
                    expect(
                        model.settings.maxItems == 2 && model.settings.maxAgeDays == 0,
                        "model retention settings update to 2/0"
                    )
                    expect(
                        model.store.settings.maxItems == 2 && model.store.settings.maxAgeDays == 0,
                        "store retention settings update to 2/0"
                    )
                    expect(model.items.count == 2, "reduction immediately refreshes model to two items")
                    expect(try model.store.allItems().count == 2, "reduction immediately prunes SQLite to two rows")
                    expect(!model.isUpdatingRetention, "retention update state resets after pruning")

                    let restored = try AppModel(storeRoot: root, userDefaults: userDefaults)
                    expect(
                        restored.settings.maxItems == 2 && restored.settings.maxAgeDays == 0,
                        "new model restores persisted retention settings"
                    )

                    let rejected = await restored.updateRetention(maxItems: 0, maxAgeDays: 7)
                    expect(!rejected, "invalid retention update is rejected")
                    expect(
                        restored.settings.maxItems == 2 && restored.settings.maxAgeDays == 0,
                        "invalid retention update preserves model settings"
                    )
                    expect(
                        restored.store.settings.maxItems == 2 && restored.store.settings.maxAgeDays == 0,
                        "invalid retention update preserves store settings"
                    )
                    restored.plainTextPaste = false

                    var exclusiveLock: OpaquePointer?
                    let databasePath = root.appendingPathComponent("db.sqlite").path
                    expect(
                        sqlite3_open_v2(databasePath, &exclusiveLock, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
                        "retention rollback test opens an independent SQLite connection"
                    )
                    defer { sqlite3_close(exclusiveLock) }
                    expect(
                        sqlite3_exec(exclusiveLock, "BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK,
                        "retention rollback test acquires SQLite exclusive lock"
                    )

                    var changedPlainTextPasteDuringUpdate = false
                    let retentionUpdateObserver = restored.$isUpdatingRetention.sink { isUpdating in
                        guard isUpdating else { return }
                        changedPlainTextPasteDuringUpdate = true
                        restored.plainTextPaste = true
                    }
                    let failedReduction = await restored.updateRetention(maxItems: 1, maxAgeDays: 0)
                    retentionUpdateObserver.cancel()
                    expect(!failedReduction, "locked SQLite prune reports retention update failure")
                    expect(
                        changedPlainTextPasteDuringUpdate,
                        "unrelated setting changes after retention update starts"
                    )
                    expect(
                        restored.settings.maxItems == 2 && restored.settings.maxAgeDays == 0,
                        "failed prune restores prior model retention settings"
                    )
                    expect(
                        restored.store.settings.maxItems == 2 && restored.store.settings.maxAgeDays == 0,
                        "failed prune restores prior store retention settings"
                    )
                    let rollbackData = userDefaults.data(forKey: defaultsKey)
                    let rollbackSettings = try rollbackData.map {
                        try JSONDecoder().decode(PersistedSettingsFixture.self, from: $0)
                    }
                    expect(
                        rollbackSettings?.maxItems == 2 && rollbackSettings?.maxAgeDays == 0,
                        "failed prune restores prior persisted retention settings"
                    )
                    expect(
                        restored.plainTextPaste && restored.settings.plainTextPaste,
                        "failed prune preserves current published and model unrelated setting"
                    )
                    expect(
                        restored.store.settings.plainTextPaste,
                        "failed prune preserves current store unrelated setting"
                    )
                    expect(
                        rollbackSettings?.plainTextPaste == true,
                        "failed prune preserves current persisted unrelated setting"
                    )
                    expect(
                        restored.statusMessage?.hasPrefix("清理历史记录失败：") == true,
                        "failed prune preserves retention failure status"
                    )
                    expect(!restored.isUpdatingRetention, "failed prune resets retention updating state")
                    expect(
                        sqlite3_exec(exclusiveLock, "ROLLBACK;", nil, nil, nil) == SQLITE_OK,
                        "retention rollback test releases SQLite exclusive lock"
                    )
                    sqlite3_close(exclusiveLock)
                    exclusiveLock = nil

                    var overlappingUpdate: Task<Bool, Never>?
                    var observedUpdating = false
                    let overlapObserver = restored.$isUpdatingRetention.sink { isUpdating in
                        guard isUpdating, overlappingUpdate == nil else { return }
                        observedUpdating = true
                        overlappingUpdate = Task { @MainActor in
                            await restored.updateRetention(maxItems: 2, maxAgeDays: 0)
                        }
                    }
                    let firstUpdateSucceeded = await restored.updateRetention(maxItems: 1, maxAgeDays: 0)
                    overlapObserver.cancel()
                    expect(observedUpdating, "first retention reduction enters updating state")
                    if let overlappingUpdate {
                        let overlappingSucceeded = await overlappingUpdate.value
                        expect(!overlappingSucceeded, "overlapping retention update is rejected")
                    } else {
                        expect(false, "overlapping retention update is scheduled from updating publication")
                    }
                    expect(firstUpdateSucceeded, "first overlapping retention update succeeds")
                    expect(
                        restored.settings.maxItems == 1 && restored.settings.maxAgeDays == 0,
                        "rejected overlapping update cannot overwrite active retention settings"
                    )
                    expect(!restored.isUpdatingRetention, "updating state resets after overlap rejection")
                } catch {
                    state.setupError = "\(error)"
                }
                state.finished = true
            }
        }

        let deadline = Date().addingTimeInterval(5)
        while !state.finished, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if let error = state.setupError {
            failures += 1
            print("FAIL appmodel retention setup: \(error)")
        } else if !state.finished {
            expect(false, "appmodel retention async test completed")
        }
    }

    /// Search box must not run a synchronous full refresh on every keystroke / IME update.
    /// Debounced async load: immediate assignment leaves items unchanged; final query wins.
    static func runAppModelSearchTests() {
        print("--- appmodel search debounce ---")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LC-search-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Hold shared state in a class so concurrent mutation is legal under strict concurrency.
        final class State: @unchecked Sendable {
            var model: AppModel?
            var setupError: String?
            var phase = 0 // 0 loading, 1 ready, 2 done
        }
        let state = State()

        // Drive everything with GCD + RunLoop (matches production debounce timers on CI).
        DispatchQueue.main.async {
            Task { @MainActor in
                do {
                    let model = try AppModel(storeRoot: root)
                    model.searchDebounceNanoseconds = 50_000_000
                    model.store.pruneExecutor = { _ in }
                    _ = try model.store.insertText("Hello Alpha")
                    _ = try model.store.insertText("other beta")
                    _ = try model.store.insertImage(data: tinyPNG())
                    model.refresh()
                    state.model = model
                    state.phase = 1
                } catch {
                    state.setupError = "\(error)"
                    state.phase = 2
                }
            }
        }

        // Wait until model is ready.
        let readyDeadline = Date().addingTimeInterval(3)
        while state.phase == 0, Date() < readyDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if let err = state.setupError {
            failures += 1
            print("FAIL appmodel search setup: \(err)")
            return
        }
        guard let model = state.model else {
            expect(false, "appmodel search model ready")
            return
        }

        // Assertions hop to MainActor via main queue + RunLoop pump.
        final class Probe: @unchecked Sendable {
            var itemsCount = -1
            var firstText: String?
            var finished = false
        }

        func onMain(_ body: @escaping @MainActor () -> Void) {
            DispatchQueue.main.async {
                Task { @MainActor in body() }
            }
        }

        func readItems() -> (count: Int, first: String?) {
            let probe = Probe()
            onMain {
                probe.itemsCount = model.items.count
                probe.firstText = model.items.first?.textContent
                probe.finished = true
            }
            let d = Date().addingTimeInterval(2)
            while !probe.finished, Date() < d {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            return (probe.itemsCount, probe.firstText)
        }

        func waitItems(count: Int, timeout: TimeInterval = 2) -> Bool {
            let d = Date().addingTimeInterval(timeout)
            while Date() < d {
                if readItems().count == count { return true }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            return readItems().count == count
        }

        let seeded = readItems()
        expect(seeded.count == 3, "seeded history before search")

        // Rapid query changes must not apply synchronously.
        onMain {
            model.searchQuery = "H"
        }
        // Let didSet schedule work, then immediately read.
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        let mid = readItems()
        expect(mid.count == 3, "searchQuery change is not synchronous (still \(mid.count))")

        onMain {
            model.searchQuery = "He"
            model.searchQuery = "Hello"
        }
        expect(waitItems(count: 1), "debounced search applies final query")
        let filtered = readItems()
        expect(filtered.first == "Hello Alpha", "final search content")

        onMain { model.searchQuery = "" }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        let afterClear = readItems()
        expect(afterClear.count == 1, "clear search not synchronous (still \(afterClear.count))")
        expect(waitItems(count: 3), "empty query restores full list")
    }
}
