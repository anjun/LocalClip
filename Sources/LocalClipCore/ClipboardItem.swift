import Foundation

public enum ClipboardItemKind: String, Sendable, Codable, Equatable {
    case text
    case image
}

public struct ClipboardItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: ClipboardItemKind
    public let createdAt: Date
    public let textContent: String?
    public let contentHash: String
    public let imagePath: String?
    public let thumbPath: String?
    public let sourceBundleId: String?
    public let byteSize: Int

    public init(
        id: String = UUID().uuidString,
        kind: ClipboardItemKind,
        createdAt: Date = Date(),
        textContent: String? = nil,
        contentHash: String,
        imagePath: String? = nil,
        thumbPath: String? = nil,
        sourceBundleId: String? = nil,
        byteSize: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.textContent = textContent
        self.contentHash = contentHash
        self.imagePath = imagePath
        self.thumbPath = thumbPath
        self.sourceBundleId = sourceBundleId
        self.byteSize = byteSize
    }
}

/// Result of extracting one pasteboard change (may yield 0–2 items to insert).
public struct ClipboardCapture: Equatable, Sendable {
    public var text: String?
    public var imageData: Data?
    public var sourceBundleId: String?

    public init(text: String? = nil, imageData: Data? = nil, sourceBundleId: String? = nil) {
        self.text = text
        self.imageData = imageData
        self.sourceBundleId = sourceBundleId
    }

    public var hasText: Bool {
        guard let t = text else { return false }
        return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var hasImage: Bool {
        guard let d = imageData else { return false }
        return !d.isEmpty
    }
}
