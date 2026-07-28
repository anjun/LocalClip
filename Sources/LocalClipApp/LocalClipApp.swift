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
        // Hide the SwiftUI bootstrap window (required Scene; all real UI is AppKit).
        Self.hideBootstrapWindows()
        guard let model = AppDelegate.sharedModel else { return }
        model.start()
        if AppDelegate.statusBar == nil {
            let bar = StatusBarController(model: model)
            bar.install()
            AppDelegate.statusBar = bar
        }
        model.refreshAccessibility()
        // One more pass after SwiftUI creates its Scene window.
        DispatchQueue.main.async {
            Self.hideBootstrapWindows()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppDelegate.sharedModel?.refreshAccessibility()
        // Never let the bootstrap / stray Settings-style window reappear on activate.
        Self.hideBootstrapWindows()
    }

    /// Order out the dummy WindowGroup used only for SwiftUI lifecycle.
    static func hideBootstrapWindows() {
        for window in NSApp.windows {
            let id = window.identifier?.rawValue ?? ""
            if id == "localclip-bootstrap"
                || window.title == "LocalClip Bootstrap"
                || (window.contentView?.subviews.isEmpty == true && window.frame.width <= 2) {
                window.alphaValue = 0
                window.collectionBehavior.insert([.transient, .ignoresCycle, .stationary])
                window.orderOut(nil)
            }
        }
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
        // Dummy scene only — real UI is AppKit (status item / popover / prefs window).
        // Do NOT use Settings { }: it opens on Cmd+, and can reappear when the app
        // becomes active (looked like “right-click menu opened preferences”).
        WindowGroup(id: "localclip-bootstrap") {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
                .onAppear {
                    AppDelegate.hideBootstrapWindows()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 1, height: 1)
        .commandsRemoved()
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
        HStack(alignment: .center, spacing: 12) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            Text("LocalClip")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LCTheme.textPrimary)
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
                Text("自动粘贴就绪")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(LCTheme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("未授权辅助功能时将尝试粘贴；失败请手动 ⌘V")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(LCTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("系统设置") { AccessibilityPaste.openSystemSettings() }
                    Button("重检") { model.refreshAccessibility() }
                    Button("重启") { AccessibilityPaste.relaunchCurrentApp() }
                }
                .buttonStyle(LCGhostButtonStyle())
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LCTheme.fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(LCTheme.border, lineWidth: 1)
                    )
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }

        if let msg = model.statusMessage {
            Text(msg)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(LCTheme.textSecondary)
                .padding(.horizontal, 16)
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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.items) { item in
                            HistoryRow(
                                item: item,
                                isHovered: hoveredID == item.id,
                                isSelected: model.selectedItemID == item.id
                            )
                            .id(item.id)
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
                                model.pasteItem(item)
                            }
                            .contextMenu {
                                Button("粘贴") { model.pasteItem(item) }
                                Button("删除", role: .destructive) { model.deleteItem(item) }
                            }
                            Divider().overlay(LCTheme.border).padding(.leading, 60)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .onChange(of: model.selectedItemID) { selectedID in
                    let ids = model.items.map(\.id)
                    guard let targetID = HistoryListSelection.scrollTargetID(
                        selected: selectedID,
                        in: ids
                    ) else { return }
                    proxy.scrollTo(targetID)
                }
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

                Button("刷新") { model.refreshAsync() }
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
            // Selected accent bar (minimal, system-list style)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(isSelected ? LCTheme.accent : Color.clear)
                .frame(width: 3, height: 36)

            mediaThumb
            VStack(alignment: .leading, spacing: 4) {
                primaryLabel
                metaLine
            }
            Spacer(minLength: 0)

            if isSelected {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LCTheme.accent)
                    .padding(6)
                    .background(
                        Circle().fill(LCTheme.accent.opacity(0.12))
                    )
                    .help("Return 粘贴")
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(rowFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? LCTheme.selectionStroke : Color.clear, lineWidth: 1)
                )
        )
    }

    private var rowFill: Color {
        if isSelected { return LCTheme.selectionFill }
        if isHovered { return LCTheme.hoverFill }
        return Color.clear
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
            Text(item.kind == .image ? "图片" : "文本")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(LCTheme.textTertiary)
            Text(Self.relativeFormatter.localizedString(for: item.createdAt, relativeTo: Date()))
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(LCTheme.textTertiary)
            if item.kind == .image {
                Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteSize), countStyle: .file))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(LCTheme.textTertiary)
            }
        }
    }

    private func placeholder(icon: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LCTheme.fill)
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LCTheme.textTertiary)
        }
        .frame(width: 40, height: 40)
    }
}


