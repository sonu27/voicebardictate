import AppKit
import SwiftUI

/// Colours from `docs/design/voicebar-dark-mockups.html`. The app is dark-only, so these are fixed values.
enum Theme {
    static let accent = Color(hex: 0x2F6FE8)
    static let accentPressed = Color(hex: 0x2559C0)
    static let accentBright = Color(hex: 0x4C8DFF)
    static let accentOnFill = Color(hex: 0xDBE7FF)

    static let popoverBackground = Color(hex: 0x1F2229)
    static let overlayBackground = Color(hex: 0x1B1D22)
    static let border = Color(hex: 0x3A3F4A)
    static let divider = Color(hex: 0x343944)
    static let segmentTrack = Color(hex: 0x15171C)
    static let segmentSelected = Color(hex: 0x3A3F4A)
    static let cardBackground = Color(hex: 0x262A32)

    static let textPrimary = Color(hex: 0xF2F3F5)
    static let textBody = Color(hex: 0xDFE2E7)
    static let textSecondary = Color(hex: 0xA7ADB8)
    static let textTertiary = Color(hex: 0x8D939E)

    static let keycapOnFill = Color.white.opacity(0.18)
    static let keycapBackground = Color(hex: 0x2B2F38)
    static let keycapBorder = Color(hex: 0x454B57)
    static let keycapText = Color(hex: 0xC9CDD6)

    static let warningBackground = Color(hex: 0x3A2F17)
    static let warningBorder = Color(hex: 0x6B5420)
    static let warningText = Color(hex: 0xF3DCAE)
    static let warningAccent = Color(hex: 0xF0B44C)

    static let errorAccent = Color(hex: 0xFF6961)
    static let meterIdle = Color(hex: 0x4C4F57)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// A single key, e.g. `⌃` or `Space`.
struct KeyCap: View {
    enum Style {
        /// On the blue primary button.
        case onAccent
        /// On a dark surface.
        case onSurface
    }

    let label: String
    var style: Style = .onSurface

    var body: some View {
        Text(label)
            .font(.system(size: 11))
            .foregroundStyle(style == .onAccent ? Color.white : Theme.keycapText)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(style == .onAccent ? Theme.keycapOnFill : Theme.keycapBackground)
            )
            .overlay {
                if style == .onSurface {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Theme.keycapBorder, lineWidth: 0.5)
                }
            }
    }
}

/// Every key of a shortcut as separate keycaps.
struct HotkeyCaps: View {
    let hotkey: Hotkey
    var style: KeyCap.Style = .onAccent

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(hotkey.keyCapLabels.enumerated()), id: \.offset) { _, label in
                KeyCap(label: label, style: style)
            }
        }
    }
}

/// Live input level as ten bars; grey and flat when no audio has been heard.
struct LevelBars: View {
    let level: Double
    var isSilent = false

    private static let multipliers: [Double] = [0.25, 0.5, 0.8, 1.0, 0.7, 0.88, 0.45, 0.62, 0.32, 0.18]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(Self.multipliers.enumerated()), id: \.offset) { _, multiplier in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(isSilent ? Theme.meterIdle : Theme.accentBright)
                    .frame(width: 3, height: height(for: multiplier))
            }
        }
        .frame(height: 16)
        .animation(.linear(duration: 0.07), value: level)
    }

    private func height(for multiplier: Double) -> Double {
        guard !isSilent else { return 3 }
        let scaled = min(max(level, 0), 1) * multiplier
        return 3 + (13 * scaled)
    }
}

/// The blue recording dot with a soft halo that pulses.
struct PulsingDot: View {
    var size: CGFloat = 8
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Theme.accentBright)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(Theme.accentBright.opacity(0.25))
                    .frame(width: size + 6, height: size + 6)
                    .scaleEffect(pulsing ? 1.25 : 0.85)
                    .opacity(pulsing ? 0.4 : 1)
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}

/// A small rotating arc, drawn in SwiftUI so it matches the accent and renders the same everywhere.
struct Spinner: View {
    var color: Color = Theme.accentBright
    var size: CGFloat = 13
    @State private var rotation = 0.0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

/// "0:07", "1:42", "12:05" from a start date, updated every second.
struct ElapsedTimeText: View {
    let since: Date
    var color: Color = Theme.textTertiary

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(DictationFormat.elapsed(context.date.timeIntervalSince(since)))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(color)
        }
    }
}

/// Pure formatting helpers shared by the popover and the overlay.
enum DictationFormat {
    static func elapsed(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    /// The end of `text`, cut at a word boundary and prefixed with "…" when longer than `maxCharacters`,
    /// so live text always shows the newest words.
    static func tail(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let suffix = text.suffix(maxCharacters)
        let trimmed = suffix.drop(while: { !$0.isWhitespace }).drop(while: { $0.isWhitespace })
        return "…" + (trimmed.isEmpty ? String(suffix) : String(trimmed))
    }

    /// "just now", "2 min ago", "yesterday".
    static func relative(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 {
            return "just now"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
