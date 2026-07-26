import SwiftUI
import LocalClipCore
import AppKit

/// Starts clipboard monitoring at process launch; owns AppKit status item.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var sharedModel: AppModel?
    static var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Apply bundle icon (shows in Accessibility, Force Quit, etc.)
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        guard let model = AppDelegate.sharedModel else { return }
        model.start()
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
        GlobalHotKey.shared.unregister()
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
            // Don't crash the process with fatalError — surface a running accessory
            // that can still quit cleanly (store open almost never fails).
            NSLog("LocalClip failed to open store: \(error)")
            // Last-resort: temp store so UI can still load
            created = try! AppModel(storeRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("LocalClip-fallback", isDirectory: true))
        }
        _model = StateObject(wrappedValue: created)
        AppDelegate.sharedModel = created
        // Start monitor in applicationDidFinishLaunching / StatusBarController.install —
        // not here — so AppKit is fully up before timers / pasteboard access.
    }

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 400, height: 320)
        }
    }
}

// MARK: - Keyboard router (panel)

/// Routes ↑/↓/Return for the history list.
/// Always intercepts navigation keys (search field must not swallow ↑/↓/Return —
/// that was why keyboard paste appeared dead). Other keys still reach the search field.
enum HistoryPanelKeyRouter {
    /// keyCode: 125 ↓, 126 ↑, 36 return, 76 keypad enter
    static func handle(_ event: NSEvent) -> NSEvent? {
        guard let model = AppDelegate.sharedModel else { return event }
        switch event.keyCode {
        case 125: // down arrow
            DispatchQueue.main.async { model.moveSelection(delta: 1) }
            return nil
        case 126: // up arrow
            DispatchQueue.main.async { model.moveSelection(delta: -1) }
            return nil
        case 36, 76: // return / enter → same paste path as click
            DispatchQueue.main.async { model.pasteSelectedItem() }
            return nil
        default:
            return event
        }
    }
}

// MARK: - History Panel

