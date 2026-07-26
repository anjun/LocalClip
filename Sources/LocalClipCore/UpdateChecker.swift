import Foundation

/// Optional GitHub Releases update check.
/// Only network path in LocalClip: user-initiated (or explicit auto-check),
/// hits `api.github.com` for the latest release only — no telemetry.
public enum UpdateChecker {
    public struct CheckResult: Equatable, Sendable {
        public let currentVersion: String
        public let latestVersion: String
        public let releaseURL: URL?
        public let isUpdateAvailable: Bool
        public let releaseNotes: String?

        public init(
            currentVersion: String,
            latestVersion: String,
            releaseURL: URL?,
            isUpdateAvailable: Bool,
            releaseNotes: String? = nil
        ) {
            self.currentVersion = currentVersion
            self.latestVersion = latestVersion
            self.releaseURL = releaseURL
            self.isUpdateAvailable = isUpdateAvailable
            self.releaseNotes = releaseNotes
        }
    }

    public enum CheckError: Error, Equatable {
        case badURL
        case httpStatus(Int)
        case decodeFailed
        case emptyTag
    }

    /// Compare dotted versions: `1.2.0` vs `1.10.3`. Missing segments treated as 0.
    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = parseVersion(lhs)
        let b = parseVersion(rhs)
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
        }
        return .orderedSame
    }

    /// Strip leading `v`/`V` from tags like `v1.0.0`.
    public static func normalizeTag(_ tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("v"), t.count > 1 {
            t = String(t.dropFirst())
        }
        return t
    }

    public static func parseVersion(_ raw: String) -> [Int] {
        let cleaned = normalizeTag(raw)
            .split(separator: "-").first
            .map(String.init) ?? normalizeTag(raw)
        return cleaned.split(separator: ".").map { part in
            Int(part.filter(\.isNumber)) ?? 0
        }
    }

    /// Fetch latest GitHub release and compare to `currentVersion`.
    public static func check(
        currentVersion: String = AppIdentity.currentVersion(),
        apiURL: URL = AppIdentity.latestReleaseAPIURL,
        session: URLSession = .shared
    ) async throws -> CheckResult {
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("LocalClip-UpdateCheck", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CheckError.httpStatus(http.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CheckError.decodeFailed
        }
        guard let tag = json["tag_name"] as? String, !tag.isEmpty else {
            throw CheckError.emptyTag
        }
        let latest = normalizeTag(tag)
        let html = (json["html_url"] as? String).flatMap(URL.init(string:))
        let body = json["body"] as? String
        let available = compareVersions(currentVersion, latest) == .orderedAscending

        return CheckResult(
            currentVersion: normalizeTag(currentVersion),
            latestVersion: latest,
            releaseURL: html ?? AppIdentity.releasesURL,
            isUpdateAvailable: available,
            releaseNotes: body
        )
    }
}
