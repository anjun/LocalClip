import Foundation

public struct AppSettings: Equatable, Sendable {
    public static let retentionMaxItemOptions = [50, 100, 200, 500, 1000]
    public static let retentionMaxAgeDayOptions = [1, 3, 7, 14, 30, 0]

    public var pollIntervalMs: Int
    public var maxItems: Int
    public var maxAgeDays: Int
    public var plainTextPaste: Bool
    public var launchAtLogin: Bool

    public static let `default` = AppSettings(
        pollIntervalMs: 400,
        maxItems: 200,
        maxAgeDays: 7,
        plainTextPaste: false,
        launchAtLogin: true
    )

    public init(
        pollIntervalMs: Int = 400,
        maxItems: Int = 200,
        maxAgeDays: Int = 7,
        plainTextPaste: Bool = false,
        launchAtLogin: Bool = true
    ) {
        self.pollIntervalMs = pollIntervalMs
        self.maxItems = maxItems
        self.maxAgeDays = maxAgeDays
        self.plainTextPaste = plainTextPaste
        self.launchAtLogin = launchAtLogin
    }

    public var pollInterval: TimeInterval {
        Double(pollIntervalMs) / 1000.0
    }

    public static func isValidRetention(maxItems: Int, maxAgeDays: Int) -> Bool {
        (1...1_000_000).contains(maxItems) && (0...36_500).contains(maxAgeDays)
    }

    public static func isRetentionReduction(
        fromMaxItems: Int,
        fromMaxAgeDays: Int,
        toMaxItems: Int,
        toMaxAgeDays: Int
    ) -> Bool {
        if toMaxItems < fromMaxItems {
            return true
        }
        if fromMaxAgeDays == 0 {
            return toMaxAgeDays > 0
        }
        return toMaxAgeDays > 0 && toMaxAgeDays < fromMaxAgeDays
    }
}

/// Clock injection for retention tests.
public protocol Clock: Sendable {
    func now() -> Date
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}

public final class FixedClock: Clock, @unchecked Sendable {
    public var date: Date
    public init(_ date: Date) { self.date = date }
    public func now() -> Date { date }
}
