import Foundation

/// GitHub Releases update check + in-app download/install.
/// Network is user-initiated only (check / install) — no telemetry.
public enum UpdateChecker {
    public struct CheckResult: Equatable, Sendable {
        public let currentVersion: String
        public let latestVersion: String
        public let releaseURL: URL?
        public let isUpdateAvailable: Bool
        public let releaseNotes: String?
        /// Preferred install asset (universal zip).
        public let zipDownloadURL: URL?
        public let zipAssetName: String?

        public init(
            currentVersion: String,
            latestVersion: String,
            releaseURL: URL?,
            isUpdateAvailable: Bool,
            releaseNotes: String? = nil,
            zipDownloadURL: URL? = nil,
            zipAssetName: String? = nil
        ) {
            self.currentVersion = currentVersion
            self.latestVersion = latestVersion
            self.releaseURL = releaseURL
            self.isUpdateAvailable = isUpdateAvailable
            self.releaseNotes = releaseNotes
            self.zipDownloadURL = zipDownloadURL
            self.zipAssetName = zipAssetName
        }
    }

    public enum CheckError: Error, Equatable, LocalizedError {
        case badURL
        case httpStatus(Int)
        case decodeFailed
        case emptyTag
        case noZipAsset
        case downloadFailed
        case unzipFailed
        case appNotFoundInArchive
        case installFailed(String)

        public var errorDescription: String? {
            switch self {
            case .badURL: return "无效的更新地址"
            case .httpStatus(let c): return "服务器返回 \(c)"
            case .decodeFailed: return "无法解析 Release 信息"
            case .emptyTag: return "Release 缺少版本号"
            case .noZipAsset: return "Release 中没有 universal zip 安装包"
            case .downloadFailed: return "下载失败"
            case .unzipFailed: return "解压失败"
            case .appNotFoundInArchive: return "压缩包内未找到 LocalClip.app"
            case .installFailed(let m): return "安装失败：\(m)"
            }
        }
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

    /// Pick the best downloadable asset from GitHub release `assets` array.
    /// Prefers `*universal*macos*.zip`, then any `.zip` with LocalClip in name, then any `.zip`.
    public static func preferZipAsset(from assets: [[String: Any]]) -> (name: String, url: URL)? {
        struct Cand { let name: String; let url: URL; let score: Int }
        var cands: [Cand] = []
        for a in assets {
            guard let name = a["name"] as? String,
                  let urlStr = a["browser_download_url"] as? String,
                  let url = URL(string: urlStr)
            else { continue }
            let lower = name.lowercased()
            guard lower.hasSuffix(".zip") else { continue }
            var score = 10
            if lower.contains("universal") { score += 50 }
            if lower.contains("macos") { score += 20 }
            if lower.contains("localclip") { score += 10 }
            if lower.contains("dmg") { score -= 5 }
            cands.append(Cand(name: name, url: url, score: score))
        }
        guard let best = cands.max(by: { $0.score < $1.score }) else { return nil }
        return (best.name, best.url)
    }

    /// Prefer stable ~/Applications path for updates (TCC identity); fall back to running .app.
    public static func installDestination(
        bundle: Bundle = .main,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let apps = home
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("LocalClip.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: apps.path) {
            return apps
        }
        let running = bundle.bundleURL
        if running.pathExtension == "app" {
            return running
        }
        return apps
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

        let assets = json["assets"] as? [[String: Any]] ?? []
        let zip = preferZipAsset(from: assets)

        return CheckResult(
            currentVersion: normalizeTag(currentVersion),
            latestVersion: latest,
            releaseURL: html ?? AppIdentity.releasesURL,
            isUpdateAvailable: available,
            releaseNotes: body,
            zipDownloadURL: zip?.url,
            zipAssetName: zip?.name
        )
    }

