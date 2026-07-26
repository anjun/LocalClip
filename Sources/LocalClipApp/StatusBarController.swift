import AppKit
import SwiftUI
import LocalClipCore

/// AppKit status item: left-click opens panel, right-click shows menu (Quit, etc.).
@MainActor
final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let model: AppModel
    private var permissionTimer: Timer?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.makeStatusBarImage()
            button.image?.isTemplate = true
            button.toolTip = "LocalClip"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
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
        // Light material under SwiftUI paper panel
        if #available(macOS 10.14, *) {
            host.view.wantsLayer = true
            host.view.layer?.backgroundColor = NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.985, alpha: 1).cgColor
        }
        pop.contentViewController = host
        popover = pop

        // Re-check Accessibility while untrusted (TCC can lag; also after user returns from Settings).
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.model.refreshAccessibility()
            }
        }
        RunLoop.main.add(permissionTimer!, forMode: .common)

        model.start()
        model.refreshAccessibility()
        AppDelegateClosePopover.shared = { [weak self] in
            self?.closePopover()
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let trustTitle = model.accessibilityTrusted
            ? "辅助功能：已信任 ✓"
            : "辅助功能：未信任"
        let trustItem = NSMenuItem(title: trustTitle, action: nil, keyEquivalent: "")
        trustItem.isEnabled = false
        menu.addItem(trustItem)

        menu.addItem(NSMenuItem(
            title: "重新检查辅助功能",
            action: #selector(recheckAccessibility),
            keyEquivalent: "r"
        ))
        menu.addItem(NSMenuItem(
            title: "打开辅助功能设置…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "退出并重新打开（刷新权限）",
            action: #selector(relaunch),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "退出 LocalClip",
            action: #selector(quit),
            keyEquivalent: "q"
        ))

        for item in menu.items {
            item.target = self
        }

        // Show menu under status item
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        // Clear so left-click keeps working next time
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.menu = nil
        }
    }

    private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        model.refreshAccessibility()
        model.refresh()
        model.frontmostTracker.observeFrontmost()
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Make key so search field works
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func closePopover() {
        popover?.performClose(nil)
    }

    @objc private func recheckAccessibility() {
        model.refreshAccessibility()
        if model.accessibilityTrusted {
            model.statusMessage = "辅助功能已生效"
        } else {
            model.statusMessage = "仍未信任：请在设置中确认已勾选，然后用「退出并重新打开」"
        }
    }

    @objc private func openAccessibilitySettings() {
        // Prompt once so macOS may register the app in the list
        _ = AccessibilityPaste.isTrusted(prompt: true)
        AccessibilityPaste.openSystemSettings()
        model.refreshAccessibility()
    }

    @objc private func relaunch() {
        closePopover()
        AccessibilityPaste.relaunchCurrentApp()
    }

    @objc private func quit() {
        model.stop()
        NSApp.terminate(nil)
    }

    /// Prefer bundled template PNG; fall back to SF Symbol.
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
