import Foundation

/// Pure list-selection helpers for keyboard navigation (unit-tested, no AppKit).
public enum HistoryListSelection: Sendable {
    /// Move selection by `delta` (−1 up / +1 down). Nil current starts at ends.
    public static func moveIndex(current: Int?, count: Int, delta: Int) -> Int? {
        guard count > 0 else { return nil }
        let base: Int
        if let current, current >= 0, current < count {
            base = current
        } else if delta > 0 {
            base = -1
        } else {
            base = count
        }
        let next = base + delta
        return max(0, min(count - 1, next))
    }

    /// Resolve item id for index, or nil if out of range.
    public static func itemID(at index: Int?, in ids: [String]) -> String? {
        guard let index, index >= 0, index < ids.count else { return nil }
        return ids[index]
    }

    /// Index of id in list, or nil.
    public static func index(of id: String?, in ids: [String]) -> Int? {
        guard let id else { return nil }
        return ids.firstIndex(of: id)
    }
}
