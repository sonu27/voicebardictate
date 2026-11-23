import AppKit
import Observation
import SwiftUI

private enum OverlayLayout {
    static let wideWidth: CGFloat = 340
    static let compactWidth: CGFloat = 220
    /// The panel is a fixed transparent canvas; the card sits at its bottom edge and grows upwards,
    /// so changing state never needs a window resize and the card's bottom edge never moves.
    static let canvasSize = NSSize(width: 380, height: 200)
    /// Room around the card for its shadow.
    static let shadowMargin: CGFloat = 20
    static let bottomInset: CGFloat = 18 - shadowMargin
    static let cornerRadius: CGFloat = 14
}

/// What the listening card's footer offers.
struct ListeningHints: Equatable {
    /// Hold-to-talk started from the shortcut: letting go inserts.
    var releaseToInsert: Bool
    /// Return and Escape are captured system-wide (needs Accessibility). When false, the footer shows plain
    /// buttons instead of key labels, so it never suggests keys that won't work.
    var capturesKeys: Bool
}

@MainActor
final class RecordingOverlayController {
    /// Called when Insert or Cancel is clicked in the listening card.
    var onInsert: (() -> Void)?
    var onCancel: (() -> Void)?

    private let model = RecordingOverlayModel()
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var mouseMonitors: [Any] = []

    func showListening(startedAt: Date, hints: ListeningHints) {
        model.level = 0
        model.liveText = ""
        model.silentDeviceName = nil
        present(.listening(startedAt: startedAt, hints: hints))
    }

    func updateLevel(_ level: Double, silentDeviceName: String?) {
        guard case .listening = model.phase else { return }
        model.level = level
        if model.silentDeviceName != silentDeviceName {
            model.silentDeviceName = silentDeviceName
        }
    }

    /// Partial text from a live transcriber.
    func updateLiveText(_ text: String) {
        guard case .listening = model.phase else { return }
        model.liveText = text
    }

    func showTranscribing(engineName: String) {
        present(.transcribing(engineName: engineName))
    }

    /// A short notice that hides itself, for feedback when the menu is not open.
    func showMessage(_ message: String, duration: Duration = .seconds(3)) {
        present(.message(message), autoHideAfter: duration)
    }

    func showError(title: String, detail: String) {
        present(.error(title: title, detail: detail), autoHideAfter: .seconds(5))
    }

    func hide() {
        dismissTask?.cancel()
        stopTrackingMouse()
        model.phase = .hidden
        model.liveText = ""
        model.silentDeviceName = nil
        panel?.orderOut(nil)
    }

    private func present(_ phase: RecordingOverlayModel.Phase, autoHideAfter duration: Duration? = nil) {
        ensurePanel()
        dismissTask?.cancel()
        model.phase = phase
        showPanel()
        if case .listening = phase {
            startTrackingMouse()
        } else {
            stopTrackingMouse()
        }

        guard let duration else { return }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, model.phase == phase else { return }
            hide()
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: OverlayLayout.canvasSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = FirstClickHostingView(rootView: RecordingOverlayView(
            model: model,
            onInsert: { [weak self] in self?.onInsert?() },
            onCancel: { [weak self] in self?.onCancel?() }
        ))
        panel.acceptsMouseMovedEvents = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.orderOut(nil)

        self.panel = panel
    }

    private func showPanel() {
        guard let panel, let screen = preferredScreen() else { return }
        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - (OverlayLayout.canvasSize.width / 2),
            y: visibleFrame.minY + OverlayLayout.bottomInset
        )
        panel.setFrame(NSRect(origin: origin, size: OverlayLayout.canvasSize), display: false)
        panel.orderFrontRegardless()
    }

    // MARK: Clicks

    /// The panel is a large transparent canvas, so it ignores the mouse except while the pointer is over the
    /// card; otherwise it would block clicks meant for the app underneath. Watching mouse movement needs no
    /// permission, unlike watching keys.
    private func startTrackingMouse() {
        guard mouseMonitors.isEmpty else { return }
        updateMouseInteractivity()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMouseInteractivity() }
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateMouseInteractivity() }
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func stopTrackingMouse() {
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors.removeAll()
        panel?.ignoresMouseEvents = true
    }

    private func updateMouseInteractivity() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        // `cardFrame` is in SwiftUI's top-left-origin coordinates within the panel.
        let local = NSPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
        let isOverCard = model.cardFrame.contains(local)
        if panel.ignoresMouseEvents == isOverCard {
            panel.ignoresMouseEvents = !isOverCard
        }
    }

    private func preferredScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let matchingScreen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return matchingScreen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}

