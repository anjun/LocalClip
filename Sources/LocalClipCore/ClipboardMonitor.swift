import AppKit
import Foundation

public protocol ClipboardMonitoring: AnyObject {
    func start()
    func stop()
}

/// Polls pasteboard changeCount; extracts on background; feeds store.
public final class ClipboardMonitor: ClipboardMonitoring, @unchecked Sendable {
    private let store: ClipboardStore
    private let pasteboard: SystemPasteboard
    private let selfWriteGuard: SelfWriteGuard
    private let frontmostTracker: FrontmostAppTracker
    private let pollInterval: TimeInterval
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.localclip.monitor", qos: .utility)
    private var lastChangeCount: Int = -1
    public var onItemsChanged: (() -> Void)?
    public private(set) var isRunning: Bool = false

    public init(
        store: ClipboardStore,
        pasteboard: SystemPasteboard = SystemPasteboard(),
        selfWriteGuard: SelfWriteGuard,
        frontmostTracker: FrontmostAppTracker = FrontmostAppTracker(),
        pollInterval: TimeInterval = 0.4
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.selfWriteGuard = selfWriteGuard
        self.frontmostTracker = frontmostTracker
        self.pollInterval = pollInterval
    }

    public func start() {
        stop()
        lastChangeCount = pasteboard.changeCount
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Fire soon so we track frontmost even before first pasteboard change.
        timer.schedule(deadline: .now() + 0.05, repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
        isRunning = true
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        isRunning = false
    }

    private func tick() {
        // Always track external frontmost app for paste targeting.
        frontmostTracker.observeFrontmost()

        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        if selfWriteGuard.shouldIgnore(changeCount: count) {
            return
        }

        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let capture = pasteboard.readCapture(sourceBundleId: source)
        guard capture.hasText || capture.hasImage else { return }

        do {
            let inserted = try store.ingest(capture)
            if !inserted.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.onItemsChanged?()
                }
            }
        } catch {
            NSLog("LocalClip monitor ingest error: \(error)")
        }
    }
}
