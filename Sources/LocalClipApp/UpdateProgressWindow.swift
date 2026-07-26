import AppKit
import Combine
import LocalClipCore
import SwiftUI

/// Compact update dialog with progress (not Preferences).
@MainActor
final class UpdateProgressController: NSObject {
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func showAndStartCheck() {
        ensureWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !model.isCheckingUpdate && !model.isInstallingUpdate {
            model.checkForUpdates()
        }
    }

    private func ensureWindow() {
        if window != nil { return }
        let host = NSHostingController(
            rootView: UpdateProgressView(model: model) { [weak self] in
                self?.window?.close()
            }
        )
        let win = NSWindow(contentViewController: host)
        win.title = "软件更新"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 400, height: 220))
        win.isReleasedWhenClosed = false
        win.center()
        win.backgroundColor = LCTheme.windowNSBackground
        window = win
    }
}

struct UpdateProgressView: View {
    @ObservedObject var model: AppModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("软件更新")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LCTheme.textPrimary)
            Text("当前版本 \(AppIdentity.currentVersion())")
                .font(.system(size: 12))
                .foregroundStyle(LCTheme.textSecondary)

            VStack(alignment: .leading, spacing: 8) {
                if model.isCheckingUpdate || model.isInstallingUpdate {
                    if let p = model.updateProgress {
                        ProgressView(value: p, total: 1.0)
                    } else {
                        ProgressView()
                    }
                }
                Text(statusText)
                    .font(.system(size: 13))
                    .foregroundStyle(LCTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(LCTheme.border, lineWidth: 1)
            )

            HStack {
                Button("关闭") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if !model.isCheckingUpdate && !model.isInstallingUpdate {
                    Button("重新检查") { model.checkForUpdates() }
                }
                if model.updateAvailable, !model.isInstallingUpdate {
                    Button("打开下载页") { model.openUpdatePage() }
                    Button("立即更新") { model.installUpdate() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.updateZipURL == nil)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(LCTheme.bg)
    }

    private var statusText: String {
        if let msg = model.updateCheckMessage { return msg }
        if model.isInstallingUpdate { return "正在下载…" }
        if model.isCheckingUpdate { return "正在检查…" }
        return "点击重新检查以获取最新版本。"
    }
}
