import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var items: [ClipboardItem] = []
    @Published public var searchQuery: String = "" {
        didSet { refresh() }
    }
    @Published public var plainTextPaste: Bool {
        didSet {
            settings.plainTextPaste = plainTextPaste
            persistSettings()
        }
    }
    @Published public var accessibilityTrusted: Bool = false
    @Published public var statusMessage: String?
    /// Keyboard / visual selection in history list (id of item).
    @Published public var selectedItemID: String?

    public let store: ClipboardStore
    public let selfWriteGuard = SelfWriteGuard()
    public let frontmostTracker = FrontmostAppTracker()
    public private(set) var settings: AppSettings
    public private(set) var isMonitoring: Bool = false
    private var monitor: ClipboardMonitor?
    private var pasteService: PasteService!
    private let systemPasteboard = SystemPasteboard()
    private let defaultsKey = "LocalClip.AppSettings.v1"

    public init(storeRoot: URL? = nil) throws {
        let root = storeRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalClip", isDirectory: true)
        var loaded = AppSettings.default
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(CodableSettings.self, from: data) {
            loaded = decoded.settings
        }
        self.settings = loaded
        self.plainTextPaste = loaded.plainTextPaste
        self.store = try ClipboardStore(rootURL: root, settings: loaded)
        setupPasteService()
        // Defer history load off init so app chrome appears immediately.
        // `start()` / panel onAppear call `refreshAsync()`.
    }

    private func setupPasteService() {
        let guard_ = selfWriteGuard
        let tracker = frontmostTracker
        pasteService = PasteService(
            accessibilityChecker: { AccessibilityPaste.isTrusted(prompt: false) },
            // Always attempt auto-paste by default (ad-hoc trust flag is unreliable).
            attemptAutoPaste: { AccessibilityPaste.shouldAttemptAutoPaste() },
            pasteboard: systemPasteboard,
            keystroke: {
                let pid = tracker.previousExternalApp?.processIdentifier
                AccessibilityPaste.postCommandV(toPid: pid)
            },
            selfWriteGuard: guard_
        )
    }

    /// Start clipboard monitoring. Safe to call multiple times; starts at app launch.
    public func start() {
        if isMonitoring, monitor?.isRunning == true {
            refreshAccessibility()
            return
        }
        refreshAccessibility()
        let mon = ClipboardMonitor(
            store: store,
            pasteboard: systemPasteboard,
            selfWriteGuard: selfWriteGuard,
            frontmostTracker: frontmostTracker,
            pollInterval: settings.pollInterval
        )
        mon.onItemsChanged = { [weak self] in
            Task { @MainActor in
                self?.refresh()
            }
        }
        mon.start()
        monitor = mon
        isMonitoring = true
        frontmostTracker.observeFrontmost()
        // History + legacy thumbs off the main actor (capture path stays light).
        refreshAsync()
        let storeRef = store
        Task.detached(priority: .utility) {
            storeRef.repairBloatedThumbnails()
        }

        if settings.launchAtLogin {
            registerLoginItem(enabled: true)
        }
    }

    public func stop() {
        monitor?.stop()
        isMonitoring = false
    }

    public func refresh() {
        do {
            if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items = try store.allItems()
            } else {
                items = try store.search(searchQuery)
            }
            reconcileSelection()
        } catch {
            statusMessage = "Load failed: \(error)"
        }
        refreshAccessibility()
    }

    /// Load history off the main actor, then publish items (startup / open panel).
    public func refreshAsync() {
        let store = self.store
        let query = searchQuery
        Task { @MainActor [weak self] in
            let loaded: [ClipboardItem]
            do {
                loaded = try await Task.detached(priority: .userInitiated) {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return try store.allItems()
                    }
                    return try store.search(query)
                }.value
            } catch {
                self?.statusMessage = "Load failed: \(error)"
                return
            }
            guard let self else { return }
            // Drop stale result if user typed a new search meanwhile.
            if self.searchQuery == query {
                self.items = loaded
                self.reconcileSelection()
            }
            self.refreshAccessibility()
        }
    }

    private func reconcileSelection() {
        let ids = items.map(\.id)
        if let selectedItemID, ids.contains(selectedItemID) { return }
        selectedItemID = ids.first
    }

    /// Move keyboard selection (↑/↓). Pure index math via HistoryListSelection.
    public func moveSelection(delta: Int) {
        let ids = items.map(\.id)
        let current = HistoryListSelection.index(of: selectedItemID, in: ids)
        guard let next = HistoryListSelection.moveIndex(current: current, count: ids.count, delta: delta) else {
            return
        }
        selectedItemID = ids[next]
    }

    /// Paste selected item (Return). Resolves id then calls `pasteItem` — same as click.
    public func pasteSelectedItem() {
        let ids = items.map(\.id)
        guard let targetID = HistoryListSelection.pasteTargetID(selected: selectedItemID, in: ids),
              let item = items.first(where: { $0.id == targetID })
        else { return }
        pasteItem(item)
    }

    /// Paste item at list index (keyboard). Same path as click.
    public func pasteItem(at index: Int) {
        guard index >= 0, index < items.count else { return }
        pasteItem(items[index])
    }

    public func refreshAccessibility() {
        accessibilityTrusted = AccessibilityPaste.isTrusted(prompt: false)
    }

    public func requestAccessibility() {
        _ = AccessibilityPaste.isTrusted(prompt: true)
        AccessibilityPaste.openSystemSettings()
        refreshAccessibility()
        if !accessibilityTrusted {
            statusMessage = "授权后请「退出并重新打开」LocalClip"
        }
    }

    /// Paste history item. Fully async — never blocks main with sleep or large-image decode races.
    public func pasteItem(_ item: ClipboardItem) {
        frontmostTracker.observeFrontmost()
        let target = frontmostTracker.previousExternalApp
        let plain = plainTextPaste
        // Close UI immediately (not inside a blocking paste path).
        AppDelegateClosePopover.shared?()
        HostUIDismisser.dismissLocalClipWindows()

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performPaste(item: item, target: target, plainTextMode: plain)
        }
    }

    private func performPaste(
        item: ClipboardItem,
        target: NSRunningApplication?,
        plainTextMode: Bool
    ) async {
        // Load image off main actor so 5K PNGs don't freeze / kill the UI thread.
        let imageData: Data?
        if item.kind == .image {
            let store = self.store
            do {
                imageData = try await Task.detached(priority: .userInitiated) {
                    try store.loadImageData(for: item)
                }.value
            } catch {
                statusMessage = "粘贴失败: \(error)"
                return
            }
        } else {
            imageData = nil
        }

        let result = pasteService.writeToPasteboard(
            item: item,
            imageData: imageData,
            plainTextMode: plainTextMode
        )

        switch result {
        case .wroteAndAutoPasted:
            target?.activate(options: [.activateIgnoringOtherApps])
            // Non-blocking delay so target becomes key before ⌘V.
            try? await Task.sleep(nanoseconds: 150_000_000)
            AccessibilityPaste.postCommandV(toPid: target?.processIdentifier)
            if accessibilityTrusted {
                statusMessage = nil
            } else {
                statusMessage = "已粘贴（若未出现请手动 ⌘V）"
            }
        case .wroteClipboardOnly:
            statusMessage = "已复制到剪贴板，请 ⌘V"
        case .failed:
            statusMessage = "粘贴失败"
        case .nothing:
            statusMessage = "无内容可粘贴"
        }
    }


    public func clearHistory() {
        try? store.clearAll()
        refresh()
    }

    public func deleteItem(_ item: ClipboardItem) {
        try? store.delete(id: item.id)
        refresh()
    }

    private func persistSettings() {
        let box = CodableSettings(settings: settings)
        if let data = try? JSONEncoder().encode(box) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        store.updateSettings(settings)
    }

    public func registerLoginItem(enabled: Bool) {
        settings.launchAtLogin = enabled
        persistSettings()
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("LocalClip login item: \(error)")
            }
        }
    }
}

private struct CodableSettings: Codable {
    var pollIntervalMs: Int
    var maxItems: Int
    var maxAgeDays: Int
    var plainTextPaste: Bool
    var launchAtLogin: Bool

    var settings: AppSettings {
        AppSettings(
            pollIntervalMs: pollIntervalMs,
            maxItems: maxItems,
            maxAgeDays: maxAgeDays,
            plainTextPaste: plainTextPaste,
            launchAtLogin: launchAtLogin
        )
    }

    init(settings: AppSettings) {
        pollIntervalMs = settings.pollIntervalMs
        maxItems = settings.maxItems
        maxAgeDays = settings.maxAgeDays
        plainTextPaste = settings.plainTextPaste
        launchAtLogin = settings.launchAtLogin
    }
}
