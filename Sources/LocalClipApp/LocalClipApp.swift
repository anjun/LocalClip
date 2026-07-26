import SwiftUI
import LocalClipCore
import AppKit

@main
struct LocalClipApp: App {
    @StateObject private var model: AppModel

    init() {
        // LSUIElement-style: hide dock icon when launched as packaged app
        NSApplication.shared.setActivationPolicy(.accessory)
        let created: AppModel
        do {
            created = try AppModel()
        } catch {
            fatalError("LocalClip failed to open store: \(error)")
        }
        _model = StateObject(wrappedValue: created)
    }

    var body: some Scene {
        MenuBarExtra {
            HistoryPanel()
                .environmentObject(model)
                .frame(width: 360, height: 480)
                .onAppear {
                    model.start()
                    model.refresh()
                }
        } label: {
            Label("LocalClip", systemImage: "doc.on.clipboard")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 360, height: 220)
        }
    }
}

struct HistoryPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

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

            if !model.accessibilityTrusted {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("未授予辅助功能：只能写入剪贴板，需手动 ⌘V")
                            .font(.caption)
                        Button("打开系统设置…") {
                            model.requestAccessibility()
                        }
                        .font(.caption)
                    }
                    Spacer()
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
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
                            model.pasteItem(item)
                        }
                        .contextMenu {
                            Button("粘贴") { model.pasteItem(item) }
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
                Button("刷新") { model.refresh() }
            }
            .padding(8)
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
                    Button("检查 / 授权") { model.requestAccessibility() }
                }
            }
            Section("保留") {
                Text("默认最多 200 条，且不超过 7 天。")
                    .font(.caption)
            }
        }
        .padding()
        .formStyle(.grouped)
    }
}
