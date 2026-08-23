import Foundation

public enum HotKeyAction: UInt32, CaseIterable, Hashable, Sendable {
    case historyPanel = 1
    case regionScreenshot = 2
}

public enum HotKeyRegistrationError: Error, Equatable, Sendable {
    case invalidShortcut(ShortcutValidationError)
    case conflict
    case system(code: Int32)
}

extension HotKeyRegistrationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidShortcut(.missingModifier):
            return "快捷键至少需要一个修饰键"
        case .invalidShortcut(.unsupportedModifiers):
            return "快捷键包含不支持的修饰键"
        case .invalidShortcut(.unsupportedKey):
            return "请选择字母、数字、方向键或功能键"
        case .conflict:
            return "快捷键已被其他功能或应用占用"
        case .system(let code):
            return "系统注册快捷键失败（\(code)）"
        }
    }
}

public final class HotKeyRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?

    public init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    public func cancel() {
        let work: (() -> Void)?
        lock.lock()
        work = cancellation
        cancellation = nil
        lock.unlock()
        work?()
    }

    deinit {
        cancel()
    }
}

public protocol HotKeyRegistering: AnyObject {
    func register(
        shortcut: HotKeyShortcut,
        handler: @escaping () -> Void
    ) -> Result<HotKeyRegistration, HotKeyRegistrationError>
}

/// Owns application hotkey actions and replaces each binding transactionally.
/// A candidate registration is acquired before the previous registration is released.
public final class HotKeyManager: @unchecked Sendable {
    public static let shared = HotKeyManager(registrar: CarbonHotKeyRegistrar())

    private struct ActiveBinding {
        let shortcut: HotKeyShortcut
        let registration: HotKeyRegistration
    }

    private let registrar: HotKeyRegistering
    private let lock = NSLock()
    private var handlers: [HotKeyAction: () -> Void] = [:]
    private var active: [HotKeyAction: ActiveBinding] = [:]

    public init(registrar: HotKeyRegistering) {
        self.registrar = registrar
    }

    public func setHandler(for action: HotKeyAction, handler: @escaping () -> Void) {
        lock.lock()
        handlers[action] = handler
        lock.unlock()
    }

    @discardableResult
    public func activate(
        _ action: HotKeyAction,
        shortcut: HotKeyShortcut
    ) -> Result<Void, HotKeyRegistrationError> {
        if let validationError = shortcut.validationError {
            return .failure(.invalidShortcut(validationError))
        }

        lock.lock()
        if active[action]?.shortcut == shortcut {
            lock.unlock()
            return .success(())
        }
        if active.contains(where: { $0.key != action && $0.value.shortcut == shortcut }) {
            lock.unlock()
            return .failure(.conflict)
        }

        let candidate = registrar.register(shortcut: shortcut) { [weak self] in
            self?.dispatch(action)
        }
        switch candidate {
        case .failure(let error):
            lock.unlock()
            return .failure(error)
        case .success(let registration):
            let previous = active.updateValue(
                ActiveBinding(shortcut: shortcut, registration: registration),
                forKey: action
            )
            lock.unlock()
            previous?.registration.cancel()
            return .success(())
        }
    }

    public func deactivate(_ action: HotKeyAction) {
        lock.lock()
        let previous = active.removeValue(forKey: action)
        lock.unlock()
        previous?.registration.cancel()
    }

    public func deactivateAll() {
        lock.lock()
        let registrations = active.values.map(\.registration)
        active.removeAll()
        lock.unlock()
        registrations.forEach { $0.cancel() }
    }

    public func activeShortcut(for action: HotKeyAction) -> HotKeyShortcut? {
        lock.lock()
        defer { lock.unlock() }
        return active[action]?.shortcut
    }

    private func dispatch(_ action: HotKeyAction) {
        lock.lock()
        let handler = handlers[action]
        lock.unlock()
        handler?()
    }
}
