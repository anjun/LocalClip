import Foundation

/// Key routing while the history search field is focused.
/// ↑/↓/Return always drive the list; other keys stay in the search field.
public enum HistoryPanelKeyRouting: Sendable {
    public enum Decision: Equatable, Sendable {
        case moveSelection(delta: Int)
        case pasteSelected
        case typeInSearch
    }

    /// keyCode: 125 ↓, 126 ↑, 36 return, 76 keypad enter
    public static func decision(keyCode: UInt16) -> Decision {
        switch keyCode {
        case 125:
            return .moveSelection(delta: 1)
        case 126:
            return .moveSelection(delta: -1)
        case 36, 76:
            return .pasteSelected
        default:
            return .typeInSearch
        }
    }
}
