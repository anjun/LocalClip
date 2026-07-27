import Foundation
import SQLite3

public enum ClipboardStoreError: Error, Equatable {
    case openFailed(String)
    case execFailed(String)
    case invalidCapture
}

/// Local SQLite-backed clipboard history. Zero network.
public final class ClipboardStore: @unchecked Sendable {
    private var db: OpaquePointer?
    public let rootURL: URL
    public let imagesURL: URL
    public let thumbsURL: URL
    private let clock: Clock
    public private(set) var settings: AppSettings
    private let lock = NSLock()
    /// Retention prune runs off the ingest hot path so copy capture stays responsive.
    private let pruneQueue = DispatchQueue(label: "com.localclip.store.prune", qos: .utility)
    /// Schedule body for retention prune. Default: utility-queue async.
    /// Tests replace with a holder that does not run until flushed, proving insert
    /// does not wait on prune.
    public var pruneExecutor: (@escaping () -> Void) -> Void = { _ in }

    public init(rootURL: URL, settings: AppSettings = .default, clock: Clock = SystemClock()) throws {
        self.rootURL = rootURL
        self.imagesURL = rootURL.appendingPathComponent("images", isDirectory: true)
        self.thumbsURL = rootURL.appendingPathComponent("thumbs", isDirectory: true)
        self.clock = clock
        self.settings = settings
        let queue = self.pruneQueue
        self.pruneExecutor = { work in queue.async(execute: work) }

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: thumbsURL, withIntermediateDirectories: true)

