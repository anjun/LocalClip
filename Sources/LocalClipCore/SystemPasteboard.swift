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
    /// Prefer true if either API reports trusted (some macOS builds disagree).
    public static func isTrusted(prompt: Bool = false) -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        let opts = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Simulate ⌘V using CGEvent (requires Accessibility trust for reliable delivery).
    public static func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyV: CGKeyCode = 9 // kVK_ANSI_V
        let flag = CGEventFlags.maskCommand

        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true) {
            down.flags = flag
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false) {
            up.flags = flag
            up.post(tap: .cghidEventTap)
        }
    }

    public static func openSystemSettings() {
        // Ventura+ deep link
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

    /// Relaunch this .app after a short delay (so TCC re-evaluates trust).
    public static func relaunchCurrentApp() {
        let appPath = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Escape single quotes in path
        let escaped = appPath.replacingOccurrences(of: "'", with: "'\\''")
        process.arguments = ["-c", "sleep 0.6; /usr/bin/open '\(escaped)'"]
        try? process.run()
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }
}
