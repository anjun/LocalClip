import AppKit
import SwiftUI

/// Minimal system-like visual language (white / gray / single accent).
/// Avoid gradients, glow, monospaced eyebrows, decorative rails.
enum LCTheme {
    static let accent = Color(red: 0.0, green: 0.48, blue: 1.0) // system-like blue
    static let bg = Color.white
    static let bgSubtle = Color(red: 0.96, green: 0.96, blue: 0.97) // #F5F5F7
    static let fill = Color(red: 0.95, green: 0.95, blue: 0.97)
    static let border = Color(red: 0.90, green: 0.90, blue: 0.92)
    static let textPrimary = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let textSecondary = Color(red: 0.53, green: 0.53, blue: 0.55)
    static let textTertiary = Color(red: 0.68, green: 0.68, blue: 0.70)
    static let success = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let danger = Color(red: 1.0, green: 0.23, blue: 0.19)
    static let warning = Color(red: 1.0, green: 0.58, blue: 0.0)

    // Compatibility aliases (old names used across views)
    static let ink = accent
    static let inkSoft = accent.opacity(0.10)
    static let paper = bg
    static let paperElevated = bg
    static let mist = fill
    static let hairline = border
    static let slate = bgSubtle
    static let slateElevated = bg

    static let panelWidth: CGFloat = 380
    static let panelHeight: CGFloat = 540
    static let radius: CGFloat = 10
    static let rowRadius: CGFloat = 10

    static var panelBackground: some View {
        bgSubtle
    }
}

/// In-memory thumbnail cache — list must never re-decode disk images every frame.
@MainActor
enum ThumbImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 80
        c.totalCostLimit = 12 * 1024 * 1024
        return c
    }()

    static func image(at url: URL) -> NSImage? {
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let img = NSImage(contentsOf: url) else { return nil }
        let cost = max(1, Int(img.size.width * img.size.height * 4))
        cache.setObject(img, forKey: key, cost: cost)
        return img
    }

    static func clear() {
        cache.removeAllObjects()
    }
}

struct LCSearchFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LCTheme.textTertiary)
            configuration
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(LCTheme.textPrimary)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LCTheme.fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(LCTheme.border, lineWidth: 1)
                )
        )
    }
}

struct LCGhostButtonStyle: ButtonStyle {
    var destructive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(destructive ? LCTheme.danger : LCTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? LCTheme.fill : Color.clear)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct LCChipToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Text(configuration.isOn ? "纯文本 · 开" : "纯文本")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(configuration.isOn ? Color.white : LCTheme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(configuration.isOn ? LCTheme.accent : LCTheme.fill)
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(configuration.isOn ? Color.clear : LCTheme.border, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}
