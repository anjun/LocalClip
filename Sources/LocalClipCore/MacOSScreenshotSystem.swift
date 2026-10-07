import AppKit
import CoreGraphics
import Foundation
import ImageIO

public final class MacOSScreenshotSystem: ScreenshotSystem, @unchecked Sendable {
    private var captureSound: NSSound?
    public init() {}

    public static func captureArguments(for frame: CGRect, to outputURL: URL) -> [String] {
        let bounds = frame.integral
        let rectangle = "\(Int(bounds.minX)),\(Int(bounds.minY)),\(Int(bounds.width)),\(Int(bounds.height))"
        // Freeze each screen silently, without the cursor or selection overlay.
        return ["-x", "-R", rectangle, "-t", "png", outputURL.path]
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
        // LSUIElement / accessory apps often never surface the TCC prompt
        // unless they briefly become a regular, active app.
        let app = NSApplication.shared
        let previous = app.activationPolicy()
        if previous != .regular {
            app.setActivationPolicy(.regular)
        }
        app.activate(ignoringOtherApps: true)
        let granted = CGRequestScreenCaptureAccess()
        if previous != .regular {
            app.setActivationPolicy(previous)
        }
        return granted
    }

    public func captureRegion(to outputURL: URL) async throws -> ScreenshotProcessResult {
        try await captureWithAdjustableSelection(to: outputURL)
    }

    @MainActor
    private func captureWithAdjustableSelection(to outputURL: URL) async throws -> ScreenshotProcessResult {
        let screens = NSScreen.screens.compactMap { screen -> DisplayDescriptor? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let frame = CGDisplayBounds(number.uint32Value)
            guard !frame.isEmpty else { return nil }
            return DisplayDescriptor(frame: frame, screenFrame: screen.frame)
        }
        guard !screens.isEmpty else { throw SelectionError(message: "没有可截图的屏幕") }
        // Enumerate before our own windows are shown, preserving front-to-back order.
        let candidates = Self.visibleWindowCandidates()
        let snapshots = try await Task.detached(priority: .userInitiated) {
            try screens.map { screen in
                try Task.checkCancellation()
                return try Self.freeze(screen)
            }
        }.value
        try Task.checkCancellation()
        let selector = ScreenshotSelectionController(snapshots: snapshots, windows: candidates)
        guard let region = await selector.select() else {
            return ScreenshotProcessResult(terminationStatus: 0, standardError: "")
        }
        try await Task.detached(priority: .userInitiated) {
            guard let data = ScreenshotSnapshotRenderer.pngData(for: region, snapshots: snapshots) else {
                throw SelectionError(message: "无法生成选区图片")
            }
            try data.write(to: outputURL, options: .atomic)
        }.value
        captureSound = NSSound(contentsOf: URL(fileURLWithPath:
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif"
        ), byReference: true)
        captureSound?.play()
        return ScreenshotProcessResult(terminationStatus: 0, standardError: "")
    }

    private struct DisplayDescriptor: Sendable {
        let frame: CGRect
        let screenFrame: CGRect
    }

    private struct SelectionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func visibleWindowCandidates() -> [ScreenshotWindowCandidate] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? NSNumber,
                  let owner = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  owner.int32Value > 0,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= 16, frame.height >= 16 else { return nil }
            return ScreenshotWindowCandidate(id: id.uint32Value, frame: frame)
        }
    }

    private static func freeze(_ screen: DisplayDescriptor) throws -> ScreenshotDisplaySnapshot {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalClip-Display-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = captureArguments(for: screen.frame, to: file)
        process.standardError = errorPipe
        try process.run()
        // This worker runs off the main actor; the selection UI remains responsive.
        process.waitUntilExit()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw SelectionError(message: detail.isEmpty ? "无法读取屏幕内容" : detail)
        }
        return ScreenshotDisplaySnapshot(frame: screen.frame, screenFrame: screen.screenFrame, image: image)
    }

    public func openSystemSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
