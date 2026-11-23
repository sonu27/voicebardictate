#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: set `VOICEBAR_SNAPSHOT_DIR` to write PNGs of the interface (overlay states at launch,
/// popover states when a `cmd-popovers` file appears in that directory), for comparing against
/// `docs/design/voicebar-dark-mockups.html` without needing Screen Recording permission.
@MainActor
enum DebugSnapshots {
    static var directory: URL? {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_SNAPSHOT_DIR"], !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Renders every overlay state with sample content.
    static func writeOverlayStates() {
        guard let directory else { return }
        let started = Date().addingTimeInterval(-7)
        let keys = ListeningHints(releaseToInsert: false, capturesKeys: true)
        let samples: [(String, RecordingOverlayModel.Phase, Double, String, String?)] = [
            ("overlay-listening", .listening(startedAt: started, hints: keys), 0.8,
             "Could you check the PostgreSQL connection before the meet", nil),
            ("overlay-hold", .listening(startedAt: started, hints: ListeningHints(releaseToInsert: true, capturesKeys: true)), 0.7, "", nil),
            ("overlay-long", .listening(startedAt: started.addingTimeInterval(-95), hints: keys), 0.6,
             "So the plan is to finish the review first, and once that's done we can move the migration to Thursday, then send the summary to the whole team before lun",
             nil),
            ("overlay-no-keys", .listening(startedAt: started, hints: ListeningHints(releaseToInsert: false, capturesKeys: false)),
             0.7, "Could you check the PostgreSQL connection", nil),
            ("overlay-no-audio", .listening(startedAt: started, hints: keys), 0, "", "MacBook Pro Microphone"),
            ("overlay-transcribing", .transcribing(engineName: "OpenAI"), 0, "", nil),
            ("overlay-error", .error(
                title: "Couldn't paste the transcript",
                detail: "Accessibility access is off. The transcript is on your clipboard. Press ⌘V to paste it."
            ), 0, "", nil),
        ]

        for (name, phase, level, liveText, silentDevice) in samples {
            let model = RecordingOverlayModel()
            model.phase = phase
            model.level = level
            model.liveText = liveText
            model.silentDeviceName = silentDevice
            write(RecordingOverlayView(model: model).background(Color(hex: 0x0B0C0F)), name: name, in: directory)
        }
    }

    static weak var appState: AppState?

    /// Renders the real popover view offscreen for each mockup scenario, then restores the app's state.
    static func writePopoverStates() async {
        guard let directory, let appState else { return }
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 316, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(MenuBarView().environment(appState)))
        window.contentView = hosting
        window.orderFrontRegardless()

        for scenario in AppState.DebugScenario.allCases {
            let restore = appState.debugApply(scenario)
            try? await Task.sleep(for: .milliseconds(400))
            let size = hosting.fittingSize
            window.setContentSize(size)
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(200))
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("\(scenario.rawValue).png"))
            }
            restore()
        }
        window.orderOut(nil)
    }

    /// Watches the snapshot directory for command files: `cmd-popovers` renders the popover scenarios, and
    /// `cmd-toggle` opens or closes the menu bar panel, and `cmd-dump` appends the app's state and visible
    /// windows to `dump.log`.
    /// (UI scripting cannot click the menu bar panel reliably, so the popover is drawn offscreen.)
    static func watchForCommands() {
        guard let directory else { return }
        let log = directory.appendingPathComponent("dump.log")
        func append(_ line: String) {
            if let handle = try? FileHandle(forWritingTo: log) {
                handle.seekToEndOfFile()
                handle.write(Data((line + "\n").utf8))
                try? handle.close()
            } else {
                try? Data((line + "\n").utf8).write(to: log)
            }
        }
        let trigger = directory.appendingPathComponent("cmd-popovers")
        let dump = directory.appendingPathComponent("cmd-dump")
        let toggle = directory.appendingPathComponent("cmd-toggle")
        Task {
            while true {
                try? await Task.sleep(for: .milliseconds(300))
                if FileManager.default.fileExists(atPath: toggle.path) {
                    try? FileManager.default.removeItem(at: toggle)
                    StatusItemController.shared?.togglePanel()
                }
                if FileManager.default.fileExists(atPath: dump.path) {
                    try? FileManager.default.removeItem(at: dump)
                    let windows = NSApp.windows.filter { $0.isVisible && $0.frame.minY >= 0 }
                        .map { "\(type(of: $0)) key=\($0.isKeyWindow) \($0.frame)" }
                    let line = "model=\(appState?.model.rawValue ?? "-") phase=\(appState?.phase ?? .idle) "
                        + "active=\(NSApp.isActive) notice=\(String(describing: appState?.notice)) "
                        + "windows=\(windows.joined(separator: " | "))"
                    append(line)
                }
                guard FileManager.default.fileExists(atPath: trigger.path) else { continue }
                try? FileManager.default.removeItem(at: trigger)
                await writePopoverStates()
            }
        }
    }

    private static func write(_ view: some View, name: String, in directory: URL) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard
            let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else {
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
#endif
