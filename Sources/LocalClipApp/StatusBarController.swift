import AppKit
import SwiftUI
import LocalClipCore

/// AppKit status item: left-click opens panel, right-click shows menu (Quit, etc.).
/// Global hotkey ⌥C toggles the same popover.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let model: AppModel
    private var permissionTimer: Timer?
    /// Keep menu alive while open (status-item menu=nil hack used to drop actions).
    private var activeContextMenu: NSMenu?
    /// Owned prefs window — never use SwiftUI Settings scene (it opens unexpectedly).
    private var preferencesWindow: NSWindow?
    private var updateProgressController: UpdateProgressController?

    /// After context menu closes, the dismissing click can fall through to the status
    /// button as a left-click. Swallow status-item actions briefly.
    private var suppressStatusActionsUntil: Date = .distantPast

    /// Menu item tags — only these exact items may open prefs / updates.
    private enum MenuTag: Int {
        case preferences = 1001
        case checkUpdates = 1002
    }

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.makeStatusBarImage()
            button.image?.isTemplate = true
            button.toolTip = "LocalClip · \(GlobalHotKey.displayLabel)"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // Never assign statusItem.menu — that fights the action-based click handler
        // and has historically opened preferences / dropped menu actions.
        statusItem = item

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.contentSize = NSSize(width: LCTheme.panelWidth, height: LCTheme.panelHeight)
        let host = NSHostingController(
            rootView: HistoryPanel()
                .environmentObject(model)
                .frame(width: LCTheme.panelWidth, height: LCTheme.panelHeight)
        )
        host.view.wantsLayer = true
        LCAppearance.applySystem(to: host.view)
        pop.contentViewController = host
        popover = pop

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.model.refreshAccessibility()
            }
        }
        RunLoop.main.add(permissionTimer!, forMode: .common)

        model.start()
        model.refreshAccessibility()
        AppDelegateClosePopover.shared = { [weak self] in
            self?.closePopover()
        }

        installGlobalHotKey()
    }

    private func installGlobalHotKey() {
        GlobalHotKey.shared.onPressed = { [weak self] in
            Task { @MainActor [weak self] in
                self?.togglePopover()
            }
        }
        if !GlobalHotKey.shared.registerOptionC() {
            model.statusMessage = "快捷键 \(GlobalHotKey.displayLabel) 注册失败：请检查辅助功能权限后重启"
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if Date() < suppressStatusActionsUntil {
            return
        }

        let event = NSApp.currentEvent
        // Right-click or Control-click → context menu only.
        if let event,
           event.type == .rightMouseUp
            || event.type == .rightMouseDown
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control)) {
            showContextMenu(with: event)
            return
        }
        // Left-click only opens the history panel — never preferences.
        togglePopover()
    }

    private func showContextMenu(with event: NSEvent) {
        guard let button = statusItem?.button else { return }

        // Close history popover first so menu / prefs / update windows don't fight it.
        closePopover()
        model.refreshAccessibility()

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        // No keyEquivalents on any item — empty keyEquivalent prevents system shortcuts
        // (especially "," for Preferences) from auto-firing when the menu appears.

        let trustItem = NSMenuItem(
            title: AccessibilityPaste.trustStatusLabel(),
            action: nil,
            keyEquivalent: ""
        )
        trustItem.isEnabled = false
        menu.addItem(trustItem)

        let recheck = NSMenuItem(
            title: "重新检查辅助功能",
            action: #selector(recheckAccessibility(_:)),
            keyEquivalent: ""
        )
        recheck.target = self
        recheck.isEnabled = true
        menu.addItem(recheck)

        let updates = NSMenuItem(
            title: "检查更新…",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updates.target = self
        updates.tag = MenuTag.checkUpdates.rawValue
        updates.isEnabled = true
        menu.addItem(updates)

        let openSettings = NSMenuItem(
            title: "打开辅助功能设置…",
            action: #selector(openAccessibilitySettings(_:)),
            keyEquivalent: ""
        )
        openSettings.target = self
        openSettings.isEnabled = true
        menu.addItem(openSettings)

        let relaunchItem = NSMenuItem(
            title: "退出并重新打开（刷新权限）",
            action: #selector(relaunch(_:)),
            keyEquivalent: ""
        )
        relaunchItem.target = self
        relaunchItem.isEnabled = true
        menu.addItem(relaunchItem)

        menu.addItem(.separator())

        // Preferences near the bottom — less likely to be hit by a sloppy click
        // when the menu first appears under the cursor.
        let prefs = NSMenuItem(
            title: "偏好设置…",
            action: #selector(openAppSettings(_:)),
            keyEquivalent: ""
        )
        prefs.target = self
        prefs.tag = MenuTag.preferences.rawValue
        prefs.isEnabled = true
        menu.addItem(prefs)

        let quitItem = NSMenuItem(
            title: "退出 LocalClip",
            action: #selector(quit(_:)),
            keyEquivalent: ""
        )
        quitItem.target = self
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        // Critical: pop up in-place. Do NOT assign statusItem.menu then clear it —
        // that race cancelled item actions and could surface the wrong window.
        activeContextMenu = menu
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === activeContextMenu {
            activeContextMenu = nil
        }
        // Swallow the click that dismissed the menu (and any immediate re-entry).
        suppressStatusActionsUntil = Date().addingTimeInterval(0.35)
    }

    /// Shared by menu-bar click and global hotkey ⌥C.
    func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        model.refreshAccessibility()
        // Async so opening the panel never blocks the main thread on SQLite / list rebuild.
        model.refreshAsync()
        model.frontmostTracker.observeFrontmost()
        if popover.isShown {
            popover.performClose(nil)
        } else {
            LCAppearance.applySystem(to: popover.contentViewController?.view)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Activate + key window so local key monitors receive ↑/↓/Return.
            NSApp.activate(ignoringOtherApps: true)
            if let win = popover.contentViewController?.view.window {
                win.makeKey()
                win.makeFirstResponder(popover.contentViewController?.view)
            }
        }
    }

    func closePopover() {
        popover?.performClose(nil)
    }

    @objc func recheckAccessibility(_ sender: Any?) {
        model.refreshAccessibility()
        let trusted = model.accessibilityTrusted
        let label = AccessibilityPaste.trustStatusLabel()
        let detail = AccessibilityPaste.debugStatusLine()

        if trusted {
            model.statusMessage = "\(label)"
        } else {
            model.statusMessage = "仍未信任：请在设置中勾选 LocalClip 后「退出并重新打开」"
        }

        let alert = NSAlert()
        alert.messageText = label
        if trusted {
            alert.informativeText = """
            自动粘贴应可用。若仍无法粘贴，请「退出并重新打开」一次。

            \(detail)
            """
            alert.alertStyle = .informational
        } else {
            alert.informativeText = """
            系统仍报告未授权。请打开「系统设置 → 隐私与安全性 → 辅助功能」，确认 LocalClip 已勾选；改权限后必须完全退出再打开。

            \(detail)
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "打开设置")
            alert.addButton(withTitle: "好")
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if !trusted, response == .alertFirstButtonReturn {
            openAccessibilitySettings(nil)
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        // Only accept explicit menu selection (or internal nil for tests/tools).
        if let item = sender as? NSMenuItem, item.tag != MenuTag.checkUpdates.rawValue {
            return
        }
        if updateProgressController == nil {
            updateProgressController = UpdateProgressController(model: model)
        }
        updateProgressController?.showAndStartCheck()
    }

    /// Opens app preferences (login item, privacy). Dedicated window only —
    /// never SwiftUI `Settings` scene (that scene opens on activation / Cmd+,).
    @objc func openAppSettings(_ sender: Any?) {
        // Refuse unexpected senders so prefs cannot open from stray actions.
        if let sender {
            if let item = sender as? NSMenuItem {
                guard item.tag == MenuTag.preferences.rawValue else { return }
            } else if !(sender is NSButton) {
                return
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        if preferencesWindow == nil {
            let host = NSHostingController(
                rootView: SettingsView()
                    .environmentObject(model)
            )
            host.view.appearance = NSApp.effectiveAppearance
            let window = NSWindow(contentViewController: host)
            window.title = "LocalClip 偏好设置"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 520, height: 640))
            window.minSize = NSSize(width: 480, height: 520)
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("localclip.preferences")
            window.center()
            preferencesWindow = window
        } else {
            preferencesWindow?.contentViewController = NSHostingController(
                rootView: SettingsView().environmentObject(model)
            )
            preferencesWindow?.contentViewController?.view.appearance = NSApp.effectiveAppearance
            preferencesWindow?.setContentSize(NSSize(width: 520, height: 640))
        }
        LCAppearance.applySystem(to: preferencesWindow)
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openAccessibilitySettings(_ sender: Any?) {
        AccessibilityPaste.openSystemSettings()
        model.refreshAccessibility()
    }

    @objc func relaunch(_ sender: Any?) {
        closePopover()
        AccessibilityPaste.relaunchCurrentApp()
    }

    @objc func quit(_ sender: Any?) {
        GlobalHotKey.shared.unregister()
        model.stop()
        NSApp.terminate(nil)
    }

    private static func makeStatusBarImage() -> NSImage {
        if let url = Bundle.main.url(forResource: "StatusBarIcon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.isTemplate = true
            img.size = NSSize(width: 18, height: 18)
            return img
        }
        let symbol = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "LocalClip")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        symbol.isTemplate = true
        return symbol
    }
}
