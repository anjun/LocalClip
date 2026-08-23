import Carbon
import Foundation

public final class CarbonHotKeyRegistrar: HotKeyRegistering, @unchecked Sendable {
    /// FourCharCode `LCHK`.
    private static let signature: UInt32 = 0x4C43484B

    private final class CallbackBox {
        let numericID: UInt32
        private let lock = NSLock()
        private var handler: (() -> Void)?

        init(numericID: UInt32, handler: @escaping () -> Void) {
            self.numericID = numericID
            self.handler = handler
        }

        func invoke() {
            lock.lock()
            let work = handler
            lock.unlock()
            work?()
        }

        func invalidate() {
            lock.lock()
            handler = nil
            lock.unlock()
        }
    }

    private let lock = NSLock()
    private var nextNumericID: UInt32 = 1

    public init() {}

    public func register(
        shortcut: HotKeyShortcut,
        handler: @escaping () -> Void
    ) -> Result<HotKeyRegistration, HotKeyRegistrationError> {
        guard let carbonModifiers = Self.carbonModifiers(for: shortcut.modifiers) else {
            return .failure(.invalidShortcut(.unsupportedModifiers))
        }

        lock.lock()
        let numericID = nextNumericID
        nextNumericID = nextNumericID == UInt32.max ? 1 : nextNumericID + 1
        lock.unlock()

        let box = CallbackBox(numericID: numericID, handler: handler)
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var eventHandlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let readStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard readStatus == noErr,
                      hotKeyID.signature == CarbonHotKeyRegistrar.signature,
                      hotKeyID.id == box.numericID
                else {
                    return OSStatus(eventNotHandledErr)
                }
                DispatchQueue.main.async {
                    box.invoke()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(box).toOpaque(),
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            return .failure(.system(code: installStatus))
        }

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: numericID)
        let registrationStatus = RegisterEventHotKey(
            shortcut.keyCode,
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registrationStatus == noErr else {
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
            }
            if registrationStatus == OSStatus(eventHotKeyExistsErr) {
                return .failure(.conflict)
            }
            return .failure(.system(code: registrationStatus))
        }

        return .success(HotKeyRegistration {
            box.invalidate()
            if let hotKeyRef {
                UnregisterEventHotKey(hotKeyRef)
            }
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
            }
        })
    }

    private static func carbonModifiers(for modifiers: HotKeyModifiers) -> UInt32? {
        guard modifiers.subtracting(.supported).isEmpty else { return nil }
        var result: UInt32 = 0
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }
}
