import AppKit
import SwiftUI

/// The menu bar panel's content, hosted by `StatusItemController`. See `docs/design/voicebar-dark-mockups.html`.
struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettingsWindow) private var openSettingsWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 10)
            PrimaryButton(appState: appState, action: primaryAction)

            if appState.isRecording, !appState.liveText.isEmpty {
                Text(DictationFormat.tail(appState.liveText, maxCharacters: 140))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textBody)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .truncationMode(.head)
                    .padding(.horizontal, 2)
                    .padding(.top, 10)
            }

            EngineSwitch(appState: appState)
                .padding(.top, 10)
            engineCaption
                .padding(.horizontal, 2)
                .padding(.top, 7)

            if let notice = appState.notice, !appState.isRecording {
                NoticeCard(notice: notice, appState: appState, openSettings: openSettings)
                    .padding(.top, 10)
            }

            if !appState.isRecording {
                Divider()
                    .overlay(Theme.divider)
                    .padding(.top, 10)
                LastTranscriptSection(appState: appState)
                    .padding(.top, 9)
            }
        }
        .padding(12)
        .frame(width: 316)
        .background(Theme.popoverBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 0.5)
        )
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.accentBright)
                Text("VoiceBar")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
            }
            Spacer()
            Menu {
                Button("Settings…") { openSettings() }
                    .keyboardShortcut(",")
                Divider()
                Button("Quit VoiceBar") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
    }

    @ViewBuilder
    private var engineCaption: some View {
        if appState.isRecording {
            Text("You can switch engines after this dictation.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        } else if appState.model == .appleOnDevice {
            Label("Audio stays on this Mac", systemImage: "checkmark.shield")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        } else {
            Label("Audio is sent to OpenAI · \(appState.openAIModelID)", systemImage: "icloud.and.arrow.up")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
    }

    private func primaryAction() {
        // Close the panel first so focus can return to the app the user was typing in.
        MenuBarPanel.close()
        appState.toggleFromMenu()
    }

    private func openSettings() {
        openSettingsWindow()
    }
}

// MARK: - Primary button

private struct PrimaryButton: View {
    let appState: AppState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                icon
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 8)
                trailing
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(AccentButtonStyle())
        .opacity(isDimmed ? 0.5 : 1)
        .disabled(appState.phase == .starting || appState.isTranscribing)
    }

    /// Dimmed while the on-device model downloads; still clickable, and clicking explains why it can't start.
    private var isDimmed: Bool {
        appState.phase == .idle && appState.isWaitingForAppleModel
    }

    private var title: String {
        switch appState.phase {
        case .idle: return appState.hotkeyMode == .hold ? "Hold to dictate" : "Start dictation"
        case .starting: return "Starting…"
        case .recording: return "Stop and insert"
        case .transcribing: return "Transcribing…"
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch appState.phase {
        case .idle: Image(systemName: "mic")
        case .recording: Image(systemName: "stop.fill")
        case .starting, .transcribing: Spinner(color: .white, size: 12)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if appState.isRecording, let startedAt = appState.recordingStartedAt {
            HStack(spacing: 6) {
                Circle().fill(.white).frame(width: 6, height: 6)
                ElapsedTimeText(since: startedAt, color: Theme.accentOnFill)
            }
        } else if appState.phase == .idle {
            HotkeyCaps(hotkey: appState.hotkey, style: .onAccent)
        }
    }
}

private struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? Theme.accentPressed : Theme.accent)
            )
    }
}

// MARK: - Engine switch

private struct EngineSwitch: View {
    let appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            segment("On-device", engine: .appleOnDevice, isAvailable: appState.isOnDeviceSupported)
            segment("OpenAI", engine: .gptTranscribe, isAvailable: true)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.segmentTrack))
        .opacity(appState.canChangeModel ? 1 : 0.55)
        .disabled(!appState.canChangeModel)
    }

    private func segment(_ title: String, engine: TranscriptionModel, isAvailable: Bool) -> some View {
        let isSelected = appState.model == engine
        return Button {
            appState.setEngine(engine)
        } label: {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Theme.segmentSelected : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.45)
        .help(isAvailable ? "" : "On-device dictation needs macOS 26 or later.")
    }
}

