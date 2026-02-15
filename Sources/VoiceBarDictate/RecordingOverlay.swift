import AppKit
import SwiftUI

private enum OverlayLayout {
    static let compactWidth: CGFloat = 220
    static let compactHeight: CGFloat = 62
    static let liveWidth: CGFloat = 420
    static let liveHeight: CGFloat = 136
    static let bottomInset: CGFloat = 18
    static let cornerRadius: CGFloat = 15
}

@MainActor
final class RecordingOverlayController {
    private let model = RecordingOverlayModel()
    private var panel: NSPanel?

    func showRecording(level: Double) {
        ensurePanel()
        model.phase = .recording
        model.level = level
        model.previewText = ""
        showPanel()
    }

    func updateRecordingLevel(_ level: Double) {
        guard model.phase == .recording else { return }
        model.level = level
    }

    func showTranscribing() {
        ensurePanel()
        model.phase = .transcribing
        model.level = 0
        model.previewText = ""
        showPanel()
    }

    func showLiveRecording(level: Double, text: String) {
        ensurePanel()
        model.phase = .liveRecording
        model.level = level
        model.previewText = text
        showPanel()
    }

    func updateLiveRecording(level: Double, text: String) {
        guard model.phase == .liveRecording else { return }
        model.level = level
        model.previewText = text
    }

    func showLiveFinalizing(text: String) {
        ensurePanel()
        model.phase = .liveFinalizing
        model.level = 0
        model.previewText = text
        showPanel()
    }

    func updateLiveText(_ text: String) {
        guard model.phase == .liveRecording || model.phase == .liveFinalizing else { return }
        model.previewText = text
    }

    func hide() {
        model.phase = .hidden

        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: OverlayLayout.compactWidth,
                height: OverlayLayout.compactHeight
            ),
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
        applySize(for: model.phase)
        repositionPanel()

        if panel.isVisible {
            panel.orderFrontRegardless()
            return
        }

        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func applySize(for phase: RecordingOverlayModel.Phase) {
        guard let panel else { return }
        let width = phase.isLiveMode ? OverlayLayout.liveWidth : OverlayLayout.compactWidth
        let height = phase.isLiveMode ? OverlayLayout.liveHeight : OverlayLayout.compactHeight

        guard panel.frame.width != width || panel.frame.height != height else {
            return
        }

        var frame = panel.frame
        frame.size = NSSize(width: width, height: height)
        panel.setFrame(frame, display: true)
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

@MainActor
final class RecordingOverlayModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case recording
        case transcribing
        case liveRecording
        case liveFinalizing

        var isLiveMode: Bool {
            self == .liveRecording || self == .liveFinalizing
        }
    }

    @Published var phase: Phase = .hidden
    @Published var level: Double = 0
    @Published var previewText: String = ""
}

struct RecordingOverlayView: View {
    @ObservedObject var model: RecordingOverlayModel

    var body: some View {
        Group {
            if model.phase.isLiveMode {
                liveModeBody
            } else {
                compactBody
            }
        }
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

    private var compactBody: some View {
        HStack(spacing: 9) {
            iconView(isListening: model.phase == .recording)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.phase == .recording ? "Listening..." : "Transcribing...")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)

                if model.phase == .recording {
                    RecordingLevelBars(level: model.level)
                } else {
                    Text("Processing speech")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.76))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: OverlayLayout.compactWidth, height: OverlayLayout.compactHeight)
    }

    private var liveModeBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                iconView(isListening: model.phase == .liveRecording)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.phase == .liveRecording ? "Live Dictation" : "Finalizing...")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(model.phase == .liveRecording ? "Listening and previewing text" : "Committing final transcript")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.76))
                }
                Spacer(minLength: 0)
            }

            if model.phase == .liveRecording {
                RecordingLevelBars(level: model.level)
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.08))

                if model.previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Speak to see live transcript...")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.52))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                } else {
                    Text(model.previewText)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                }
            }
            .frame(height: 58)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: OverlayLayout.liveWidth, height: OverlayLayout.liveHeight)
    }

    private func iconView(isListening: Bool) -> some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.15))
                .frame(width: 24, height: 24)

            if isListening {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.white)
                    .font(.system(size: 11, weight: .semibold))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
        }
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
