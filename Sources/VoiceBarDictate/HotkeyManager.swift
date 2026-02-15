import Carbon
import Foundation

final class HotkeyManager {
    var onHotKeyPressed: (() -> Void)?

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

    func registerDefaultShortcut() throws {
        let modifiers = UInt32(controlKey) | UInt32(optionKey)
        try register(keyCode: UInt32(kVK_Space), modifiers: modifiers)
    }

    func register(keyCode: UInt32, modifiers: UInt32) throws {
        unregister()

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr else {
            throw HotkeyError.registerFailed(status)
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

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

                if incomingID.id == manager.hotKeyID.id, incomingID.signature == manager.hotKeyID.signature {
                    manager.onHotKeyPressed?()
                    return noErr
                }

                return OSStatus(eventNotHandledErr)
            },
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )

        if status != noErr {
            eventHandlerRef = nil
        }
    }
}

enum HotkeyError: LocalizedError {
    case registerFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .registerFailed(let status):
            return "RegisterEventHotKey failed with OSStatus \(status)."
        }
    }
}

private func fourCharCode(from string: String) -> OSType {
    precondition(string.utf16.count == 4, "Four-character code must be exactly 4 UTF-16 code units.")
    return string.utf16.reduce(0) { ($0 << 8) + OSType($1) }
}
