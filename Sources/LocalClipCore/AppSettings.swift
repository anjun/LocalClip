import Foundation

public struct AppSettings: Equatable, Sendable {
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
