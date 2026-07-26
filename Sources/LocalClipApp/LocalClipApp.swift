import SwiftUI
import LocalClipCore
import AppKit

/// Starts clipboard monitoring at process launch; owns AppKit status item.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var sharedModel: AppModel?
    static var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let model = AppDelegate.sharedModel else { return }
        model.start()
        // Prefer AppKit status item (left panel / right menu) over MenuBarExtra.
        if AppDelegate.statusBar == nil {
            let bar = StatusBarController(model: model)
            bar.install()
            AppDelegate.statusBar = bar
        }
        model.refreshAccessibility()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppDelegate.sharedModel?.refreshAccessibility()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.sharedModel?.stop()
    }
}

@main
struct LocalClipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let created: AppModel
        do {
            created = try AppModel()
        } catch {
            fatalError("LocalClip failed to open store: \(error)")
        }
        _model = StateObject(wrappedValue: created)
        AppDelegate.sharedModel = created
        created.start()
    }

    var body: some Scene {
        // Settings window only; menu bar UI is AppKit StatusBarController.
        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 380, height: 280)
        }
    }
}

struct HistoryPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("LocalClip")
                    .font(.headline)
                Spacer()
                Toggle("纯文本", isOn: $model.plainTextPaste)
                    .toggleStyle(.checkbox)
                    .help("文本以纯文本粘贴；图片仍粘贴图片")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            TextField("搜索文本…", text: $model.searchQuery)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            if model.accessibilityTrusted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("辅助功能已生效 · 点选可自动粘贴")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            } else {
                // Soft notice: we still attempt auto-paste (ad-hoc trust API is flaky).
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.blue)
                        Text("系统未回报「已信任」，但仍会尝试自动粘贴。若内容没贴上，请手动 ⌘V。")
                            .font(.caption)
                    }
                    Text("可选：系统设置中确认勾选 LocalClip 后点「退出并重新打开」。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("打开系统设置…") {
                            _ = AccessibilityPaste.isTrusted(prompt: true)
                            AccessibilityPaste.openSystemSettings()
                        }
                        Button("重新检查") { model.refreshAccessibility() }
                        Button("退出并重新打开") { AccessibilityPaste.relaunchCurrentApp() }
                    }
                    .font(.caption)
                }
                .padding(8)
                .background(Color.blue.opacity(0.10))
                .padding(.horizontal, 8)
            }

            if let msg = model.statusMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            Divider()

            if model.items.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "clipboard")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("暂无历史")
                        .foregroundStyle(.secondary)
                    Text("复制文本或图片后会出现在这里")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(model.items) { item in
                    HistoryRow(item: item)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Close popover first so previous app can activate
                            AppDelegate.statusBar?.closePopover()
                            model.pasteItem(item)
                        }
                        .contextMenu {
                            Button("粘贴") {
                                AppDelegate.statusBar?.closePopover()
                                model.pasteItem(item)
                            }
                            Button("删除", role: .destructive) { model.deleteItem(item) }
                        }
                }
                .listStyle(.plain)
            }

            Divider()
            HStack {
                Button("清空") { model.clearHistory() }
                Spacer()
                Text("\(model.items.count) 条 · 本地 · 零联网")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if model.isMonitoring {
                    Text("监听中")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                Button("刷新") { model.refresh() }
                Button("退出") {
                    model.stop()
                    NSApp.terminate(nil)
                }
                .help("退出 LocalClip（菜单栏图标右键也可退出）")
            }
            .padding(8)
        }
        .onAppear {
            model.refresh()
            model.refreshAccessibility()
            model.frontmostTracker.observeFrontmost()
        }
    }
}

struct HistoryRow: View {
    let item: ClipboardItem
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                switch item.kind {
                case .image:
                    if let path = item.thumbPath ?? item.imagePath {
                        let url = model.store.rootURL.appendingPathComponent(path)
                        if let nsImage = NSImage(contentsOf: url) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 48, height: 48)
                                .clipped()
                                .cornerRadius(6)
                        } else {
                            placeholder(icon: "photo")
                        }
                    } else {
                        placeholder(icon: "photo")
                    }
                case .text:
                    placeholder(icon: "text.alignleft")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                switch item.kind {
                case .text:
                    Text(item.textContent ?? "")
                        .lineLimit(3)
                        .font(.system(.body, design: .default))
                case .image:
                    Text("图片")
                        .font(.body)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteSize), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(item.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func placeholder(icon: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
            Image(systemName: icon)
                .foregroundStyle(.secondary)
        }
        .frame(width: 48, height: 48)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var launchAtLogin: Bool = true

    var body: some View {
        Form {
            Section("隐私") {
                Text("所有历史仅保存在本机 Application Support/LocalClip。无网络、无分析、无同步。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("启动") {
                Toggle("登录时启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { new in
                        model.registerLoginItem(enabled: new)
                    }
                    .onAppear { launchAtLogin = model.settings.launchAtLogin }
            }
            Section("权限") {
                HStack {
                    Text(model.accessibilityTrusted ? "辅助功能：已信任" : "辅助功能：未信任")
                    Spacer()
                    Button("检查") { model.refreshAccessibility() }
                    Button("系统设置…") {
                        _ = AccessibilityPaste.isTrusted(prompt: true)
                        AccessibilityPaste.openSystemSettings()
                    }
                }
                if !model.accessibilityTrusted {
                    Button("退出并重新打开以刷新权限") {
                        AccessibilityPaste.relaunchCurrentApp()
                    }
                }
            }
            Section("保留") {
                Text("默认最多 200 条，且不超过 7 天。")
                    .font(.caption)
            }
            Section("退出") {
                Button("退出 LocalClip", role: .destructive) {
                    model.stop()
                    NSApp.terminate(nil)
                }
            }
        }
        .padding()
        .formStyle(.grouped)
    }
}
