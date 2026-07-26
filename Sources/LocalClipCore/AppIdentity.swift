import Foundation

/// Bundle identity + GitHub release coordinates (for update checks).
public enum AppIdentity {
    public static let githubOwner = "anjun"
    public static let githubRepo = "LocalClip"

    public static var githubURL: URL {
        URL(string: "https://github.com/\(githubOwner)/\(githubRepo)")!
    }

    public static var releasesURL: URL {
        URL(string: "https://github.com/\(githubOwner)/\(githubRepo)/releases")!
    }

    public static var latestReleaseAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases/latest")!
    }

    /// Marketing version from the running app, or fallback for tests/CLI.
    public static func currentVersion(
        bundle: Bundle = .main,
        fallback: String = "1.0.0"
    ) -> String {
        if let v = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !v.isEmpty {
            return v
        }
        return fallback
    }

    public static func currentBuild(
        bundle: Bundle = .main,
        fallback: String = "1"
    ) -> String {
        if let v = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           !v.isEmpty {
            return v
        }
        return fallback
    }
}
