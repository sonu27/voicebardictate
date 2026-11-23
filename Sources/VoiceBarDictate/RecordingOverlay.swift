import AppKit
import Observation
import SwiftUI

private enum OverlayLayout {
    static let compactWidth: CGFloat = 220
    static let expandedWidth: CGFloat = 380
    static let height: CGFloat = 62
    static let bottomInset: CGFloat = 18
    static let cornerRadius: CGFloat = 15
}

@MainActor
final class RecordingOverlayController {
    private let model = RecordingOverlayModel()
    private var panel: NSPanel?
    private var messageDismissTask: Task<Void, Never>?

    func showRecording(level: Double) {
        ensurePanel()
        messageDismissTask?.cancel()
        model.phase = .recording
        model.level = level
        model.liveText = ""
        showPanel()
    }

    func updateRecordingLevel(_ level: Double) {
        guard model.phase == .recording else { return }
        model.level = level
    }

    /// Shows partial text from a live transcriber; the panel widens to make room.
    func updateLiveText(_ text: String) {
        guard model.phase == .recording else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasEmpty = model.liveText.isEmpty
        model.liveText = trimmed
        if wasEmpty != trimmed.isEmpty {
            showPanel()
        }
    }

    func showTranscribing() {
        ensurePanel()
        messageDismissTask?.cancel()
        model.phase = .transcribing
        model.level = 0
        showPanel()
    }

    /// A short notice that hides itself, for feedback when the menu is not open.
    func showMessage(_ message: String, duration: Duration = .seconds(3)) {
        ensurePanel()
        model.phase = .message(message)
        showPanel()

        messageDismissTask?.cancel()
        messageDismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, case .message = model.phase else { return }
            hide()
        }
    }

    func hide() {
        messageDismissTask?.cancel()
        model.phase = .hidden
        model.liveText = ""

        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: OverlayLayout.compactWidth, height: OverlayLayout.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = NSHostingView(rootView: RecordingOverlayView(model: model))
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.orderOut(nil)

        self.panel = panel
    }

    private func showPanel() {
        guard let panel else { return }
        panel.setContentSize(NSSize(width: model.preferredWidth, height: OverlayLayout.height))
        repositionPanel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func repositionPanel() {
        guard let panel else { return }
        guard let screen = preferredScreen() else { return }

        let panelSize = panel.frame.size
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - (panelSize.width / 2)
        let y = visibleFrame.minY + OverlayLayout.bottomInset
        panel.setFrameOrigin(NSPoint(x: x, y: y))
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
        case recording
        case transcribing
        case message(String)
    }

    var phase: Phase = .hidden
    var level: Double = 0
    var liveText = ""

    var preferredWidth: CGFloat {
        switch phase {
        case .recording where !liveText.isEmpty, .message:
            return OverlayLayout.expandedWidth
        default:
            return OverlayLayout.compactWidth
        }
    }
}

struct RecordingOverlayView: View {
    let model: RecordingOverlayModel

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.15))
                    .frame(width: 24, height: 24)

                switch model.phase {
                case .recording:
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.white)
                        .font(.system(size: 11, weight: .semibold))
                case .message:
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.white)
                        .font(.system(size: 13, weight: .semibold))
                case .transcribing, .hidden:
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                switch model.phase {
                case .recording:
                    Text(model.liveText.isEmpty ? "Listening..." : model.liveText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.head)
                    RecordingLevelBars(level: model.level)
                case .message(let message):
                    Text(message)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                case .transcribing, .hidden:
                    Text("Transcribing...")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Processing speech")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.76))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: model.preferredWidth, height: OverlayLayout.height)
        .background(
            RoundedRectangle(cornerRadius: OverlayLayout.cornerRadius, style: .continuous)
                .fill(.black.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OverlayLayout.cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

private struct RecordingLevelBars: View {
    let level: Double

    private let multipliers: [Double] = [0.45, 0.72, 1.0, 0.78, 0.52]

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(multipliers.enumerated()), id: \.offset) { item in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 4, height: height(for: item.element))
            }
        }
        .frame(height: 16, alignment: .bottom)
        .animation(.linear(duration: 0.07), value: level)
    }

    private func height(for multiplier: Double) -> Double {
        let minHeight = 3.0
        let maxHeight = 16.0
        let scaled = min(max(level, 0), 1) * multiplier
        return minHeight + ((maxHeight - minHeight) * scaled)
    }
}
