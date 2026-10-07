import Foundation

public enum ClipboardItemKind: String, Sendable, Codable, Equatable {
    case text
    case image
}

/// Original, interoperable text representations. Keep bytes unchanged so the
/// receiving app can choose the format it supports without a lossy conversion.
public struct RichTextContent: Equatable, Sendable {
    public let rtf: Data?
    public let rtfd: Data?
    public let html: Data?

    public init(rtf: Data? = nil, rtfd: Data? = nil, html: Data? = nil) {
        self.rtf = rtf.flatMap { $0.isEmpty ? nil : $0 }
        self.rtfd = rtfd.flatMap { $0.isEmpty ? nil : $0 }
        self.html = html.flatMap { $0.isEmpty ? nil : $0 }
    }

    public var isEmpty: Bool {
        rtf == nil && rtfd == nil && html == nil
    }

    public var byteSize: Int {
        (rtf?.count ?? 0) + (rtfd?.count ?? 0) + (html?.count ?? 0)
    }
}

public struct ClipboardItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: ClipboardItemKind
    public let createdAt: Date
    public let textContent: String?
    public let richText: RichTextContent
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
        richText: RichTextContent = RichTextContent(),
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
        self.richText = richText
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
    public var richText: RichTextContent
    public var imageData: Data?
    public var sourceBundleId: String?

    public init(
        text: String? = nil,
        richText: RichTextContent = RichTextContent(),
        imageData: Data? = nil,
        sourceBundleId: String? = nil
    ) {
        self.text = text
        self.richText = richText
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
