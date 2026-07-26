import AppKit
import SwiftUI

/// System-aligned visual language with light/dark adaptive colors.
/// Avoid gradients, glow, monospaced eyebrows, decorative rails.
enum LCTheme {
    /// Accent blue that stays readable on both light and dark surfaces.
    static let accent = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.isDark
            ? NSColor(calibratedRed: 0.40, green: 0.68, blue: 1.0, alpha: 1)
            : NSColor(calibratedRed: 0.0, green: 0.48, blue: 1.0, alpha: 1)
    }))

    static let bg = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.isDark
            ? NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)
            : NSColor.white
    }))

    static let bgSubtle = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.isDark
            ? NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.16, alpha: 1)
            : NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
    }))

    static let fill = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.isDark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.08)
            : NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.97, alpha: 1)
    }))

    static let border = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.isDark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.12)
            : NSColor(calibratedRed: 0.90, green: 0.90, blue: 0.92, alpha: 1)
    }))

    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)

    static let success = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.isDark
            ? NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.45, alpha: 1)
            : NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
    }))

    static let danger = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.isDark
            ? NSColor(calibratedRed: 1.0, green: 0.40, blue: 0.38, alpha: 1)
            : NSColor(calibratedRed: 1.0, green: 0.23, blue: 0.19, alpha: 1)
    }))

    static let warning = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.isDark
            ? NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.20, alpha: 1)
            : NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.0, alpha: 1)
    }))

    /// Selected-row fill: stronger in dark mode so keyboard/hover selection stays obvious.
    static let selectionFill = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.isDark
            ? NSColor(calibratedRed: 0.28, green: 0.48, blue: 0.85, alpha: 0.42)
            : NSColor(calibratedRed: 0.0, green: 0.48, blue: 1.0, alpha: 0.12)
    }))

    static let selectionStroke = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.isDark
            ? NSColor(calibratedRed: 0.45, green: 0.70, blue: 1.0, alpha: 0.55)
            : NSColor(calibratedRed: 0.0, green: 0.48, blue: 1.0, alpha: 0.35)
    }))

    static let hoverFill = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.isDark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.07)
            : NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.97, alpha: 1)
    }))

    // Compatibility aliases
    static let ink = accent
    static let inkSoft = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.isDark
            ? NSColor(calibratedRed: 0.40, green: 0.68, blue: 1.0, alpha: 0.18)
            : NSColor(calibratedRed: 0.0, green: 0.48, blue: 1.0, alpha: 0.10)
    }))
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

    /// Resolved NSColor for AppKit hosts (popover / window chrome).
    static var panelNSBackground: NSColor {
        NSColor(name: nil, dynamicProvider: { appearance in
            appearance.isDark
                ? NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.16, alpha: 1)
                : NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
        })
    }

    static var windowNSBackground: NSColor {
        NSColor(name: nil, dynamicProvider: { appearance in
            appearance.isDark
                ? NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)
                : NSColor.white
        })
    }
}

private extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
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
