import AppKit
import Combine
import LocalClipCore
import SwiftUI

/// Compact update dialog (not Preferences): check / progress / install.
@MainActor
final class UpdateProgressController: NSObject {
    private var window: NSWindow?
    private var host: NSHostingController<UpdateProgressView>?
    private let model: AppModel
    private var cancellables = Set<AnyCancellable>()

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
        let root = UpdateProgressView(model: model) { [weak self] in
            self?.window?.close()
        }
        let host = NSHostingController(rootView: root)
        self.host = host
        let win = NSWindow(contentViewController: host)
        win.title = "软件更新"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 420, height: 240))
        win.isReleasedWhenClosed = false
        win.center()
        win.backgroundColor = NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.985, alpha: 1)
        window = win
    }
}

// MARK: - SwiftUI content

struct UpdateProgressView: View {
    @ObservedObject var model: AppModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(LCTheme.inkSoft)
                        .frame(width: 40, height: 40)
                    Image(systemName: headerIcon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(LCTheme.ink)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("LocalClip 更新")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(LCTheme.textPrimary)
                    Text("当前 \(AppIdentity.currentVersion())")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(LCTheme.textTertiary)
                }
                Spacer()
            }

            // Progress
            VStack(alignment: .leading, spacing: 8) {
                if model.isCheckingUpdate || model.isInstallingUpdate {
                    if let p = model.updateProgress {
                        ProgressView(value: p, total: 1.0)
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                    Text(model.updateCheckMessage ?? (model.isInstallingUpdate ? "正在下载…" : "正在检查…"))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(LCTheme.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let msg = model.updateCheckMessage {
                    Text(msg)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(model.updateAvailable ? LCTheme.ink : LCTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("点击下方按钮检查 GitHub 上的新版本。")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(LCTheme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(LCTheme.hairline, lineWidth: 1)
                    )
            )

            HStack(spacing: 10) {
                Button("关闭") { onClose() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if !model.isCheckingUpdate && !model.isInstallingUpdate {
                    Button("重新检查") {
                        model.checkForUpdates()
                    }
                }

                if model.updateAvailable, !model.isInstallingUpdate {
                    Button("打开下载页") {
                        model.openUpdatePage()
                    }
                    Button("立即更新") {
                        model.installUpdate()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.updateZipURL == nil)
                }
            }
        }
        .padding(22)
        .frame(width: 400)
        .background(LCTheme.paper)
    }

    private var headerIcon: String {
        if model.isInstallingUpdate { return "arrow.down.circle.fill" }
        if model.isCheckingUpdate { return "arrow.triangle.2.circlepath" }
        if model.updateAvailable { return "arrow.up.circle.fill" }
        return "checkmark.seal"
    }
}
