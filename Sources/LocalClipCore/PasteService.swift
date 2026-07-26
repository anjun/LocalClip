import Foundation

public enum PasteResult: Equatable, Sendable {
    case wroteAndAutoPasted
    case wroteClipboardOnly
    case failed
    case nothing
}

public protocol PasteboardWriting: AnyObject {
    var changeCount: Int { get }
    func writeText(_ text: String)
    func writeImageData(_ data: Data)
}

/// Test double for pasteboard.
public final class MockPasteboard: PasteboardWriting {
    public var changeCount: Int = 0
    public var lastText: String?
    public var lastImage: Data?

    public init() {}

    public func writeText(_ text: String) {
        lastText = text
        lastImage = nil
        changeCount += 1
    }

    public func writeImageData(_ data: Data) {
        lastImage = data
        lastText = nil
        changeCount += 1
    }
}

public final class PasteService: @unchecked Sendable {
    private let accessibilityChecker: () -> Bool
    private let attemptAutoPaste: () -> Bool
    private let pasteboard: PasteboardWriting
    private let keystroke: () -> Void
    private let selfWriteGuard: SelfWriteGuard

    public init(
        accessibilityChecker: @escaping () -> Bool,
        attemptAutoPaste: @escaping () -> Bool = { true },
        pasteboard: PasteboardWriting,
        keystroke: @escaping () -> Void,
        selfWriteGuard: SelfWriteGuard
    ) {
        self.accessibilityChecker = accessibilityChecker
        self.attemptAutoPaste = attemptAutoPaste
        self.pasteboard = pasteboard
        self.keystroke = keystroke
        self.selfWriteGuard = selfWriteGuard
    }

    /// - Parameter beforeKeystroke: Runs after pasteboard write and only when auto-paste is used.
    @discardableResult
    public func paste(
        item: ClipboardItem,
        imageData: Data?,
        plainTextMode: Bool,
        beforeKeystroke: (() -> Void)? = nil
    ) -> PasteResult {
        let trusted = accessibilityChecker()
        let attempt = attemptAutoPaste()
        let action = PastePolicy.resolve(
            item: item,
            imageData: imageData,
            plainTextMode: plainTextMode,
            accessibilityTrusted: trusted,
            attemptAutoPaste: attempt
        )

        let expected = AutoPasteOrchestration.steps(accessibilityTrusted: attempt || trusted)
        precondition(!expected.isEmpty)

        switch action {
        case .nothing:
            return .nothing
        case .writeAndAutoPaste(let payload), .writeClipboardOnly(let payload):
            let nextCount = pasteboard.changeCount + 1
            selfWriteGuard.beginSelfWrite(expectedChangeCountAfter: nextCount, duration: 1.5)

            switch payload {
            case .text(let text):
                pasteboard.writeText(text)
            case .image(let data):
                pasteboard.writeImageData(data)
            }
            selfWriteGuard.noteChangeCountToIgnore(pasteboard.changeCount)

            if case .writeAndAutoPaste = action {
                beforeKeystroke?()
                keystroke()
                return .wroteAndAutoPasted
            }
            return .wroteClipboardOnly
        }
    }
}
