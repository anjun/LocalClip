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
        CGPreflightScreenCaptureAccess()
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