// MARK: - Notices

private struct NoticeCard: View {
    let notice: PopoverNotice
    let appState: AppState
    let openSettings: () -> Void

    var body: some View {
        switch notice {
        case .downloading(let progress, let languageName):
            DownloadCard(progress: progress, languageName: languageName)
        case .accessibilityMissing:
            WarningCard(
                message: "Accessibility access is off, so transcripts can't be pasted.",
                actionTitle: "Open System Settings",
                action: {
                    MenuBarPanel.close()
                    appState.openAccessibilitySettings()
                }
            )
        case .microphoneDenied:
            WarningCard(
                message: "Microphone access is off, so VoiceBar can't hear you.",
                actionTitle: "Open System Settings",
                action: {
                    MenuBarPanel.close()
                    appState.openMicrophoneSettings()
                }
            )
        case .apiKeyMissing:
            WarningCard(
                message: "Add your OpenAI API key to dictate with OpenAI.",
                actionTitle: "Open Settings",
                action: openSettings
            )
        case .onDeviceUnavailable:
            WarningCard(
                message: "On-device dictation needs macOS 26 or later. Switch to OpenAI to dictate.",
                actionTitle: nil,
                action: {}
            )
        case .error(let message):
            ErrorCard(message: message, dismiss: appState.dismissError)
        case .info(let message):
            ErrorCard(message: message, icon: "info.circle", iconColor: Theme.accentBright, dismiss: appState.dismissInfo)
        }
    }
}

private struct DownloadCard: View {
    let progress: Double
    let languageName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(languageName.isEmpty ? "Downloading the speech model" : "Downloading \(languageName)")
                    .lineLimit(1)
                Spacer()
                Text("\(Int((progress * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.textPrimary)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.border)
                    Capsule().fill(Theme.accentBright)
                        .frame(width: proxy.size.width * min(max(progress, 0), 1))
                }
            }
            .frame(height: 4)
            .animation(.linear(duration: 0.4), value: progress)

            Text("On-device dictation is available when this finishes")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

private struct WarningCard: View {
    let message: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.warningAccent)
            VStack(alignment: .leading, spacing: 3) {
                Text(message)
                    .foregroundStyle(Theme.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle {
                    Button(actionTitle, action: action)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.warningAccent)
                }
            }
            .font(.system(size: 11))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.warningBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.warningBorder, lineWidth: 0.5)
        )
    }
}

private struct ErrorCard: View {
    let message: String
    var icon = "exclamationmark.circle"
    var iconColor = Theme.errorAccent
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(iconColor)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textBody)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

// MARK: - Last transcript

private struct LastTranscriptSection: View {
    let appState: AppState

    var body: some View {
        if appState.lastTranscript.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("No transcripts yet")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Text(appState.hotkeyMode == .hold
                    ? "Hold the shortcut, speak, then let go."
                    : "Press the shortcut, speak, then press it again.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    label
                    Spacer()
                    HStack(spacing: 10) {
                        iconButton("doc.on.doc", help: "Copy") {
                            appState.copyLastTranscriptToClipboard()
                        }
                        iconButton("doc.on.clipboard", help: "Paste again") {
                            MenuBarPanel.close()
                            appState.pasteLastTranscript()
                        }
                        .disabled(appState.phase != .idle)
                    }
                }
                Text(appState.lastTranscript)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textBody)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
    }

    private var label: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(labelText(now: context.date))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func labelText(now: Date) -> String {
        guard let date = appState.lastTranscriptDate else { return "Last transcript" }
        return "Last transcript · \(DictationFormat.relative(date, now: now))"
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