// MARK: - Settings

/// Preferences — system-aligned light/dark surfaces.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var launchAtLogin: Bool = true
    @State private var retentionMaxItems = AppSettings.default.maxItems
    @State private var retentionMaxAgeDays = AppSettings.default.maxAgeDays
    @State private var pendingRetention: (maxItems: Int, maxAgeDays: Int)?
    @State private var showsRetentionConfirmation = false
    /// Local gate covering the gap before `model.isUpdatingRetention` flips true.
    @State private var isApplyingRetention = false
    /// Bumped to force Menu pickers to re-sync when selection is rejected/cancelled.
    @State private var retentionPickerEpoch = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("设置")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(LCTheme.textPrimary)

                settingsGroup(title: "启动", subtitle: "开机后在菜单栏自动运行") {
                    settingsRow {
                        Text("登录时启动")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(LCTheme.textPrimary)
                        Spacer()
                        Toggle("", isOn: $launchAtLogin)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: launchAtLogin) { new in
                                model.registerLoginItem(enabled: new)
                            }
                    }
                }

                settingsGroup(title: "权限", subtitle: "自动粘贴需要辅助功能授权") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(model.accessibilityTrusted ? "辅助功能：已就绪" : "辅助功能：未授权")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(LCTheme.textPrimary)
                            Spacer()
                            Circle()
                                .fill(model.accessibilityTrusted ? LCTheme.success : LCTheme.warning)
                                .frame(width: 8, height: 8)
                        }
                        HStack(spacing: 8) {
                            minimalButton("检查") { model.refreshAccessibility() }
                            minimalButton("系统设置") { AccessibilityPaste.openSystemSettings() }
                        }
                        minimalButton("退出并重新打开", fullWidth: true) {
                            AccessibilityPaste.relaunchCurrentApp()
                        }
                    }
                }

                settingsGroup(title: "保留", subtitle: "超出后自动清理记录与图片文件") {
                    VStack(spacing: 12) {
                        settingsRow {
                            Text("最多保留")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(LCTheme.textPrimary)
                            Spacer()
                            Picker("最多保留", selection: retentionMaxItemsBinding) {
                                ForEach(retentionMaxItemChoices, id: \.self) { maxItems in
                                    Text("\(maxItems) 条").tag(maxItems)
                                }
                            }
                            .pickerStyle(.menu)
                            .id("retention-items-\(retentionMaxItems)-\(retentionPickerEpoch)")
                            .disabled(isRetentionControlsDisabled)
                        }

                        settingsRow {
                            Text("保留时长")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(LCTheme.textPrimary)
                            Spacer()
                            Picker("保留时长", selection: retentionMaxAgeDaysBinding) {
                                ForEach(retentionMaxAgeDayChoices, id: \.self) { maxAgeDays in
                                    Text(maxAgeDays == 0 ? "永久" : "\(maxAgeDays) 天")
                                        .tag(maxAgeDays)
                                }
                            }
                            .pickerStyle(.menu)
                            .id("retention-age-\(retentionMaxAgeDays)-\(retentionPickerEpoch)")
                            .disabled(isRetentionControlsDisabled)
                        }
                    }
                }

                settingsGroup(title: "更新", subtitle: "仅在点击时访问 GitHub Releases") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("当前版本 \(AppIdentity.currentVersion())")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(LCTheme.textPrimary)
                        if let msg = model.updateCheckMessage {
                            Text(msg)
                                .font(.system(size: 13))
                                .foregroundStyle(LCTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        VStack(spacing: 8) {
                            minimalButton(
                                model.isCheckingUpdate ? "检查中…" : "检查更新",
                                fullWidth: true,
                                primary: true,
                                enabled: !model.isCheckingUpdate && !model.isInstallingUpdate
                            ) {
                                model.checkForUpdates()
                            }
                            if model.updateAvailable {
                                minimalButton(
                                    model.isInstallingUpdate ? "安装中…" : "立即更新",
                                    fullWidth: true,
                                    primary: true,
                                    enabled: !model.isInstallingUpdate && model.updateZipURL != nil
                                ) {
                                    model.installUpdate()
                                }
                                minimalButton("打开下载页", fullWidth: true) {
                                    model.openUpdatePage()
                                }
                            }
                            minimalButton("GitHub", fullWidth: true) {
                                NSWorkspace.shared.open(AppIdentity.githubURL)
                            }
                        }
                    }
                }

                settingsGroup(title: "隐私", subtitle: nil) {
                    Text("历史仅保存在本机 Application Support/LocalClip。无分析、无同步。默认不联网。")
                        .font(.system(size: 13))
                        .foregroundStyle(LCTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(3)
                }

                minimalButton("退出 LocalClip", fullWidth: true, destructive: true) {
                    model.stop()
                    NSApp.terminate(nil)
                }
                .padding(.top, 4)
            }
            .padding(28)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .background(LCTheme.bg)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 560, idealHeight: 640)
        .onAppear {
            launchAtLogin = model.settings.launchAtLogin
            retentionMaxItems = model.settings.maxItems
            retentionMaxAgeDays = model.settings.maxAgeDays
            model.refreshAccessibility()
        }
        .alert("清理并应用新的保留设置？", isPresented: $showsRetentionConfirmation) {
            Button("取消", role: .cancel) {
                pendingRetention = nil
                retentionPickerEpoch += 1
            }
            Button("清理并应用", role: .destructive) {
                guard let pendingRetention else { return }
                self.pendingRetention = nil
                applyRetention(
                    maxItems: pendingRetention.maxItems,
                    maxAgeDays: pendingRetention.maxAgeDays
                )
            }
        } message: {
            Text("缩短保留范围会立即清理不符合新设置的历史记录和图片文件。")
        }
    }

    private var isRetentionControlsDisabled: Bool {
        isApplyingRetention || model.isUpdatingRetention
    }

    private var retentionMaxItemsBinding: Binding<Int> {
        Binding(
            get: { retentionMaxItems },
            set: { proposeRetention(maxItems: $0, maxAgeDays: retentionMaxAgeDays) }
        )
    }

    private var retentionMaxAgeDaysBinding: Binding<Int> {
        Binding(
            get: { retentionMaxAgeDays },
            set: { proposeRetention(maxItems: retentionMaxItems, maxAgeDays: $0) }
        )
    }

    private var retentionMaxItemChoices: [Int] {
        retentionOptions(AppSettings.retentionMaxItemOptions, including: retentionMaxItems)
    }

    private var retentionMaxAgeDayChoices: [Int] {
        retentionOptions(AppSettings.retentionMaxAgeDayOptions, including: retentionMaxAgeDays)
    }

    /// Keep preset order (e.g. 永久 last); only append a non-preset current value.
    private func retentionOptions(_ presets: [Int], including currentValue: Int) -> [Int] {
        if presets.contains(currentValue) {
            return presets
        }
        return presets + [currentValue]
    }

    private func proposeRetention(maxItems: Int, maxAgeDays: Int) {
        guard !isRetentionControlsDisabled else { return }
        if AppSettings.isRetentionReduction(
            fromMaxItems: retentionMaxItems,
            fromMaxAgeDays: retentionMaxAgeDays,
            toMaxItems: maxItems,
            toMaxAgeDays: maxAgeDays
        ) {
            pendingRetention = (maxItems, maxAgeDays)
            showsRetentionConfirmation = true
        } else {
            applyRetention(maxItems: maxItems, maxAgeDays: maxAgeDays)
        }
    }

    private func applyRetention(maxItems: Int, maxAgeDays: Int) {
        guard !isRetentionControlsDisabled else { return }
        isApplyingRetention = true
        retentionMaxItems = maxItems
        retentionMaxAgeDays = maxAgeDays

        Task { @MainActor in
            defer { isApplyingRetention = false }
            let didUpdate = await model.updateRetention(maxItems: maxItems, maxAgeDays: maxAgeDays)
            if !didUpdate {
                retentionMaxItems = model.settings.maxItems
                retentionMaxAgeDays = model.settings.maxAgeDays
                retentionPickerEpoch += 1
            }
        }
    }

    private func settingsGroup<Content: View>(
        title: String,
        subtitle: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LCTheme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(LCTheme.textSecondary)
            }
            content()
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LCTheme.fill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(LCTheme.border, lineWidth: 1)
                        )
                )
        }
    }

    private func settingsRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12, content: content)
    }

    private func minimalButton(
        _ title: String,
        fullWidth: Bool = false,
        primary: Bool = false,
        destructive: Bool = false,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(LCDialogButtonStyle(primary: primary, destructive: destructive))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}
