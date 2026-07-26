import AppKit
import Foundation

/// Remembers the last frontmost app that is not LocalClip, for paste targeting.
public final class FrontmostAppTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var previousExternal: NSRunningApplication?
    private let selfPID: pid_t
    private let selfBundleId: String?

    public init(
        selfPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        selfBundleId: String? = Bundle.main.bundleIdentifier
    ) {
        self.selfPID = selfPID
        self.selfBundleId = selfBundleId
    }

    /// Call frequently (e.g. monitor tick) so we know who the user was last in.
    public func observeFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        guard !isSelf(app) else { return }
        lock.lock()
        previousExternal = app
        lock.unlock()
    }

    public var previousExternalApp: NSRunningApplication? {
        lock.lock()
        defer { lock.unlock() }
        return previousExternal
    }

    private func isSelf(_ app: NSRunningApplication) -> Bool {
        if app.processIdentifier == selfPID { return true }
        if let bid = selfBundleId, app.bundleIdentifier == bid { return true }
        return false
    }
}

/// Pure sequence describing auto-paste focus handling (unit-tested).
public enum AutoPasteOrchestration {
    public enum Step: String, Equatable, Sendable {
        case writePasteboard
        case dismissHostUI
        case activatePreviousApp
        case delay
        case keystroke
    }

    /// When Accessibility is trusted we must leave LocalClip before ⌘V.
    public static func steps(accessibilityTrusted: Bool) -> [Step] {
        if accessibilityTrusted {
            return [
                .writePasteboard,
                .dismissHostUI,
                .activatePreviousApp,
                .delay,
                .keystroke
            ]
        }
        return [.writePasteboard]
    }
}

public enum HostUIDismisser {
    /// Soft-dismiss LocalClip UI so ⌘V targets the previous app.
    /// Avoid `NSApp.hide` — on accessory/menu-bar apps it can look like a crash and
    /// races badly with NSPopover teardown.
    public static func dismissLocalClipWindows() {
        for window in NSApp.windows where window.isVisible {
            window.orderOut(nil)
        }
    }
}

/// Optional hook so Core can close AppKit popover without importing app target.
public enum AppDelegateClosePopover {
    public static var shared: (() -> Void)?
}
