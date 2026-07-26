import Foundation

/// Pure helpers for dual-capture row planning (tested without SQLite).
public enum CaptureOrdering {
    public struct PlannedRow: Equatable {
        public let kind: ClipboardItemKind
        public let createdAtOffset: TimeInterval
    }

    /// Returns planned kinds for a capture: image first, then text when both present.
    public static func plannedRows(for capture: ClipboardCapture) -> [PlannedRow] {
        var rows: [PlannedRow] = []
        // Image gets +0.001 so newest-first list shows image above text for dual captures.
        if capture.hasImage {
            rows.append(PlannedRow(kind: .image, createdAtOffset: capture.hasText ? 0.001 : 0))
        }
        if capture.hasText {
            rows.append(PlannedRow(kind: .text, createdAtOffset: 0))
        }
        return rows
    }
}
