import AppKit

/// Chooses the keyboard first responder when the history panel opens.
/// Unit-tested: the search field wins over the SwiftUI hosting view.
public enum PanelOpenFocus: Sendable {
    /// First visible, enabled, editable text field in `root`, or nil.
    public static func preferredFirstResponder(in root: NSView?) -> NSView? {
        guard let root else { return nil }
        return firstEditableTextField(in: root)
    }

    /// Walk depth-first so a nested SwiftUI `TextField` is found after `show()`.
    public static func firstEditableTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField,
           field.isEditable,
           field.isEnabled,
           !field.isHidden {
            return field
        }
        for subview in view.subviews {
            if let found = firstEditableTextField(in: subview) {
                return found
            }
        }
        return nil
    }

    /// Make the search field first responder. Returns false if it is not in the tree yet.
    @discardableResult
    @MainActor
    public static func makeSearchFieldFirstResponder(in window: NSWindow?, root: NSView?) -> Bool {
        guard let window, let field = preferredFirstResponder(in: root) else {
            return false
        }
        return window.makeFirstResponder(field)
    }
}
