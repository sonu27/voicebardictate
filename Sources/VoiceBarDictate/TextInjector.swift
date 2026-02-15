import AppKit
import ApplicationServices
import Carbon
import Foundation

struct TextInjector {
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func hasAccessibilityPermission(promptIfNeeded: Bool) -> Bool {
        if promptIfNeeded, !AXIsProcessTrusted() {
            if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(settingsURL)
            }
        }
        return AXIsProcessTrusted()
    }

    func inject(text: String) throws {
        guard hasAccessibilityPermission(promptIfNeeded: true) else {
            throw TextInjectionError.accessibilityPermissionMissing
        }

        Self.copyToClipboard(text)

        guard
            let source = CGEventSource(stateID: .combinedSessionState),
            let commandVDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: UInt16(kVK_ANSI_V),
                keyDown: true
            ),
            let commandVUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: UInt16(kVK_ANSI_V),
                keyDown: false
            )
        else {
            throw TextInjectionError.eventCreationFailed
        }

        commandVDown.flags = .maskCommand
        commandVUp.flags = .maskCommand
        commandVDown.post(tap: .cghidEventTap)
        commandVUp.post(tap: .cghidEventTap)
    }
}

enum TextInjectionError: LocalizedError {
    case accessibilityPermissionMissing
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return "Accessibility permission is required to paste into other apps."
        case .eventCreationFailed:
            return "Failed to synthesize Cmd+V key events."
        }
    }
}