        let dbPath = rootURL.appendingPathComponent("db.sqlite").path
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw ClipboardStoreError.openFailed(msg)
        }
        try exec("""
        CREATE TABLE IF NOT EXISTS items (
          id TEXT PRIMARY KEY NOT NULL,
          kind TEXT NOT NULL,
          created_at REAL NOT NULL,
          text_content TEXT,
          content_hash TEXT NOT NULL,
          image_path TEXT,
          thumb_path TEXT,
          source_bundle_id TEXT,
          byte_size INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_items_created_at ON items(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_items_kind_created ON items(kind, created_at DESC);
        """)
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    public func updateSettings(_ settings: AppSettings) {
        lock.lock()
        self.settings = settings
        lock.unlock()
    }

    // MARK: - Capture insert (dual row support)

    /// Insert items from a single pasteboard capture.
    /// Dual text+image → two rows, **image first**, then text.
    /// Per-kind adjacent hash dedupe.
    @discardableResult
    public func ingest(_ capture: ClipboardCapture) throws -> [ClipboardItem] {
        let inserted: [ClipboardItem]
        do {
            lock.lock()
            defer { lock.unlock() }

            var built: [ClipboardItem] = []
            let baseTime = clock.now()
            let source = capture.sourceBundleId

            // When both present: image first in ingest result and in DESC list.
            // Give image a slightly newer timestamp so ORDER BY created_at DESC lists image above text.
            let hasBoth = capture.hasImage && capture.hasText
            let imageTime = hasBoth ? baseTime.addingTimeInterval(0.001) : baseTime
            let textTime = baseTime

            if capture.hasImage, let data = capture.imageData {
                if let item = try insertImageLocked(data: data, createdAt: imageTime, source: source) {
                    built.append(item)
                }
            }

            if capture.hasText, let text = capture.text {
                if let item = try insertTextLocked(text: text, createdAt: textTime, source: source) {
                    built.append(item)
                }
            }
            inserted = built
        }
        // Prune only after unlock — never on the write-lock critical section.
        schedulePrune()
        return inserted
    }

    @discardableResult
    public func insertText(_ text: String, createdAt: Date? = nil, sourceBundleId: String? = nil) throws -> ClipboardItem? {
        let item: ClipboardItem?
        do {
            lock.lock()
            defer { lock.unlock() }
            item = try insertTextLocked(
                text: text,
                createdAt: createdAt ?? clock.now(),
                source: sourceBundleId
            )
        }
        schedulePrune()
        return item
    }

    @discardableResult
    public func insertImage(data: Data, createdAt: Date? = nil, sourceBundleId: String? = nil) throws -> ClipboardItem? {
        let item: ClipboardItem?
        do {
            lock.lock()
            defer { lock.unlock() }
            item = try insertImageLocked(
                data: data,
                createdAt: createdAt ?? clock.now(),
                source: sourceBundleId
            )
        }
        schedulePrune()
        return item
    }

    /// Schedule retention prune off the insert call stack (never blocks UI / pasteboard tick).
    public func schedulePrune() {
        pruneExecutor { [weak self] in
            guard let self else { return }
            do {
                try self.prune()
            } catch {
                NSLog("LocalClip prune error: \(error)")
            }
        }
    }

    // MARK: - Query

    public func allItems() throws -> [ClipboardItem] {
        lock.lock()
        defer { lock.unlock() }
        return try fetchLocked(query: nil)
    }

    /// Case-insensitive substring on text. Non-empty search hides image-only rows.
    public func search(_ query: String) throws -> [ClipboardItem] {
        lock.lock()
        defer { lock.unlock() }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            return try fetchLocked(query: nil)
        }
        return try fetchLocked(query: q)
    }

    public func item(id: String) throws -> ClipboardItem? {
        lock.lock()
        defer { lock.unlock() }
        return try fetchByIdLocked(id)
    }

    public func loadImageData(for item: ClipboardItem) throws -> Data? {
        guard item.kind == .image, let rel = item.imagePath else { return nil }
        let url = rootURL.appendingPathComponent(rel)
        return try Data(contentsOf: url)
    }

    /// Absolute URL for a stored relative path (thumb or image).
    public func absoluteURL(forRelativePath path: String) -> URL {
        rootURL.appendingPathComponent(path)
    }

    /// Rebuild oversized “thumbs” that were written as full originals (pre-fix data).
    public func repairBloatedThumbnails() {
        lock.lock()
        defer { lock.unlock() }
        let items: [ClipboardItem]
        do {
            items = try fetchLocked(query: nil)
        } catch {
            return
        }
        for item in items where item.kind == .image {
            guard let thumbRel = item.thumbPath, let imageRel = item.imagePath else { continue }
            let thumbURL = rootURL.appendingPathComponent(thumbRel)
            let imageURL = rootURL.appendingPathComponent(imageRel)
            let thumbSize = (try? FileManager.default.attributesOfItem(atPath: thumbURL.path)[.size] as? NSNumber)?.intValue ?? 0
            guard thumbSize > ThumbnailMaker.maxThumbFileBytes else { continue }
            guard let full = try? Data(contentsOf: imageURL) else { continue }
            let fixed = ThumbnailMaker.preferredThumbData(from: full)
            try? fixed.write(to: thumbURL, options: .atomic)
        }
    }

    public func delete(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try deleteLocked(id: id)
    }

    public func clearAll() throws {
        lock.lock()
        defer { lock.unlock() }
        let items = try fetchLocked(query: nil)
        for item in items {
            try deleteLocked(id: item.id)
        }
    }

    // MARK: - Private insert

    private func newestHashLocked(kind: ClipboardItemKind) throws -> String? {
        let sql = "SELECT content_hash FROM items WHERE kind = ? ORDER BY created_at DESC LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ClipboardStoreError.execFailed(lastError())
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, kind.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                return String(cString: c)
            }
        }
        return nil
    }

    private func insertTextLocked(text: String, createdAt: Date, source: String?) throws -> ClipboardItem? {
        let hash = ContentHasher.sha256Hex(ofText: text)
        if let newest = try newestHashLocked(kind: .text), newest == hash {
            return nil // adjacent same-kind dedupe
        }
        let item = ClipboardItem(
            kind: .text,
            createdAt: createdAt,
            textContent: text,
            contentHash: hash,
            sourceBundleId: source,
            byteSize: text.utf8.count
        )
        try insertRowLocked(item)
        return item
    }

    private func insertImageLocked(data: Data, createdAt: Date, source: String?) throws -> ClipboardItem? {
        let hash = ContentHasher.sha256Hex(of: data)
        if let newest = try newestHashLocked(kind: .image), newest == hash {
            return nil
        }
        let id = UUID().uuidString
        let imageRel = "images/\(id).png"
        let thumbRel = "thumbs/\(id).jpg"
        let imageURL = rootURL.appendingPathComponent(imageRel)
        let thumbURL = rootURL.appendingPathComponent(thumbRel)

        // Store raw bytes as .png path (may be PNG or other; display uses NSImage)
        try data.write(to: imageURL, options: .atomic)

        // Real downscaled thumb — full-resolution dumps make the list unusably slow.
        let thumbData = ThumbnailMaker.preferredThumbData(from: data)
        try thumbData.write(to: thumbURL, options: .atomic)

        let item = ClipboardItem(
            id: id,
            kind: .image,
            createdAt: createdAt,
            textContent: nil,
            contentHash: hash,
            imagePath: imageRel,
            thumbPath: thumbRel,
            sourceBundleId: source,
            byteSize: data.count
        )
        try insertRowLocked(item)
        return item
    }

    private func insertRowLocked(_ item: ClipboardItem) throws {
        let sql = """
        INSERT INTO items (id, kind, created_at, text_content, content_hash, image_path, thumb_path, source_bundle_id, byte_size)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ClipboardStoreError.execFailed(lastError())
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, item.id)
        bindText(stmt, 2, item.kind.rawValue)
        sqlite3_bind_double(stmt, 3, item.createdAt.timeIntervalSince1970)
        if let t = item.textContent { bindText(stmt, 4, t) } else { sqlite3_bind_null(stmt, 4) }
        bindText(stmt, 5, item.contentHash)
        if let p = item.imagePath { bindText(stmt, 6, p) } else { sqlite3_bind_null(stmt, 6) }
        if let p = item.thumbPath { bindText(stmt, 7, p) } else { sqlite3_bind_null(stmt, 7) }
        if let s = item.sourceBundleId { bindText(stmt, 8, s) } else { sqlite3_bind_null(stmt, 8) }
        sqlite3_bind_int64(stmt, 9, Int64(item.byteSize))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ClipboardStoreError.execFailed(lastError())
        }
    }

    // MARK: - Prune

    public func prune() throws {
        lock.lock()
        defer { lock.unlock() }
        try pruneLocked()
    }

    private func pruneLocked() throws {
        let now = clock.now()
        if settings.maxAgeDays > 0 {
            let maxAge = TimeInterval(settings.maxAgeDays) * 24 * 60 * 60
            let cutoff = now.addingTimeInterval(-maxAge)
            let aged = try fetchIdsOlderThanLocked(cutoff)
            for id in aged {
                try deleteLocked(id: id)
            }
        }

        // Count prune: keep newest maxItems
        let all = try fetchLocked(query: nil) // newest first
        if all.count > settings.maxItems {
            let excess = all.suffix(from: settings.maxItems)
            for item in excess {
                try deleteLocked(id: item.id)
            }
        }
    }

    private func fetchIdsOlderThanLocked(_ cutoff: Date) throws -> [String] {
        let sql = "SELECT id FROM items WHERE created_at < ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ClipboardStoreError.execFailed(lastError())
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
        var ids: [String] = []
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw ClipboardStoreError.execFailed(lastError())
            }
            if let c = sqlite3_column_text(stmt, 0) {
                ids.append(String(cString: c))
            }
        }
        return ids
    }

    private func deleteLocked(id: String) throws {
        guard let item = try fetchByIdLocked(id) else { return }
        if let rel = item.imagePath {
            try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(rel))
        }
        if let rel = item.thumbPath {
            try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(rel))
        }
        let sql = "DELETE FROM items WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ClipboardStoreError.execFailed(lastError())
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ClipboardStoreError.execFailed(lastError())
        }
    }

    private func fetchByIdLocked(_ id: String) throws -> ClipboardItem? {
        let sql = """
        SELECT id, kind, created_at, text_content, content_hash, image_path, thumb_path, source_bundle_id, byte_size
        FROM items WHERE id = ? LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ClipboardStoreError.execFailed(lastError())
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return rowToItem(stmt)
        }
        return nil
    }

    private func fetchLocked(query: String?) throws -> [ClipboardItem] {
        let sql: String
        if query != nil {
            sql = """
            SELECT id, kind, created_at, text_content, content_hash, image_path, thumb_path, source_bundle_id, byte_size
            FROM items
            WHERE kind = 'text' AND text_content IS NOT NULL AND LOWER(text_content) LIKE '%' || LOWER(?) || '%'
            ORDER BY created_at DESC;
            """
        } else {
            sql = """
            SELECT id, kind, created_at, text_content, content_hash, image_path, thumb_path, source_bundle_id, byte_size
            FROM items
            ORDER BY created_at DESC;
            """
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ClipboardStoreError.execFailed(lastError())
        }
        defer { sqlite3_finalize(stmt) }
        if let query {
            bindText(stmt, 1, query)
        }
        var items: [ClipboardItem] = []
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw ClipboardStoreError.execFailed(lastError())
            }
            items.append(rowToItem(stmt))
        }
        return items
    }

    private func rowToItem(_ stmt: OpaquePointer?) -> ClipboardItem {
        func colText(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        let id = colText(0) ?? UUID().uuidString
        let kind = ClipboardItemKind(rawValue: colText(1) ?? "text") ?? .text
        let created = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
        let text = colText(3)
        let hash = colText(4) ?? ""
        let imagePath = colText(5)
        let thumbPath = colText(6)
        let source = colText(7)
        let size = Int(sqlite3_column_int64(stmt, 8))
        return ClipboardItem(
            id: id,
            kind: kind,
            createdAt: created,
            textContent: text,
            contentHash: hash,
            imagePath: imagePath,
            thumbPath: thumbPath,
            sourceBundleId: source,
            byteSize: size
        )
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? lastError()
            sqlite3_free(err)
            throw ClipboardStoreError.execFailed(message)
        }
    }

    private func lastError() -> String {
        guard let db else { return "no db" }
        return String(cString: sqlite3_errmsg(db))
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        _ = value.withCString { cstr in
            sqlite3_bind_text(stmt, idx, cstr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }
}
