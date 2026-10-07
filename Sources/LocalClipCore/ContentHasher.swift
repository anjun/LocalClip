import Foundation
import CryptoKit

public enum ContentHasher {
    public static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(ofText text: String, richText: RichTextContent = RichTextContent()) -> String {
        let textData = Data(text.utf8)
        // Keep existing plain-text hashes stable for histories created before rich text support.
        guard !richText.isEmpty else { return sha256Hex(of: textData) }

        var hasher = SHA256()
        hasher.update(data: Data("LocalClip.richText.v1".utf8))
        // Fixed field order plus explicit byte lengths prevents ambiguous concatenations.
        for data in [textData, richText.rtf ?? Data(), richText.rtfd ?? Data(), richText.html ?? Data()] {
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { bytes in
                hasher.update(data: Data(bytes))
            }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