struct HistoryPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var hoveredID: String?
    @State private var keyMonitor: Any?

    var body: some View {
        ZStack {
            LCTheme.panelBackground
            VStack(spacing: 0) {
                header
                searchBar
                statusStrip
                content
                footer
            }
        }
        .frame(width: LCTheme.panelWidth, height: LCTheme.panelHeight)
        .preferredColorScheme(.light)
        .onAppear {
            model.refreshAsync()
            model.refreshAccessibility()
            model.frontmostTracker.observeFrontmost()
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        // Read AppModel via shared reference so we never capture a stale View struct.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            HistoryPanelKeyRouter.handle(event)
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            // Brand mark: prefer app icon, fall back to ink tile + paperclip
            Group {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .shadow(color: LCTheme.ink.opacity(0.22), radius: 5, y: 2)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [LCTheme.ink, LCTheme.ink.opacity(0.75)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 28, height: 28)
                            .shadow(color: LCTheme.ink.opacity(0.28), radius: 6, y: 2)
                        Image(systemName: "paperclip")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .rotationEffect(.degrees(-25))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("LocalClip")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(LCTheme.textPrimary)
                    .tracking(0.3)
                Text("本地 · 零联网")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(LCTheme.textTertiary)
            }

            Spacer()

            Toggle(isOn: $model.plainTextPaste) {
                Text("纯文本")
            }
            .toggleStyle(LCChipToggleStyle())
            .help("文本以纯文本粘贴；图片仍为图片")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: Search

    private var searchBar: some View {
        TextField("搜索剪贴记录…", text: $model.searchQuery)
            .textFieldStyle(LCSearchFieldStyle())
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
    }

    // MARK: Status

    @ViewBuilder
    private var statusStrip: some View {
        if model.accessibilityTrusted {
            HStack(spacing: 6) {
                Circle()
                    .fill(LCTheme.success)
                    .frame(width: 6, height: 6)
                    .shadow(color: LCTheme.success.opacity(0.45), radius: 3)
                Text(AccessibilityPaste.trustStatusLabel().replacingOccurrences(of: "辅助功能：", with: "") + " · 自动粘贴")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(LCTheme.textSecondary)
                Spacer()
                if model.isMonitoring {
                    Text("LIVE")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(LCTheme.success)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(LCTheme.success.opacity(0.12))
                        )
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LCTheme.warning)
                    Text("将尝试自动粘贴；若未贴上请 ⌘V")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(LCTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Button("系统设置") {
                        _ = AccessibilityPaste.isTrusted(prompt: true)
                        AccessibilityPaste.openSystemSettings()
                    }
                    Button("重检") { model.refreshAccessibility() }
                    Button("重启 App") { AccessibilityPaste.relaunchCurrentApp() }
                }
                .buttonStyle(LCGhostButtonStyle())
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LCTheme.warning.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(LCTheme.warning.opacity(0.22), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }

        if let msg = model.statusMessage {
            Text(msg)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(LCTheme.ink)
                .padding(.horizontal, 18)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.items) { item in
                        HistoryRow(
                            item: item,
                            isHovered: hoveredID == item.id,
                            isSelected: model.selectedItemID == item.id
                        )
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering {
                                hoveredID = item.id
                            } else if hoveredID == item.id {
                                hoveredID = nil
                            }
                        }
                        .onTapGesture {
                            model.selectedItemID = item.id
                            // Same paste entry as Return — never a parallel path.
                            model.pasteItem(item)
                        }
                        .contextMenu {
                            Button("粘贴") { model.pasteItem(item) }
                            Button("删除", role: .destructive) { model.deleteItem(item) }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle()
                    .fill(LCTheme.inkSoft)
                    .frame(width: 72, height: 72)
                Image(systemName: "scissors")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(LCTheme.ink)
            }
            VStack(spacing: 6) {
                Text("还没有剪下的内容")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(LCTheme.textPrimary)
                Text("复制文字或截图后，会出现在这里")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(LCTheme.textTertiary)
                Text("\(GlobalHotKey.displayLabel) 可随时唤出面板")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(LCTheme.ink.opacity(0.85))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(LCTheme.hairline)
                .frame(height: 1)

            HStack(spacing: 4) {
                Button("清空") { model.clearHistory() }
                    .buttonStyle(LCGhostButtonStyle(destructive: true))

                Spacer()

                Text(GlobalHotKey.displayLabel)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LCTheme.ink)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(LCTheme.inkSoft)
                    )
                    .help("全局快捷键：切换历史面板")

                HStack(spacing: 6) {
                    Text("\(model.items.count)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(LCTheme.textPrimary)
                    Text("条记录")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(LCTheme.textTertiary)
                }
                .padding(.horizontal, 8)

                Button("刷新") { model.refresh() }
                    .buttonStyle(LCGhostButtonStyle())

                Button("退出") {
                    model.stop()
                    NSApp.terminate(nil)
                }
                .buttonStyle(LCGhostButtonStyle())
                .help("也可右键菜单栏图标退出")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(LCTheme.paper.opacity(0.92))
    }
}

// MARK: - Row

struct HistoryRow: View {
    let item: ClipboardItem
    var isHovered: Bool = false
    var isSelected: Bool = false
    @EnvironmentObject var model: AppModel

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            mediaThumb

            VStack(alignment: .leading, spacing: 5) {
                primaryLabel
                metaLine
            }

            Spacer(minLength: 0)

            if isHovered || isSelected {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LCTheme.ink)
                    .padding(6)
                    .background(Circle().fill(LCTheme.inkSoft))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if isHovered || isSelected {
                RoundedRectangle(cornerRadius: 2)
                    .fill(LCTheme.ink)
                    .frame(width: 3)
                    .padding(.vertical, 10)
                    .padding(.leading, 3)
            }
        }
        // No per-row animation — was a major scroll hitch with large lists.
    }

    @ViewBuilder
    private var mediaThumb: some View {
        switch item.kind {
        case .image:
            if let path = item.thumbPath ?? item.imagePath {
                let url = model.store.absoluteURL(forRelativePath: path)
                if let nsImage = ThumbImageCache.image(at: url) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(LCTheme.hairline, lineWidth: 1)
                        )
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

    @ViewBuilder
    private var primaryLabel: some View {
        switch item.kind {
        case .text:
            Text(item.textContent ?? "")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(LCTheme.textPrimary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        case .image:
            Text("图片")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(LCTheme.textPrimary)
        }
    }

    private var metaLine: some View {
        HStack(spacing: 8) {
            Text(kindTag)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(LCTheme.ink)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(LCTheme.inkSoft)
                )

            Text(Self.relativeFormatter.localizedString(for: item.createdAt, relativeTo: Date()))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(LCTheme.textTertiary)

            if item.kind == .image {
                Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteSize), countStyle: .file))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(LCTheme.textTertiary)
            }
        }
    }

    private var kindTag: String {
        item.kind == .image ? "IMG" : "TXT"
    }

    private var rowBackground: some View {
        let highlight = isHovered || isSelected
        return RoundedRectangle(cornerRadius: LCTheme.rowRadius, style: .continuous)
            .fill(highlight ? LCTheme.inkSoft : LCTheme.paperElevated)
            .overlay(
                RoundedRectangle(cornerRadius: LCTheme.rowRadius, style: .continuous)
                    .strokeBorder(highlight ? LCTheme.ink.opacity(0.28) : LCTheme.hairline, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(highlight ? 0.06 : 0.03), radius: highlight ? 6 : 2, y: 1)
    }

    private func placeholder(icon: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LCTheme.mist)
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LCTheme.textSecondary)
        }
        .frame(width: 44, height: 44)
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(LCTheme.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var launchAtLogin: Bool = true

    var body: some View {
        Form {
            Section("隐私") {
                Text("历史仅保存在本机 Application Support/LocalClip。无网络、无分析、无同步。")
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
                    Text(AccessibilityPaste.trustStatusLabel())
                    Spacer()
                    Button("检查") { model.refreshAccessibility() }
                    Button("系统设置…") {
                        _ = AccessibilityPaste.isTrusted(prompt: true)
                        AccessibilityPaste.openSystemSettings()
                    }
                }
                Button("退出并重新打开") {
                    AccessibilityPaste.relaunchCurrentApp()
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
