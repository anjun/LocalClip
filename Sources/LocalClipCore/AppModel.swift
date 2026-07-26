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
        refresh()
    }

    private func setupPasteService() {
        let guard_ = selfWriteGuard
        pasteService = PasteService(
            accessibilityChecker: { AccessibilityPaste.isTrusted(prompt: false) },
            pasteboard: systemPasteboard,
            keystroke: {
                AccessibilityPaste.postCommandV()
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
        } catch {
            statusMessage = "Load failed: \(error)"
        }
        refreshAccessibility()
    }

    public func refreshAccessibility() {
        accessibilityTrusted = AccessibilityPaste.isTrusted(prompt: false)
    }

    public func requestAccessibility() {
        _ = AccessibilityPaste.isTrusted(prompt: true)
        refreshAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public func pasteItem(_ item: ClipboardItem) {
        do {
            // Snapshot target before we become / stay key.
            frontmostTracker.observeFrontmost()
            let target = frontmostTracker.previousExternalApp
            let imageData = try store.loadImageData(for: item)
            let trusted = AccessibilityPaste.isTrusted(prompt: false)

            let result = pasteService.paste(
                item: item,
                imageData: imageData,
                plainTextMode: plainTextPaste,
                beforeKeystroke: {
                    // Follow AutoPasteOrchestration: dismiss host UI, activate previous, delay.
                    HostUIDismisser.dismissLocalClipWindows()
                    target?.activate(options: [.activateIgnoringOtherApps])
                    Thread.sleep(forTimeInterval: 0.08)
                }
            )

            // If untrusted we still wrote clipboard; no keystroke path.
            _ = trusted

            switch result {
            case .wroteAndAutoPasted:
                statusMessage = nil
            case .wroteClipboardOnly:
                statusMessage = "已复制到剪贴板（请开启辅助功能以自动粘贴，或手动 ⌘V）"
            case .failed:
                statusMessage = "粘贴失败"
            case .nothing:
                statusMessage = "无内容可粘贴"
            }
        } catch {
            statusMessage = "粘贴失败: \(error)"
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
