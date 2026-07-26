import SwiftUI

/// LocalClip visual system — “ink on pale paper”
/// Signature: monospaced meta + indigo ink rail on soft white cards.
/// User preference: brighter than the previous frosted-slate dark panel.
enum LCTheme {
    // Palette — cool paper + indigo ink
    static let ink = Color(red: 0.28, green: 0.36, blue: 0.92)          // indigo ink
    static let inkSoft = Color(red: 0.35, green: 0.42, blue: 0.95).opacity(0.12)
    static let paper = Color(red: 0.96, green: 0.97, blue: 0.985)        // pale paper
    static let paperElevated = Color.white
    static let mist = Color(red: 0.90, green: 0.92, blue: 0.96).opacity(0.85)
    static let hairline = Color.black.opacity(0.07)
    static let textPrimary = Color(red: 0.12, green: 0.14, blue: 0.18)
    static let textSecondary = Color(red: 0.38, green: 0.42, blue: 0.50)
    static let textTertiary = Color(red: 0.55, green: 0.58, blue: 0.64)
    static let success = Color(red: 0.12, green: 0.62, blue: 0.45)
    static let danger = Color(red: 0.86, green: 0.28, blue: 0.30)
    static let warning = Color(red: 0.82, green: 0.55, blue: 0.12)

    // Compatibility aliases used by older call sites
    static let slate = paper
    static let slateElevated = paperElevated

    static let panelWidth: CGFloat = 380
    static let panelHeight: CGFloat = 540
    static let radius: CGFloat = 14
    static let rowRadius: CGFloat = 12

    static var panelBackground: some View {
        ZStack {
            paper
            LinearGradient(
                colors: [
                    Color(red: 0.88, green: 0.91, blue: 1.0).opacity(0.55),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [ink.opacity(0.08), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 280
            )
        }
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
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(LCTheme.textPrimary)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LCTheme.paperElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(LCTheme.hairline, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.03), radius: 2, y: 1)
        )
    }
}

struct LCGhostButtonStyle: ButtonStyle {
    var destructive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(destructive ? LCTheme.danger : LCTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? LCTheme.mist : Color.clear)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct LCChipToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                configuration.label
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(configuration.isOn ? LCTheme.ink : LCTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(configuration.isOn ? LCTheme.inkSoft : LCTheme.mist)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                configuration.isOn ? LCTheme.ink.opacity(0.35) : LCTheme.hairline,
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
