import Carbon
import Foundation

/// System-wide hotkey via Carbon `RegisterEventHotKey` (consumes the key so it
/// does not type into the frontmost app). Fixed v1 binding: ⌥C.
public final class GlobalHotKey: @unchecked Sendable {
    public static let shared = GlobalHotKey()

    /// FourCharCode 'LCHK'
    private static let hotKeySignature: UInt32 = 0x4C43484B
    private static let hotKeyNumericID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var registered = false

    /// Invoked on the main queue when the hotkey is pressed.
    public var onPressed: (() -> Void)?

    private init() {}

    /// Register ⌥C. Safe to call repeatedly; re-registers if needed.
    @discardableResult
    public func registerOptionC() -> Bool {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else {
                    return OSStatus(eventNotHandledErr)
                }
                let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                var hkID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                guard err == noErr,
                      hkID.signature == GlobalHotKey.hotKeySignature,
                      hkID.id == GlobalHotKey.hotKeyNumericID
                else {
                    return OSStatus(eventNotHandledErr)
                }
                DispatchQueue.main.async {
                    owner.onPressed?()
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &handlerRef
        )

        guard installStatus == noErr else {
            NSLog("LocalClip hotkey: InstallEventHandler failed \(installStatus)")
            return false
        }

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyNumericID)
        // kVK_ANSI_C = 0x08; optionKey = Carbon modifier
        let regStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_C),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard regStatus == noErr else {
            NSLog("LocalClip hotkey: RegisterEventHotKey failed \(regStatus)")
            if let handlerRef {
                RemoveEventHandler(handlerRef)
                self.handlerRef = nil
            }
            return false
        }

        registered = true
        return true
    }

    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        registered = false
    }

    public var isRegistered: Bool { registered }

    /// Human-readable label for UI.
    public static let displayLabel = "⌥C"
}
