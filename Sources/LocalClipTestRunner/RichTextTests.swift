import AppKit
import Foundation
import LocalClipCore
import SQLite3

extension LocalClipTestRunner {
    static func runRichTextTests() {
        print("--- rich text capture, persistence and paste ---")
        do {
            let text = "Bold link"
            let attributed = NSMutableAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 16)
            ])
            attributed.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 16), range: NSRange(location: 0, length: 4))
            attributed.addAttribute(.link, value: URL(string: "https://example.com/reference")!, range: NSRange(location: 5, length: 4))
            let range = NSRange(location: 0, length: attributed.length)
            let richText = RichTextContent(
                rtf: try attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]),
                rtfd: try attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]),
                html: Data("<p><strong>Bold</strong> <a href=\"https://example.com/reference\">link</a></p>".utf8)
            )
            expect(!richText.isEmpty, "rich text fixture has formats")
            expect(richText.byteSize == [richText.rtf, richText.rtfd, richText.html].compactMap { $0 }.reduce(0) { $0 + $1.count }, "rich text byte size counts all formats")
            let empty = RichTextContent(rtf: Data(), rtfd: Data(), html: Data())
            expect(empty == RichTextContent() && empty.isEmpty && empty.byteSize == 0, "empty format data normalizes to absent")

            runRichTextStoreTests(text: text, richText: richText)
            runRichTextMigrationTests(text: text, richText: richText)
            runRichTextPasteTests(text: text, richText: richText)
        } catch {
            failures += 1
            print("FAIL rich text fixture: \(error)")
        }
    }

    private static func runRichTextStoreTests(text: String, richText: RichTextContent) {
        withStore { store, clock, root in
            let capture = ClipboardCapture(text: text, richText: richText, imageData: tinyPNG(), sourceBundleId: "com.example.editor")
            let inserted = try store.ingest(capture)
            expect(inserted.map(\.kind) == [.image, .text], "rich text plus image keeps dual capture ordering")
            guard let item = inserted.first(where: { $0.kind == .text }) else {
                expect(false, "rich text capture inserts a text row")
                return
            }
            expect(item.richText == richText, "ingest preserves every rich text format")
            expect(item.byteSize == text.utf8.count + richText.byteSize, "stored byte size includes plain and formatted content")
            expect(inserted.first?.richText.isEmpty == true, "image capture does not acquire text formats")
            expect(try store.item(id: item.id)?.richText == richText, "item lookup restores rich text blobs")
            let found = try store.search("BOLD")
            expect(found.count == 1 && found.first?.richText == richText, "plain text search returns formatted content")
            let promoted = try store.promote(id: item.id, to: clock.date.addingTimeInterval(1))
            expect(promoted?.id == item.id && promoted?.richText == richText, "promoting a rich text item retains formats and identity")
            expect(promoted?.sourceBundleId == "com.example.editor", "rich text promotion retains source application")

            let reopened = try ClipboardStore(rootURL: root, settings: store.settings, clock: clock)
            reopened.pruneExecutor = { _ in }
            expect(try reopened.allItems().first?.richText == richText, "reopening store restores promoted rich text")
            try store.delete(id: item.id)
            expect(try store.item(id: item.id) == nil, "deleting rich text removes its row")
            let remaining = try store.allItems()
            expect(remaining.count == 1 && remaining.first?.kind == .image, "rich text deletion leaves captured image intact")
            if let image = remaining.first {
                expect(try store.loadImageData(for: image) == tinyPNG(), "rich text storage leaves image bytes intact")
            }
        }

        withStore { store, clock, _ in
            let plain = try store.insertText(text)
            expect(plain?.richText.isEmpty == true, "ordinary text retains empty rich text default")
            expect(try store.insertText(text) == nil, "identical plain text remains deduplicated")
            clock.date = clock.date.addingTimeInterval(1)
            let formatted = try store.insertText(text, richText: richText)
            expect(formatted != nil, "same characters with formatting are distinct from plain text")
            expect(try store.insertText(text, richText: richText) == nil, "identical characters and formats deduplicate")
            let differentHTML = RichTextContent(rtf: richText.rtf, rtfd: richText.rtfd, html: Data("<p><em>Bold</em> link</p>".utf8))
            clock.date = clock.date.addingTimeInterval(1)
            let changed = try store.insertText(text, richText: differentHTML)
            expect(changed != nil && changed?.contentHash != formatted?.contentHash, "same characters with different HTML do not deduplicate")
            let rtfOnly = RichTextContent(rtf: richText.rtf)
            clock.date = clock.date.addingTimeInterval(1)
            expect(try store.insertText(text, richText: rtfOnly) != nil, "removing alternative rich formats changes content identity")
            expect(try store.insertText(text, richText: rtfOnly) == nil, "identical RTF-only content deduplicates")
        }

        withStore { store, clock, _ in
            _ = try store.insertText("old formatted", richText: richText, createdAt: clock.date.addingTimeInterval(-8 * 86_400))
            let kept = try store.insertText(text, richText: richText)
            try store.prune()
            let afterAgePrune = try store.allItems()
            expect(afterAgePrune.count == 1 && afterAgePrune.first?.id == kept?.id, "age retention prunes formatted rows")
            expect(afterAgePrune.first?.richText == richText, "age pruning retains remaining format data")
            clock.date = clock.date.addingTimeInterval(1)
            let newest = try store.insertText("newest formatted", richText: richText)
            store.updateSettings(AppSettings(maxItems: 1, maxAgeDays: 0))
            try store.prune()
            let afterCountPrune = try store.allItems()
            expect(afterCountPrune.count == 1 && afterCountPrune.first?.id == newest?.id, "count retention prunes formatted rows")
            expect(afterCountPrune.first?.richText == richText, "count pruning retains remaining format data")
            try store.clearAll()
            expect(try store.allItems().isEmpty, "clear history removes formatted rows")
        }
    }

    private static func runRichTextMigrationTests(text: String, richText: RichTextContent) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LC-rich-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var legacyDB: OpaquePointer?
            guard sqlite3_open(root.appendingPathComponent("db.sqlite").path, &legacyDB) == SQLITE_OK else {
                expect(false, "open legacy rich text migration fixture")
                if let legacyDB { sqlite3_close(legacyDB) }
                return
            }
            do {
                defer { sqlite3_close(legacyDB) }
                try executeSQL(legacyDB, """
                CREATE TABLE items (
                  id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL,
                  created_at REAL NOT NULL, text_content TEXT, content_hash TEXT NOT NULL,
                  image_path TEXT, thumb_path TEXT, source_bundle_id TEXT,
                  byte_size INTEGER NOT NULL DEFAULT 0
                );
                """)
                try executeSQL(legacyDB, "INSERT INTO items (id, kind, created_at, text_content, content_hash, byte_size) VALUES ('legacy', 'text', 1700000000, ?, ?, 11);", bindings: ["legacy text", ContentHasher.sha256Hex(ofText: "legacy text")])
            }

            let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_001))
            var migrated: ClipboardStore? = try ClipboardStore(rootURL: root, settings: AppSettings(maxItems: 200, maxAgeDays: 0), clock: clock)
            migrated?.pruneExecutor = { _ in }
            let old = try migrated?.item(id: "legacy")
            expect(old?.textContent == "legacy text" && old?.richText.isEmpty == true, "schema migration preserves old text with absent formats")
            expect(try migrated?.insertText("legacy text") == nil, "schema migration preserves legacy plain text deduplication")
            let saved = try migrated?.insertText(text, richText: richText)
            guard let saved else {
                expect(false, "migrated database accepts rich text")
                return
            }
            migrated = nil

            let reopened = try ClipboardStore(rootURL: root, settings: AppSettings(maxItems: 200, maxAgeDays: 0), clock: clock)
            reopened.pruneExecutor = { _ in }
            expect(try reopened.item(id: saved.id)?.richText == richText, "migration survives close and reopen with original rich text bytes")
            expect(try reopened.item(id: "legacy")?.richText.isEmpty == true, "repeated migration preserves old plain text")
            var inspectionDB: OpaquePointer?
            guard sqlite3_open(root.appendingPathComponent("db.sqlite").path, &inspectionDB) == SQLITE_OK else {
                expect(false, "open migrated database inspection")
                if let inspectionDB { sqlite3_close(inspectionDB) }
                return
            }
            defer { sqlite3_close(inspectionDB) }
            expect(try queryInt(inspectionDB, "SELECT COUNT(*) FROM pragma_table_info('items') WHERE name IN ('rtf_data', 'rtfd_data', 'html_data');") == 3, "migration adds all three format columns once")
            expect(try queryInt(inspectionDB, "SELECT COUNT(*) FROM items WHERE typeof(rtf_data) = 'blob' AND typeof(rtfd_data) = 'blob' AND typeof(html_data) = 'blob';") == 1, "formatted representations persist as SQLite blobs")
        } catch {
            failures += 1
            print("FAIL rich text migration: \(error)")
        }
    }

    private static func runRichTextPasteTests(text: String, richText: RichTextContent) {
        let item = ClipboardItem(kind: .text, textContent: text, richText: richText, contentHash: "formatted")
        expect(PastePolicy.resolve(item: item, imageData: nil, plainTextMode: false, accessibilityTrusted: true) == .writeAndAutoPaste(.richText(text, richText)), "normal paste chooses original rich text formats")
        expect(PastePolicy.resolve(item: item, imageData: nil, plainTextMode: true, accessibilityTrusted: true) == .writeAndAutoPaste(.text(text)), "plain text mode strips formats in policy")
        let mock = MockPasteboard()
        let guard_ = SelfWriteGuard()
        let service = PasteService(accessibilityChecker: { false }, attemptAutoPaste: { false }, pasteboard: mock, keystroke: {}, selfWriteGuard: guard_)
        expect(service.writeToPasteboard(item: item, imageData: nil, plainTextMode: false) == .wroteClipboardOnly, "rich text service supports clipboard-only mode")
        expect(mock.lastText == text && mock.lastRichText == richText, "rich text service includes plain text fallback")
        expect(guard_.shouldIgnore(changeCount: mock.changeCount), "rich text paste suppresses recapture")
        _ = service.writeToPasteboard(item: item, imageData: nil, plainTextMode: true)
        expect(mock.lastText == text && mock.lastRichText == nil, "plain text paste clears prior mock formatting")

        // Named pasteboards isolate these tests from the user's general clipboard.
        let native = NSPasteboard(name: NSPasteboard.Name("LocalClip.rich-tests.\(UUID().uuidString)"))
        defer { native.releaseGlobally() }
        native.clearContents()
        expect(native.setString(text, forType: .string), "seed named pasteboard plain text")
        expect(native.setData(richText.rtf, forType: .rtf), "seed named pasteboard RTF")
        expect(native.setData(richText.rtfd, forType: .rtfd), "seed named pasteboard RTFD")
        expect(native.setData(richText.html, forType: .html), "seed named pasteboard HTML")
        let system = SystemPasteboard(board: native)
        let captured = system.readCapture(sourceBundleId: "com.example.editor")
        expect(captured.text == text && captured.richText == richText, "native capture preserves all source formats exactly")
        expect(captured.sourceBundleId == "com.example.editor", "native rich text capture preserves source application")
        withStore { store, _, root in
            let stored = try store.ingest(captured)
            guard let id = stored.first?.id else {
                expect(false, "native rich text capture enters history")
                return
            }
            let reopened = try ClipboardStore(rootURL: root, settings: store.settings)
            reopened.pruneExecutor = { _ in }
            guard let restored = try reopened.item(id: id) else {
                expect(false, "native rich text capture reloads from history")
                return
            }
            let writer = PasteService(accessibilityChecker: { false }, attemptAutoPaste: { false }, pasteboard: system, keystroke: {}, selfWriteGuard: SelfWriteGuard())
            expect(writer.writeToPasteboard(item: restored, imageData: nil, plainTextMode: false) == .wroteClipboardOnly, "stored rich text writes to native pasteboard")
            expect(native.string(forType: .string) == text, "native rich text paste includes plain text fallback")
            expect(native.data(forType: .rtf) == richText.rtf && native.data(forType: .rtfd) == richText.rtfd && native.data(forType: .html) == richText.html, "native paste restores each original representation byte-for-byte")
            if let rtf = native.data(forType: .rtf) {
                let decoded = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
                expect(decoded.string == text, "RTF content survives capture, storage and paste")
                let font = decoded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                expect(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true, "RTF bold style survives capture, storage and paste")
                let link = decoded.attribute(.link, at: 5, effectiveRange: nil)
                expect((link as? URL)?.absoluteString == "https://example.com/reference" || (link as? String) == "https://example.com/reference", "RTF hyperlink survives capture, storage and paste")
            } else {
                expect(false, "pasted RTF is available for format verification")
            }
            _ = writer.writeToPasteboard(item: restored, imageData: nil, plainTextMode: true)
            expect(native.string(forType: .string) == text, "native plain text mode retains characters")
            expect(native.data(forType: .rtf) == nil && native.data(forType: .rtfd) == nil && native.data(forType: .html) == nil, "native plain text paste clears all stale rich formats")
            expect(system.readCapture(sourceBundleId: nil).richText.isEmpty, "plain text recapture has no residual formatting")
            _ = writer.writeToPasteboard(item: restored, imageData: nil, plainTextMode: false)
            let imageItem = ClipboardItem(kind: .image, contentHash: "image")
            expect(writer.writeToPasteboard(item: imageItem, imageData: tinyPNG(), plainTextMode: true) == .wroteClipboardOnly, "plain text mode continues to support native image paste")
            expect(native.data(forType: .png) == tinyPNG(), "image paste preserves original image bytes")
            expect(native.data(forType: .rtf) == nil && native.data(forType: .rtfd) == nil && native.data(forType: .html) == nil, "image paste clears stale text formats")
        }

        native.clearContents()
        let first = NSPasteboardItem()
        first.setString("first plain item", forType: .string)
        let second = NSPasteboardItem()
        second.setString(text, forType: .string)
        if let rtf = richText.rtf { second.setData(rtf, forType: .rtf) }
        if let rtfd = richText.rtfd { second.setData(rtfd, forType: .rtfd) }
        if let html = richText.html { second.setData(html, forType: .html) }
        expect(native.writeObjects([first, second]), "seed independent named pasteboard items")
        let separateItems = system.readCapture(sourceBundleId: nil)
        expect(separateItems.text == "first plain item" && separateItems.richText.isEmpty, "capture never mixes first item's text with second item's formatting")

        native.clearContents()
        let formatOnly = NSPasteboardItem()
        if let rtf = richText.rtf { formatOnly.setData(rtf, forType: .rtf) }
        expect(native.writeObjects([formatOnly]), "seed format-only named pasteboard item")
        // macOS can synthesize a plain representation for an RTF-only source.
        let rtfCapture = system.readCapture(sourceBundleId: nil)
        expect(rtfCapture.text == text && rtfCapture.richText.rtf == richText.rtf, "RTF-only source uses system plain text fallback and retains its format")
    }
}
