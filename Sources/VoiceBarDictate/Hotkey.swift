import AppKit
import Carbon
import SwiftUI

/// A global shortcut stored as a Carbon key code plus Carbon modifier mask.
struct Hotkey: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    /// Human-readable key name captured when the shortcut was recorded (e.g. "Space", "D", "F5").
    var keyLabel: String

    static let `default` = Hotkey(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(controlKey) | UInt32(optionKey),
        keyLabel: "Space"
    )

    /// "Control + Option + Space" style, matching the original hint text.
    var displayString: String {
        (modifierNames + [keyLabel]).joined(separator: " + ")
    }

    var modifierNames: [String] {
        var names: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { names.append("Control") }
        if carbonModifiers & UInt32(optionKey) != 0 { names.append("Option") }
        if carbonModifiers & UInt32(shiftKey) != 0 { names.append("Shift") }
        if carbonModifiers & UInt32(cmdKey) != 0 { names.append("Command") }
        return names
    }

    /// The equivalent SwiftUI shortcut, used only to display the shortcut next to the menu item.
    var menuKeyboardShortcut: KeyboardShortcut? {
        let key: KeyEquivalent
        if keyCode == UInt32(kVK_Space) {
            key = .space
        } else if keyLabel.count == 1, let character = keyLabel.lowercased().first {
            key = KeyEquivalent(character)
        } else {
            return nil
        }

        var modifiers: SwiftUI.EventModifiers = []
        if carbonModifiers & UInt32(controlKey) != 0 { modifiers.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { modifiers.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { modifiers.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { modifiers.insert(.command) }
        return KeyboardShortcut(key, modifiers: modifiers)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }
}

extension Hotkey {
    enum ValidationError: LocalizedError, Equatable {
        case reservedKey(String)
        case missingModifier

        var errorDescription: String? {
            switch self {
            case .reservedKey(let name):
                return "\(name) is used to cancel or finish dictation. Choose another key."
            case .missingModifier:
                return "Add Control, Option, or Command so the shortcut does not clash with normal typing."
            }
        }
    }

    /// Builds a hotkey from raw key-down data. Function keys may be used alone;
    /// every other key needs Control, Option, or Command.
    static func make(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) -> Result<Hotkey, ValidationError> {
        let code = Int(keyCode)
        if code == kVK_Escape { return .failure(.reservedKey("Escape")) }
        if code == kVK_Return || code == kVK_ANSI_KeypadEnter { return .failure(.reservedKey("Return")) }

        let carbon = carbonModifiers(from: modifiers)
        let hasPrimaryModifier = carbon & (UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)) != 0
        let functionKeyName = functionKeyNames[code]
        guard hasPrimaryModifier || functionKeyName != nil else {
            return .failure(.missingModifier)
        }

        let label = functionKeyName
            ?? specialKeyNames[code]
            ?? characters?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            ?? "Key \(code)"
        return .success(Hotkey(keyCode: UInt32(keyCode), carbonModifiers: carbon, keyLabel: label.isEmpty ? "Key \(code)" : label))
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space",
        kVK_Tab: "Tab",
        kVK_Delete: "Delete",
        kVK_ForwardDelete: "Forward Delete",
        kVK_LeftArrow: "Left Arrow",
        kVK_RightArrow: "Right Arrow",
        kVK_UpArrow: "Up Arrow",
        kVK_DownArrow: "Down Arrow",
        kVK_Home: "Home",
        kVK_End: "End",
        kVK_PageUp: "Page Up",
        kVK_PageDown: "Page Down"
    ]

    private static let functionKeyNames: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20"
    ]
}

/// Whether the shortcut toggles recording or records only while held.
enum HotkeyMode: String, CaseIterable, Sendable {
    case toggle
    case hold

    var displayName: String {
        switch self {
        case .toggle: return "Press to start, press again to stop"
        case .hold: return "Hold to talk"
        }
    }
}
