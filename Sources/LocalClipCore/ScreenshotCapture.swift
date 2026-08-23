import Foundation

public struct ScreenshotProcessResult: Equatable, Sendable {
    public let terminationStatus: Int32
    public let standardError: String

    public init(terminationStatus: Int32, standardError: String) {
        self.terminationStatus = terminationStatus
        self.standardError = standardError
    }
}

public protocol ScreenshotSystem: AnyObject {
    func preflightAccess() -> Bool
    func requestAccess() -> Bool
    func captureRegion(to outputURL: URL) async throws -> ScreenshotProcessResult
    func openSystemSettings()
}

public enum ScreenshotHistoryOutcome: Equatable, Sendable {
    case inserted
    case deduplicated
    case failed(message: String)
}

public enum ScreenshotCaptureFailure: Equatable, Sendable {
    case capture(message: String)
    case invalidImage
    case clipboardWrite
}

extension ScreenshotCaptureFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .capture(let message):
            return "截屏失败：\(message)"
        case .invalidImage:
            return "截屏失败：系统没有返回有效的 PNG 图片"
        case .clipboardWrite:
            return "截屏失败：无法写入系统剪贴板"
        }
    }
}

public enum ScreenshotCaptureOutcome: Equatable, Sendable {
    case captured(history: ScreenshotHistoryOutcome)
    case cancelled
    /// The system permission request API was called. macOS may still be
    /// presenting its native UI, or may require the user to open Settings.
    case permissionRequestAttempted
    case permissionDenied
    case ignoredAlreadyCapturing
    case failed(ScreenshotCaptureFailure)
}

@MainActor
public final class ScreenshotCapture {
    private let store: ClipboardStore
    private let pasteboard: PasteboardWriting
    private let selfWriteGuard: SelfWriteGuard
    private let system: ScreenshotSystem
    private let temporaryDirectory: URL
    private let fileManager: FileManager
    private var requestedPermissionThisRun = false

    public private(set) var isCapturing = false

    public init(
        store: ClipboardStore,
        pasteboard: PasteboardWriting,
        selfWriteGuard: SelfWriteGuard,
        system: ScreenshotSystem,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.selfWriteGuard = selfWriteGuard
        self.system = system
        self.temporaryDirectory = temporaryDirectory
        self.fileManager = fileManager
    }

    public var hasScreenCaptureAccess: Bool {
        system.preflightAccess()
    }

    public func openSystemSettings() {
        system.openSystemSettings()
    }

    public func captureRegion() async -> ScreenshotCaptureOutcome {
        guard !isCapturing else { return .ignoredAlreadyCapturing }
        isCapturing = true
        defer { isCapturing = false }

        if !system.preflightAccess() {
            guard !requestedPermissionThisRun else { return .permissionDenied }
            requestedPermissionThisRun = true
            _ = system.requestAccess()
            // CGRequestScreenCaptureAccess can return while the native TCC UI is
            // still visible. Stop this attempt regardless of the Boolean result;
            // a later hotkey press will either capture or report a real denial.
            return .permissionRequestAttempted
        }

        do {
            try fileManager.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            return .failed(.capture(message: error.localizedDescription))
        }

        let outputURL = temporaryDirectory
            .appendingPathComponent("LocalClip-Screenshot-\(UUID().uuidString).png")
        defer { try? fileManager.removeItem(at: outputURL) }

        let processResult: ScreenshotProcessResult
        do {
            processResult = try await system.captureRegion(to: outputURL)
        } catch {
            return .failed(.capture(message: error.localizedDescription))
        }

        guard fileManager.fileExists(atPath: outputURL.path) else {
            if !system.preflightAccess() {
                return .permissionDenied
            }
            let detail = processResult.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty {
                return .failed(.capture(message: detail))
            }
            return .cancelled
        }

        let imageData: Data
        do {
            imageData = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: outputURL)
            }.value
        } catch {
            return .failed(.capture(message: error.localizedDescription))
        }
        guard Self.isPNG(imageData) else { return .failed(.invalidImage) }

        let expectedChangeCount = pasteboard.changeCount + 1
        selfWriteGuard.beginSelfWrite(
            expectedChangeCountAfter: expectedChangeCount,
            duration: 0
        )
        guard pasteboard.writeImageData(imageData) else {
            selfWriteGuard.clear()
            return .failed(.clipboardWrite)
        }
        selfWriteGuard.noteChangeCountToIgnore(pasteboard.changeCount)

        let item: ClipboardItem?
        do {
            let store = self.store
            item = try await Task.detached(priority: .utility) {
                try store.insertImage(data: imageData)
            }.value
        } catch {
            return .captured(history: .failed(message: error.localizedDescription))
        }
        return .captured(history: item == nil ? .deduplicated : .inserted)
    }

    private static func isPNG(_ data: Data) -> Bool {
        data.count >= 8
            && data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }
}
