import AppKit
import CoreGraphics
import Foundation

public final class MacOSScreenshotSystem: ScreenshotSystem, @unchecked Sendable {
    public init() {}

    public static func captureArguments(to outputURL: URL) -> [String] {
        // No `-x`: preserve the native capture sound. Interactive selection does not
        // include the cursor, so `-C` is intentionally absent as well.
        ["-i", "-s", "-t", "png", outputURL.path]
    }

    public func preflightAccess() -> Bool {
        if let probed = Self.probeForeignWindowCapture() {
            return probed
        }
        return CGPreflightScreenCaptureAccess()
    }

    /// `true`/`false` when another app window can be tested; `nil` if none are on screen.
    /// Prefer this over `CGPreflightScreenCaptureAccess()`, which lies for ad-hoc apps
    /// on macOS 15 and does not tell us whether other windows are actually captured.
    public static func probeForeignWindowCapture() -> Bool? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var sawCandidate = false
        for entry in info {
            guard let rawID = entry[kCGWindowNumber as String] else { continue }
            let windowID = CGWindowID((rawID as? NSNumber)?.uint32Value ?? 0)
            guard windowID != 0 else { continue }
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }
            let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            guard ownerPID != 0, ownerPID != selfPID else { continue }
            let bounds = entry[kCGWindowBounds as String] as? [String: Any]
            let width = (bounds?["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds?["Height"] as? NSNumber)?.doubleValue ?? 0
            guard width >= 64, height >= 64 else { continue }

            sawCandidate = true
            let image = CGWindowListCreateImage(
                .null,
                [.optionIncludingWindow],
                windowID,
                [.boundsIgnoreFraming, .bestResolution]
            )
            if isUsableWindowCapture(image) {
                return true
            }
        }
        return sawCandidate ? false : nil
    }

    public static func isUsableWindowCapture(_ image: CGImage?) -> Bool {
        guard let image else { return false }
        return image.width >= 16 && image.height >= 16
    }

    public func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public func captureRegion(to outputURL: URL) async throws -> ScreenshotProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = Self.captureArguments(to: outputURL)
            process.standardError = errorPipe
            process.terminationHandler = { process in
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorText = String(data: errorData, encoding: .utf8) ?? ""
                continuation.resume(returning: ScreenshotProcessResult(
                    terminationStatus: process.terminationStatus,
                    standardError: errorText
                ))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    public func openSystemSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
