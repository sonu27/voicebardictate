import AppKit
import Carbon
import CoreGraphics
import Foundation

final class EscapeKeyMonitor {
    var onEscapePressed: (() -> Void)?
    var onReturnPressed: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fallbackGlobalMonitor: Any?
    private var fallbackLocalMonitor: Any?
    private var isCaptureActive = false
    private(set) var hasExclusiveCapture = false

    init() {
        hasExclusiveCapture = setupEventTap()
        guard !hasExclusiveCapture else { return }

        // Fallback keeps hotkeys functional if event tap permissions are unavailable,
        // but it cannot prevent keys from reaching the focused app.
        fallbackGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleFallback(event)
        }
        fallbackLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleFallback(event)
            return event
        }
    }

    func setCaptureActive(_ isActive: Bool) {
        isCaptureActive = isActive
    }

    deinit {
        teardownEventTap()

        if let fallbackGlobalMonitor {
            NSEvent.removeMonitor(fallbackGlobalMonitor)
        }
        if let fallbackLocalMonitor {
            NSEvent.removeMonitor(fallbackLocalMonitor)
        }
    }

    private func setupEventTap() -> Bool {
        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, eventType, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passRetained(event)
                }

                let monitor = Unmanaged<EscapeKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                return monitor.handleEventTap(eventType: eventType, event: event)
            },
            userInfo: userInfo
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func teardownEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }

        runLoopSource = nil
        eventTap = nil
    }

    private func handleEventTap(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        guard eventType == .keyDown else {
            return Unmanaged.passRetained(event)
        }
        guard isCaptureActive else {
            return Unmanaged.passRetained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if keyCode == CGKeyCode(kVK_Escape) {
            guard !isAutoRepeat else { return nil }
            onEscapePressed?()
            return nil
        }

        if keyCode == CGKeyCode(kVK_Return) || keyCode == CGKeyCode(kVK_ANSI_KeypadEnter) {
            guard !isAutoRepeat else { return nil }
            onReturnPressed?()
            return nil
        }

        return Unmanaged.passRetained(event)
    }

    private func handleFallback(_ event: NSEvent) {
        guard isCaptureActive, !event.isARepeat else {
            return
        }

        if event.keyCode == UInt16(kVK_Escape) {
            onEscapePressed?()
            return
        }

        if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            onReturnPressed?()
        }
    }
}
