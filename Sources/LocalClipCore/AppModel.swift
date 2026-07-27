import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var items: [ClipboardItem] = []
    /// Bound to the history search field. Updates are debounced + loaded off the main thread
    /// so IME (中/英) composition and rapid typing do not hitch the UI.
    @Published public var searchQuery: String = "" {
        didSet {
            guard oldValue != searchQuery else { return }
            scheduleSearchRefresh()
        }
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
    /// Last GitHub update-check result (user-initiated).
    @Published public var updateCheckMessage: String?
    @Published public var updateAvailable: Bool = false
    @Published public var updateReleaseURL: URL?
    @Published public var updateZipURL: URL?
    @Published public private(set) var isCheckingUpdate: Bool = false
    @Published public private(set) var isInstallingUpdate: Bool = false
    /// 0...1 for determinate progress; nil means indeterminate (use with ProgressView).
    @Published public private(set) var updateProgress: Double?
    /// Last successful check payload (for install).
    private var lastUpdateResult: UpdateChecker.CheckResult?

    public let store: ClipboardStore
    public let selfWriteGuard = SelfWriteGuard()
    public let frontmostTracker = FrontmostAppTracker()
    public private(set) var settings: AppSettings
    public private(set) var isMonitoring: Bool = false
    private var monitor: ClipboardMonitor?
    private var pasteService: PasteService!
    private let systemPasteboard = SystemPasteboard()
    private let defaultsKey = "LocalClip.AppSettings.v1"
    /// Debounce for search box. Overridable in tests.
    public var searchDebounceNanoseconds: UInt64 = 160_000_000
    private var searchRefreshTask: Task<Void, Never>?
    /// Bumped on every load start / sync refresh so stale async results are dropped.
    private var itemsLoadGeneration: UInt64 = 0

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
                self?.refreshAsync()
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

    /// Synchronous history reload (explicit refresh / tests). Does not re-probe Accessibility —
    /// that path is expensive and is polled separately.
    public func refresh() {
        searchRefreshTask?.cancel()
        searchRefreshTask = nil
        itemsLoadGeneration &+= 1
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
    }

    /// Load history off the main actor, then publish items (startup / open panel / monitor).
    public func refreshAsync() {
        let query = searchQuery
        Task { @MainActor [weak self] in
            await self?.loadItemsAsync(for: query)
        }
    }

    /// Debounce search-box updates so IME composition / rapid typing do not block the main thread.
    private func scheduleSearchRefresh() {
        searchRefreshTask?.cancel()
        let query = searchQuery
        let delay = searchDebounceNanoseconds
        searchRefreshTask = Task { @MainActor [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            guard self.searchQuery == query else { return }
            await self.loadItemsAsync(for: query)
        }
    }

    private func loadItemsAsync(for query: String) async {
        itemsLoadGeneration &+= 1
        let gen = itemsLoadGeneration
        let store = self.store
        let loaded: [ClipboardItem]
        do {
            loaded = try await Task.detached(priority: .userInitiated) {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return try store.allItems()
                }
                return try store.search(query)
            }.value
        } catch {
            statusMessage = "Load failed: \(error)"
            return
        }
        // Drop stale results from an older generation or a superseded query.
        guard gen == itemsLoadGeneration, searchQuery == query else { return }
        items = loaded
        reconcileSelection()
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
        // Only open System Settings — do not call isTrusted(prompt: true), which shows a
        // redundant system AX dialog on top of Settings (and its close button is awkward).
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

    /// User-initiated GitHub Releases check.
    public func checkForUpdates() {
        guard !isCheckingUpdate, !isInstallingUpdate else { return }
        isCheckingUpdate = true
        updateProgress = nil
        updateCheckMessage = "正在检查更新…"
        updateAvailable = false
        updateReleaseURL = nil
        updateZipURL = nil
        lastUpdateResult = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Indeterminate pulse while waiting on network
                self.updateProgress = 0.15
                let result = try await UpdateChecker.check()
                self.updateProgress = 1.0
                self.lastUpdateResult = result
                self.updateReleaseURL = result.releaseURL
                self.updateZipURL = result.zipDownloadURL
                self.updateAvailable = result.isUpdateAvailable
                if result.isUpdateAvailable {
                    let asset = result.zipAssetName.map { " · \($0)" } ?? ""
                    self.updateCheckMessage =
                        "发现新版本 \(result.latestVersion)（当前 \(result.currentVersion)）\(asset)"
                    self.statusMessage = "发现新版本 \(result.latestVersion)"
                } else {
                    self.updateCheckMessage =
                        "已是最新版本 \(result.currentVersion)"
                }
            } catch {
                self.updateCheckMessage = "检查失败：\(error.localizedDescription)"
                self.updateAvailable = false
                self.updateProgress = nil
            }
            self.isCheckingUpdate = false
        }
    }

    public func openUpdatePage() {
        let url = updateReleaseURL ?? AppIdentity.releasesURL
        NSWorkspace.shared.open(url)
    }

    /// Download universal zip, replace app bundle after quit, relaunch.
    public func installUpdate() {
        guard !isInstallingUpdate else { return }
        guard let zip = updateZipURL ?? lastUpdateResult?.zipDownloadURL else {
            updateCheckMessage = "没有可下载的安装包，请打开下载页手动安装"
            return
        }
        isInstallingUpdate = true
        updateProgress = 0
        updateCheckMessage = "正在下载安装包…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await UpdateChecker.downloadAndPrepareInstall(
                    zipURL: zip,
                    onProgress: { fraction in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.updateProgress = max(0, min(1, fraction))
                            let pct = Int((fraction * 100).rounded())
                            if fraction < 0.95 {
                                self.updateCheckMessage = "正在下载… \(pct)%"
                            } else {
                                self.updateCheckMessage = "正在准备安装…"
                            }
                        }
                    }
                )
                self.updateProgress = 1
                self.updateCheckMessage = "下载完成，即将退出并安装新版本…"
                self.statusMessage = "正在安装更新…"
                try? await Task.sleep(nanoseconds: 600_000_000)
                GlobalHotKey.shared.unregister()
                self.stop()
                NSApp.terminate(nil)
            } catch {
                self.updateCheckMessage = "更新失败：\(error.localizedDescription)"
                self.isInstallingUpdate = false
                self.updateProgress = nil
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
