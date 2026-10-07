import Foundation

public enum PastePayload: Equatable, Sendable {
    case text(String)
    case richText(String, RichTextContent)
    case image(Data)
}

public enum PasteAction: Equatable, Sendable {
    /// Write pasteboard and attempt ⌘V
    case writeAndAutoPaste(PastePayload)
    /// Write pasteboard only
    case writeClipboardOnly(PastePayload)
    case nothing
}

/// Pure decision logic for paste — tested without Accessibility session.
public enum PastePolicy {
    /// - Parameter attemptAutoPaste: when true, always prefer auto-paste path (default for LocalClip).
    ///   Ad-hoc apps often get `AXIsProcessTrusted == false` even when enabled in Settings.
    public static func resolve(
        item: ClipboardItem,
        imageData: Data?,
        plainTextMode: Bool,
        accessibilityTrusted: Bool,
        attemptAutoPaste: Bool = true
    ) -> PasteAction {
        let payload: PastePayload?
        switch item.kind {
        case .text:
            guard let text = item.textContent, !text.isEmpty else { return .nothing }
            payload = plainTextMode || item.richText.isEmpty
                ? .text(text)
                : .richText(text, item.richText)
        case .image:
            // Plain-text toggle does not convert images — still paste image.
            guard let data = imageData, !data.isEmpty else { return .nothing }
            payload = .image(data)
        }

        guard let payload else { return .nothing }

        // Prefer auto-paste whenever attemptAutoPaste is true; trust flag only informs UI.
        if attemptAutoPaste || accessibilityTrusted {
            return .writeAndAutoPaste(payload)
        }
        return .writeClipboardOnly(payload)
    }

    public static func requiresAccessibilityKeystroke(_ action: PasteAction) -> Bool {
        if case .writeAndAutoPaste = action { return true }
        return false
    }
}
