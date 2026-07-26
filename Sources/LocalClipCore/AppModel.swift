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
    public private(set) var settings: AppSettings
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
                // Small delay so pasteboard settles
                Thread.sleep(forTimeInterval: 0.04)
                AccessibilityPaste.postCommandV()
            },
            selfWriteGuard: guard_
        )
    }

    public func start() {
        refreshAccessibility()
        let mon = ClipboardMonitor(
            store: store,
            pasteboard: systemPasteboard,
            selfWriteGuard: selfWriteGuard,
            pollInterval: settings.pollInterval
        )
        mon.onItemsChanged = { [weak self] in
            Task { @MainActor in
                self?.refresh()
            }
        }
        mon.start()
        monitor = mon

        if settings.launchAtLogin {
            registerLoginItem(enabled: true)
        }
    }

    public func stop() {
        monitor?.stop()
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
            let imageData = try store.loadImageData(for: item)
            let result = pasteService.paste(
                item: item,
                imageData: imageData,
                plainTextMode: plainTextPaste
            )
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
                // Login item registration may fail without proper signing/bundle; non-fatal.
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
