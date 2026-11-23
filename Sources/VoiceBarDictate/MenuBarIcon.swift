import AppKit

/// Menu bar images for each `MenuBarIconState`.
///
/// `MenuBarExtra` labels can only show an `Image` or `Text`, so coloured states are drawn into non-template
/// `NSImage`s. Idle and transcribing stay template images, so macOS tints them like every other menu bar icon.
@MainActor
enum MenuBarIcon {
    private static let size = NSSize(width: 22, height: 16)
    private static let accent = NSColor(srgbRed: 0x2F / 255, green: 0x6F / 255, blue: 0xE8 / 255, alpha: 1)
    private static let accentBright = NSColor(srgbRed: 0x4C / 255, green: 0x8D / 255, blue: 0xFF / 255, alpha: 1)

    static func image(for state: MenuBarIconState) -> NSImage {
        switch state {
        case .idle:
            return symbol("waveform")
        case .transcribing:
            return symbol("ellipsis")
        case .recording:
            return recordingTile
        case .downloading(let progress):
            return progressRing(progress)
        }
    }

    private static func symbol(_ name: String) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "VoiceBar")?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = true
        return image
    }

    /// A filled blue tile with a white waveform.
    private static let recordingTile: NSImage = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        let waveform = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)

        let image = NSImage(size: size, flipped: false) { rect in
            accent.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            if let waveform {
                let origin = NSPoint(
                    x: rect.midX - waveform.size.width / 2,
                    y: rect.midY - waveform.size.height / 2
                )
                waveform.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "VoiceBar, recording"
        return image
    }()

    /// A grey ring with the downloaded share in blue.
    private static func progressRing(_ progress: Double) -> NSImage {
        let fraction = min(max(progress, 0), 1)
        let image = NSImage(size: size, flipped: false) { rect in
            let diameter: CGFloat = 12
            let ringRect = NSRect(
                x: rect.midX - diameter / 2,
                y: rect.midY - diameter / 2,
                width: diameter,
                height: diameter
            )
            let track = NSBezierPath(ovalIn: ringRect.insetBy(dx: 1, dy: 1))
            track.lineWidth = 2
            NSColor(white: 0.32, alpha: 1).setStroke()
            track.stroke()

            let arc = NSBezierPath()
            let center = NSPoint(x: ringRect.midX, y: ringRect.midY)
            arc.appendArc(
                withCenter: center,
                radius: diameter / 2 - 1,
                startAngle: 90,
                endAngle: 90 - 360 * fraction,
                clockwise: true
            )
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            accentBright.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "VoiceBar, downloading the speech model"
        return image
    }
}
