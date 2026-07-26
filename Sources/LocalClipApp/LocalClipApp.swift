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

/// Preferences — “desk blotter”: wide paper field, indigo ink rail, stacked full-width actions.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var launchAtLogin: Bool = true

    var body: some View {
        ZStack {
            // Soft paper field + cool wash
            LCTheme.paper
            LinearGradient(
                colors: [
                    Color(red: 0.90, green: 0.93, blue: 1.0).opacity(0.65),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .center
            )

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                        .padding(.bottom, 28)

                    VStack(alignment: .leading, spacing: 22) {
                        sectionBlock(title: "关于隐私", caption: "数据不出本机") {
                            privacyBody
                        }
                        sectionBlock(title: "启动与权限", caption: "登录项 · 辅助功能") {
                            launchBody
                            Divider().overlay(LCTheme.hairline).padding(.vertical, 4)
                            accessBody
                        }
                        sectionBlock(title: "保留", caption: "自动清理") {
                            retentionBody
                        }
                        sectionBlock(title: "更新", caption: "GitHub Releases") {
                            updatesBody
                        }
                        sectionBlock(title: "退出", caption: nil) {
                            quitBody
                        }
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 32)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 540, idealWidth: 560, minHeight: 640, idealHeight: 720)
        .preferredColorScheme(.light)
        .onAppear {
            launchAtLogin = model.settings.launchAtLogin
            model.refreshAccessibility()
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                appMark
                VStack(alignment: .leading, spacing: 6) {
                    Text("偏好设置")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(LCTheme.textPrimary)
                    Text("LocalClip · 菜单栏剪贴板")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(LCTheme.textSecondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(GlobalHotKey.displayLabel)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(LCTheme.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(LCTheme.inkSoft)
                        )
                    Text("全局唤起")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(LCTheme.textTertiary)
                }
            }

            // Version strip
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("VERSION")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(LCTheme.textTertiary)
                        .tracking(1.1)
                    Text(AppIdentity.currentVersion())
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(LCTheme.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle()
                    .fill(LCTheme.hairline)
                    .frame(width: 1, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text("HOTKEY")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(LCTheme.textTertiary)
                        .tracking(1.1)
                    Text("⌥C 切换面板")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(LCTheme.textPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 20)
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LCTheme.paperElevated)
                    .shadow(color: Color.black.opacity(0.05), radius: 12, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(LCTheme.hairline, lineWidth: 1)
            )
        }
    }

    private var appMark: some View {
        Group {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [LCTheme.ink, LCTheme.ink.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "paperclip")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(-22))
                }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: LCTheme.ink.opacity(0.25), radius: 10, y: 4)
    }

    // MARK: Sections

    private func sectionBlock<Content: View>(
        title: String,
        caption: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            // Signature ink rail
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(LCTheme.ink.opacity(0.85))
                .frame(width: 3)
                .padding(.top, 4)
                .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(LCTheme.textPrimary)
                    if let caption {
                        Text(caption)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(LCTheme.textTertiary)
                    }
                }
                content()
            }
            .padding(.leading, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LCTheme.paperElevated)
                .shadow(color: Color.black.opacity(0.04), radius: 10, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(LCTheme.hairline, lineWidth: 1)
        )
    }

    // MARK: Bodies

    private var privacyBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("剪贴板历史只保存在本机 Application Support/LocalClip。")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(LCTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)
            Text("无分析、无账号、无同步。默认不联网；仅在你点击检查/安装更新时访问 GitHub。")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(LCTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)
        }
    }

    private var launchBody: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("登录时启动")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(LCTheme.textPrimary)
                Text("开机后常驻菜单栏，不显示 Dock 图标")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(LCTheme.textTertiary)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .labelsHidden()
                .onChange(of: launchAtLogin) { new in
                    model.registerLoginItem(enabled: new)
                }
        }
    }

    private var accessBody: some View {
        let ready = model.accessibilityTrusted
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(ready ? LCTheme.success : LCTheme.warning)
                    .frame(width: 8, height: 8)
                    .shadow(color: (ready ? LCTheme.success : LCTheme.warning).opacity(0.45), radius: 3)
                Text(ready ? "自动粘贴已就绪" : "需要辅助功能授权")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(LCTheme.textPrimary)
                Spacer()
                Text(ready ? "OK" : "NEED")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(ready ? LCTheme.success : LCTheme.warning)
            }

            Text("授权后才能把历史自动粘贴到其它 App；未授权时仍可写入剪贴板，再手动 ⌘V。")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(LCTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)

            // Full-width stacked actions — never cram chips in one row
            VStack(spacing: 8) {
                settingsSecondaryButton(title: "重新检查权限", systemImage: "arrow.clockwise") {
                    model.refreshAccessibility()
                }
                settingsSecondaryButton(title: "打开系统辅助功能设置", systemImage: "gearshape") {
                    AccessibilityPaste.openSystemSettings()
                }
                settingsSecondaryButton(title: "退出并重新打开（刷新权限）", systemImage: "arrow.triangle.2.circlepath") {
                    AccessibilityPaste.relaunchCurrentApp()
                }
            }
        }
    }

    private var retentionBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                retentionStat(value: "200", label: "条上限")
                retentionStat(value: "7", label: "天上限")
            }
            Text("超出条数或天数会自动清理，对应图片文件一并删除。")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(LCTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var updatesBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("手动检查 GitHub Releases。有新版本时可一键下载并替换本机 App。")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(LCTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)

            if let msg = model.updateCheckMessage {
                Text(msg)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(model.updateAvailable ? LCTheme.ink : LCTheme.textPrimary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(model.updateAvailable ? LCTheme.inkSoft : LCTheme.mist)
                    )
            }

            VStack(spacing: 8) {
                settingsPrimaryButton(
                    title: model.isCheckingUpdate ? "检查中…" : "检查更新",
                    systemImage: "arrow.triangle.2.circlepath",
                    enabled: !model.isCheckingUpdate && !model.isInstallingUpdate
                ) {
                    model.checkForUpdates()
                }

                if model.updateAvailable {
                    settingsPrimaryButton(
                        title: model.isInstallingUpdate ? "正在下载安装…" : "立即更新并重启",
                        systemImage: "arrow.down.app.fill",
                        enabled: !model.isInstallingUpdate && model.updateZipURL != nil,
                        emphasized: true
                    ) {
                        model.installUpdate()
                    }

                    settingsSecondaryButton(title: "在浏览器打开下载页", systemImage: "safari") {
                        model.openUpdatePage()
                    }
                }

                settingsSecondaryButton(title: "打开 GitHub 仓库", systemImage: "link") {
                    NSWorkspace.shared.open(AppIdentity.githubURL)
                }
            }
        }
    }

    private var quitBody: some View {
        settingsSecondaryButton(title: "退出 LocalClip", systemImage: "power", destructive: true) {
            model.stop()
            NSApp.terminate(nil)
        }
    }

    // MARK: Controls

    private func retentionStat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(LCTheme.ink)
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(LCTheme.textTertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LCTheme.inkSoft)
        )
    }

    private func settingsPrimaryButton(
        title: String,
        systemImage: String,
        enabled: Bool = true,
        emphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
            }
            .foregroundStyle(emphasized ? Color.white : LCTheme.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(emphasized ? LCTheme.ink : LCTheme.inkSoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(emphasized ? Color.clear : LCTheme.ink.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
    }

    private func settingsSecondaryButton(
        title: String,
        systemImage: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
            }
            .foregroundStyle(destructive ? LCTheme.danger : LCTheme.textSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(destructive ? LCTheme.danger.opacity(0.07) : LCTheme.mist)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        destructive ? LCTheme.danger.opacity(0.2) : LCTheme.hairline,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
