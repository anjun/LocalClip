import Foundation

/// Suppresses re-capture of pasteboard changes we caused by writing history back.
public final class SelfWriteGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var ignoreUntil: Date?
    private var ignoreChangeCounts: Set<Int> = []

    public init() {}

    /// Call immediately before writing to the pasteboard for paste.
    public func beginSelfWrite(expectedChangeCountAfter: Int? = nil, duration: TimeInterval = 1.0) {
        lock.lock()
        defer { lock.unlock() }
        ignoreUntil = Date().addingTimeInterval(duration)
        if let c = expectedChangeCountAfter {
            ignoreChangeCounts.insert(c)
        }
    }

    public func noteChangeCountToIgnore(_ changeCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        ignoreChangeCounts.insert(changeCount)
        if ignoreUntil == nil {
            ignoreUntil = Date().addingTimeInterval(1.0)
        }
    }

    /// Returns true if this changeCount (or the current window) should not be captured.
    public func shouldIgnore(changeCount: Int, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if ignoreChangeCounts.contains(changeCount) {
            ignoreChangeCounts.remove(changeCount)
            return true
        }
        if let until = ignoreUntil, now < until {
            return true
        }
        if let until = ignoreUntil, now >= until {
            ignoreUntil = nil
            ignoreChangeCounts.removeAll()
        }
        return false
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        ignoreUntil = nil
        ignoreChangeCounts.removeAll()
    }
}
