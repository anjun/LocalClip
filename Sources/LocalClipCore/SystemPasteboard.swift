import AppKit
import ApplicationServices
import Foundation

/// Real NSPasteboard adapter (macOS only).
public final class SystemPasteboard: PasteboardWriting {
    private let board: NSPasteboard

    public init(board: NSPasteboard = .general) {
        self.board = board
    }

    public var changeCount: Int {
        board.changeCount
    }

    public func writeText(_ text: String) {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    public func writeImageData(_ data: Data) {
        board.clearContents()
        if let image = NSImage(data: data) {
            board.writeObjects([image])
        } else {
            board.setData(data, forType: .png)
        }
    }

    public func readCapture(sourceBundleId: String?) -> ClipboardCapture {
        var text: String?
        if let s = board.string(forType: .string),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = s
        }

        var imageData: Data?
        if let data = board.data(forType: .png), !data.isEmpty {
            imageData = data
        } else if let data = board.data(forType: .tiff), !data.isEmpty {
            if let image = NSImage(data: data),
               let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                imageData = png
            } else {
                imageData = data
            }
        } else if let objs = board.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
                  let image = objs.first,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) {
            imageData = png
        }

        return ClipboardCapture(text: text, imageData: imageData, sourceBundleId: sourceBundleId)
    }
}

public enum AccessibilityPaste {
    /// API trust flag. Ad-hoc signed apps often stay `false` even when toggled ON in Settings.
    public static func isTrusted(prompt: Bool = false) -> Bool {
        if AXIsProcessTrusted() { return true }
        let opts = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) { return true }
        // Probe: can we talk to the AX system-wide element?
        return canUseAccessibilityAPI()
    }

    /// Whether a real AX query succeeds (stronger than the trust flag alone).
    public static func canUseAccessibilityAPI() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &ref
        )
        // kAXErrorSuccess = 0, kAXErrorNoValue = -25212
        return err == AXError.success || err.rawValue == -25212
    }

    /// Whether we should attempt auto-paste. Defaults to **always try**:
    /// ad-hoc apps frequently report untrusted while the user has already enabled them.
    public static func shouldAttemptAutoPaste() -> Bool {
        if isTrusted(prompt: false) { return true }
        if UserDefaults.standard.object(forKey: "LocalClip.alwaysAttemptAutoPaste") as? Bool == false {
            return false
        }
        // Default true — try keystroke even when API flag is false.
        return true
    }

    /// Post ⌘V. Prefer target PID (more reliable), then session tap, then System Events.
    public static func postCommandV(toPid pid: pid_t? = nil) {
        postCommandVViaCGEvent(toPid: pid)
        // Fallback after a beat if CGEvent was swallowed (common when trust flag is false).
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
            postCommandVViaSystemEvents()
        }
    }

    public static func postCommandVViaCGEvent(toPid pid: pid_t? = nil) {
        let source = CGEventSource(stateID: .combinedSessionState)
            ?? CGEventSource(stateID: .hidSystemState)
        let keyV: CGKeyCode = 9
        let flag = CGEventFlags.maskCommand

        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
        else { return }

        down.flags = flag
        up.flags = flag

        if let pid, pid > 0 {
            down.postToPid(pid)
            up.postToPid(pid)
        } else {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cgSessionEventTap)
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cghidEventTap)
            up.post(tap: .cgSessionEventTap)
        }
    }

    /// AppleScript → System Events (needs Accessibility for LocalClip or Automation for System Events).
    @discardableResult
    public static func postCommandVViaSystemEvents() -> Bool {
        let source = """
        tell application "System Events"
          keystroke "v" using command down
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        _ = script.executeAndReturnError(&error)
        return error == nil
    }

    public static func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]
        for s in candidates {
            if let url = URL(string: s) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    public static func relaunchCurrentApp() {
        let appPath = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let escaped = appPath.replacingOccurrences(of: "'", with: "'\\''")
        process.arguments = ["-c", "sleep 0.6; /usr/bin/open '\(escaped)'"]
        try? process.run()
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    public static func debugStatusLine() -> String {
        let t1 = AXIsProcessTrusted()
        let t2 = isTrusted(prompt: false)
        let api = canUseAccessibilityAPI()
        let bid = Bundle.main.bundleIdentifier ?? "?"
        let path = Bundle.main.bundlePath
        return "trustedAPI=\(t1) effective=\(t2) axProbe=\(api) id=\(bid) path=\(path)"
    }
}