    /// Download zip, extract LocalClip.app, schedule replace + relaunch, then caller should quit.
    /// - Returns: path to the helper script that will finish install after quit (optional logging).
    @discardableResult
    public static func downloadAndPrepareInstall(
        zipURL: URL,
        destination: URL = installDestination(),
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) async throws -> URL {
        var request = URLRequest(url: zipURL)
        request.setValue("LocalClip-UpdateInstall", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 300

        let (tempZip, response) = try await session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CheckError.httpStatus(http.statusCode)
        }

        let work = fileManager.temporaryDirectory
            .appendingPathComponent("LocalClip-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        let zipPath = work.appendingPathComponent("update.zip")
        if fileManager.fileExists(atPath: zipPath.path) {
            try fileManager.removeItem(at: zipPath)
        }
        try fileManager.moveItem(at: tempZip, to: zipPath)

        let extractDir = work.appendingPathComponent("extract", isDirectory: true)
        try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)

        // ditto handles zip and preserves attributes better than unzip for .app
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zipPath.path, extractDir.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw CheckError.unzipFailed
        }

        guard let appURL = findAppBundle(in: extractDir, fileManager: fileManager) else {
            throw CheckError.appNotFoundInArchive
        }

        // Clear quarantine on the new app before swap
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-cr", appURL.path]
        try? xattr.run()
        xattr.waitUntilExit()

        // Put install payload outside the work dir we may delete, and log for debugging.
        let payload = fileManager.temporaryDirectory
            .appendingPathComponent("LocalClip-update-payload-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: payload, withIntermediateDirectories: true)
        let stagedApp = payload.appendingPathComponent("LocalClip.app")
        if fileManager.fileExists(atPath: stagedApp.path) {
            try fileManager.removeItem(at: stagedApp)
        }
        try fileManager.copyItem(at: appURL, to: stagedApp)

        let logFile = fileManager.temporaryDirectory.appendingPathComponent("localclip-update.log")
        let scriptURL = payload.appendingPathComponent("install-and-relaunch.sh")
        let script = """
        #!/bin/bash
        exec >>\(shellEscape(logFile.path)) 2>&1
        set -x
        SRC=\(shellEscape(stagedApp.path))
        DEST=\(shellEscape(destination.path))
        DEST_DIR=$(dirname "$DEST")
        mkdir -p "$DEST_DIR"
        # Wait until no LocalClip process remains (up to ~15s)
        for i in $(seq 1 60); do
          if ! /usr/bin/pgrep -x LocalClip >/dev/null 2>&1; then
            break
          fi
          sleep 0.25
        done
        # Extra settle time for file locks
        sleep 1.0
        /usr/bin/xattr -cr "$SRC" 2>/dev/null || true
        if [[ -e "$DEST" ]]; then
          /bin/rm -rf "$DEST"
        fi
        /usr/bin/ditto "$SRC" "$DEST"
        /usr/bin/xattr -cr "$DEST" 2>/dev/null || true
        if command -v codesign >/dev/null; then
          /usr/bin/codesign --force --sign - --identifier "com.localclip.app" "$DEST/Contents/MacOS/LocalClip" 2>/dev/null || true
          /usr/bin/codesign --force --sign - --identifier "com.localclip.app" "$DEST" 2>/dev/null || true
        fi
        # Relaunch: -n forces a new instance; -a path works for .app bundles
        /usr/bin/open -n -a "$DEST" || /usr/bin/open "$DEST"
        sleep 0.5
        # Cleanup staged payload (keep log)
        /bin/rm -rf \(shellEscape(payload.path))
        /bin/rm -rf \(shellEscape(work.path))
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        // Detach so helper survives app quit (Process alone is often reaped with parent).
        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/bin/bash")
        launch.arguments = [
            "-c",
            "nohup \(shellEscape(scriptURL.path)) >/dev/null 2>&1 &"
        ]
        try launch.run()
        // Don't wait — returns immediately; script keeps running under nohup

        return scriptURL
    }

    /// Find LocalClip.app under extracted tree (may be nested one level).
    public static func findAppBundle(in root: URL, fileManager: FileManager = .default) -> URL? {
        let direct = root.appendingPathComponent("LocalClip.app")
        if fileManager.fileExists(atPath: direct.path) {
            return direct
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "LocalClip.app" {
                return url
            }
        }
        return nil
    }

    private static func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
