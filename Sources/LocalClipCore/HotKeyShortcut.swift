import Foundation

public struct HotKeyModifiers: OptionSet, Codable, Equatable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let control = HotKeyModifiers(rawValue: 1 << 0)
    public static let option = HotKeyModifiers(rawValue: 1 << 1)
    public static let shift = HotKeyModifiers(rawValue: 1 << 2)
    public static let command = HotKeyModifiers(rawValue: 1 << 3)

    public static let supported: HotKeyModifiers = [.control, .option, .shift, .command]
}

public enum ShortcutValidationError: String, Error, Equatable, Sendable {
    case missingModifier
    case unsupportedModifiers
    case unsupportedKey
}

public struct HotKeyShortcut: Codable, Equatable, Hashable, Sendable {
    public let keyCode: UInt32
    public let modifiers: HotKeyModifiers

    public init(keyCode: UInt32, modifiers: HotKeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let historyDefault = HotKeyShortcut(keyCode: 8, modifiers: .option)
    public static let screenshotDefault = HotKeyShortcut(keyCode: 0, modifiers: .option)

    public var validationError: ShortcutValidationError? {
        guard !modifiers.isEmpty else { return .missingModifier }
        guard modifiers.subtracting(.supported).isEmpty else { return .unsupportedModifiers }
        guard keyLabel != nil else { return .unsupportedKey }
        return nil
    }

    public var displayLabel: String {
        var label = ""
        if modifiers.contains(.control) { label += "⌃" }
        if modifiers.contains(.option) { label += "⌥" }
        if modifiers.contains(.shift) { label += "⇧" }
        if modifiers.contains(.command) { label += "⌘" }
        label += keyLabel ?? "?"
        return label
    }

    private var keyLabel: String? {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 10: return "§"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 36: return "↩"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 48: return "⇥"
        case 49: return "Space"
        case 50: return "`"
        case 51: return "⌫"
        case 53: return "⎋"
        case 64: return "F17"
        case 65: return "Num ."
        case 67: return "Num *"
        case 69: return "Num +"
        case 71: return "Num Clear"
        case 75: return "Num /"
        case 76: return "Num ↩"
        case 78: return "Num -"
        case 79: return "F18"
        case 80: return "F19"
        case 81: return "Num ="
        case 82: return "Num 0"
        case 83: return "Num 1"
        case 84: return "Num 2"
        case 85: return "Num 3"
        case 86: return "Num 4"
        case 87: return "Num 5"
        case 88: return "Num 6"
        case 89: return "Num 7"
        case 90: return "F20"
        case 91: return "Num 8"
        case 92: return "Num 9"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 106: return "F16"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 113: return "F15"
        case 114: return "Help"
        case 115: return "Home"
        case 116: return "Page Up"
        case 117: return "⌦"
        case 118: return "F4"
        case 119: return "End"
        case 120: return "F2"
        case 121: return "Page Down"
        case 122: return "F1"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return nil
        }
    }
}
