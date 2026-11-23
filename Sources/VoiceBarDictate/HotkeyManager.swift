import Carbon
import Foundation

/// Registers one global shortcut through Carbon and reports key-down and key-up (for hold-to-talk).
/// Carbon delivers these events on the main thread.
final class HotkeyManager {
    var onHotKeyPressed: (() -> Void)?
    var onHotKeyReleased: (() -> Void)?

    private let hotKeyID = EventHotKeyID(signature: fourCharCode(from: "VBDT"), id: 1)
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    init() {
        installEventHandler()
    }

    deinit {
        unregister()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    func register(_ hotkey: Hotkey) throws {
        unregister()

        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr else {
            hotKeyRef = nil
            throw HotkeyError.registerFailed(hotkey.displayString, status)
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installEventHandler() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef, let userData else {
                    return OSStatus(eventNotHandledErr)
                }

                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                var incomingID = EventHotKeyID()
                let result = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &incomingID
                )

                guard result == noErr else {
                    return result
                }

                guard incomingID.id == manager.hotKeyID.id, incomingID.signature == manager.hotKeyID.signature else {
                    return OSStatus(eventNotHandledErr)
                }

                switch GetEventKind(eventRef) {
                case UInt32(kEventHotKeyPressed):
                    manager.onHotKeyPressed?()
                case UInt32(kEventHotKeyReleased):
                    manager.onHotKeyReleased?()
                default:
                    return OSStatus(eventNotHandledErr)
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            userData,
            &eventHandlerRef
        )

        if status != noErr {
            eventHandlerRef = nil
        }
    }
}

enum HotkeyError: LocalizedError {
    case registerFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .registerFailed(let shortcut, let status):
            return "\(shortcut) could not be registered (OSStatus \(status)). Another app may already use it."
        }
    }
}

private func fourCharCode(from string: String) -> OSType {
    precondition(string.utf16.count == 4, "Four-character code must be exactly 4 UTF-16 code units.")
    return string.utf16.reduce(0) { ($0 << 8) + OSType($1) }
}
