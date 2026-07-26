import SwiftUI

/// LocalClip visual system — “ink on frosted slate”
/// Signature: monospaced meta + indigo ink rail on soft glass cards.
enum LCTheme {
    // Palette
    static let ink = Color(red: 0.35, green: 0.42, blue: 0.95)          // indigo ink
    static let inkSoft = Color(red: 0.45, green: 0.52, blue: 0.98).opacity(0.18)
    static let slate = Color(red: 0.11, green: 0.12, blue: 0.15)         // deep slate
    static let slateElevated = Color(red: 0.16, green: 0.17, blue: 0.21)
    static let mist = Color.white.opacity(0.06)
    static let hairline = Color.white.opacity(0.08)
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.48)
    static let textTertiary = Color.white.opacity(0.32)
    static let success = Color(red: 0.35, green: 0.82, blue: 0.62)
    static let danger = Color(red: 0.95, green: 0.40, blue: 0.42)
    static let warning = Color(red: 0.95, green: 0.72, blue: 0.35)

    static let panelWidth: CGFloat = 380
    static let panelHeight: CGFloat = 540
    static let radius: CGFloat = 14
    static let rowRadius: CGFloat = 12

    static var panelBackground: some View {
        ZStack {
            slate
            LinearGradient(
                colors: [
                    Color(red: 0.18, green: 0.20, blue: 0.32).opacity(0.55),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // soft vignette
            RadialGradient(
                colors: [ink.opacity(0.12), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 280
            )
        }
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
                .fill(LCTheme.mist)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(LCTheme.hairline, lineWidth: 1)
                )
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
