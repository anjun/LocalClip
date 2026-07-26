import Foundation

public enum PastePayload: Equatable, Sendable {
    case text(String)
    case image(Data)
}

public enum PasteAction: Equatable, Sendable {
    /// Write pasteboard and attempt ⌘V
    case writeAndAutoPaste(PastePayload)
    /// Write pasteboard only (Accessibility not trusted)
    case writeClipboardOnly(PastePayload)
    case nothing
}

/// Pure decision logic for paste — tested without Accessibility session.
public enum PastePolicy {
    /// Resolve what to paste for an item given plain-text mode and Accessibility trust.
    public static func resolve(
        item: ClipboardItem,
        imageData: Data?,
        plainTextMode: Bool,
        accessibilityTrusted: Bool
    ) -> PasteAction {
        let payload: PastePayload?
        switch item.kind {
        case .text:
            guard let text = item.textContent, !text.isEmpty else { return .nothing }
            payload = .text(text)
        case .image:
            // Plain-text toggle does not convert images — still paste image.
            guard let data = imageData, !data.isEmpty else { return .nothing }
            payload = .image(data)
        }

        guard let payload else { return .nothing }

        // plainTextMode only affects text richness; v1 text is already plain.
        // Kept for API clarity / future rich text.
        _ = plainTextMode

        if accessibilityTrusted {
            return .writeAndAutoPaste(payload)
        }
        return .writeClipboardOnly(payload)
    }

    public static func requiresAccessibilityKeystroke(_ action: PasteAction) -> Bool {
        if case .writeAndAutoPaste = action { return true }
        return false
    }
}