@Observable
@MainActor
final class RecordingOverlayModel {
    enum Phase: Equatable {
        case hidden
        case listening(startedAt: Date, hints: ListeningHints)
        case transcribing(engineName: String)
        case message(String)
        case error(title: String, detail: String)
    }

    var phase: Phase = .hidden
    var level: Double = 0
    var liveText = ""
    /// Set when nothing has been heard from this input device since recording began.
    var silentDeviceName: String?
    /// Where the card is drawn, so the panel only takes clicks over it.
    @ObservationIgnored var cardFrame: CGRect = .zero
}

/// Lets a click on a button in the non-activating overlay act at once, instead of only focusing the panel.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct CardFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct RecordingOverlayView: View {
    let model: RecordingOverlayModel
    var onInsert: () -> Void = {}
    var onCancel: () -> Void = {}

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            card
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: CardFrameKey.self, value: proxy.frame(in: .named("canvas")))
                })
                .padding(.bottom, OverlayLayout.shadowMargin)
        }
        .coordinateSpace(name: "canvas")
        .onPreferenceChange(CardFrameKey.self) { frame in
            MainActor.assumeIsolated { model.cardFrame = frame }
        }
        .frame(width: OverlayLayout.canvasSize.width, height: OverlayLayout.canvasSize.height)
        .animation(.snappy(duration: 0.2), value: model.phase)
        .animation(.snappy(duration: 0.2), value: model.liveText.isEmpty)
        .animation(.snappy(duration: 0.2), value: model.silentDeviceName)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var card: some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case .listening(let startedAt, let hints):
            listening(startedAt: startedAt, hints: hints)
                .cardStyle(width: OverlayLayout.wideWidth)
        case .transcribing(let engineName):
            HStack(spacing: 8) {
                Spinner()
                    .frame(width: 16, height: 16)
                Text("Transcribing…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Text(engineName)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .cardStyle(width: OverlayLayout.compactWidth)
        case .message(let message):
            notice(icon: "info.circle", iconColor: Theme.accentBright, title: message, detail: nil)
                .cardStyle(width: OverlayLayout.wideWidth)
        case .error(let title, let detail):
            notice(icon: "exclamationmark.circle", iconColor: Theme.errorAccent, title: title, detail: detail)
                .cardStyle(width: OverlayLayout.wideWidth)
        }
    }

    private func listening(startedAt: Date, hints: ListeningHints) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                PulsingDot()
                Text("Listening")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                ElapsedTimeText(since: startedAt)
                Spacer(minLength: 8)
                LevelBars(level: model.level, isSilent: model.silentDeviceName != nil)
            }

            if !model.liveText.isEmpty {
                // About two lines at this width; showing the tail keeps the newest words visible.
                Text(DictationFormat.tail(model.liveText, maxCharacters: 96))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textBody)
                    .lineSpacing(2)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 7)
            }

            if let deviceName = model.silentDeviceName {
                Label("No audio from \(deviceName). Check your input device.", systemImage: "mic.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warningAccent)
                    .lineLimit(2)
                    .padding(.top, 8)
            } else {
                Divider()
                    .overlay(Theme.divider)
                    .padding(.top, 8)
                HStack {
                    if hints.releaseToInsert {
                        Label("Release to insert", systemImage: "hand.raised")
                            .padding(.vertical, 3)
                    } else {
                        HintButton(key: hints.capturesKeys ? "↩" : nil, title: "Insert", action: onInsert)
                    }
                    Spacer()
                    HintButton(key: hints.capturesKeys ? "esc" : nil, title: "Cancel", action: onCancel)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 4)
            }
        }
    }

    private func notice(icon: String, iconColor: Color, title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private extension View {
    func cardStyle(width: CGFloat) -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: width)
            .background(
                RoundedRectangle(cornerRadius: OverlayLayout.cornerRadius, style: .continuous)
                    .fill(Theme.overlayBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OverlayLayout.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
    }
}

/// A footer action: the key that triggers it (when keys are captured) plus a label, clickable either way.
private struct HintButton: View {
    let key: String?
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let key {
                    KeyCap(label: key)
                }
                Text(title)
                    .foregroundStyle(isHovered ? Theme.textPrimary : Theme.textTertiary)
            }
            .padding(.horizontal, key == nil ? 8 : 3)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(key == nil || isHovered ? Theme.keycapBackground : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
