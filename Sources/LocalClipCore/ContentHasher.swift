import Foundation
import CryptoKit

public enum ContentHasher {
    public static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(ofText text: String) -> String {
        let normalized = text
        guard let data = normalized.data(using: .utf8) else {
            return sha256Hex(of: Data())
        }
        return sha256Hex(of: data)
    }
}
