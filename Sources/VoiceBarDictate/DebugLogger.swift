import Foundation
import os

final class DebugLogger: @unchecked Sendable {
    static let shared = DebugLogger()

    let fileURL: URL

    private let logger = Logger(subsystem: "VoiceBarDictate", category: "Debug")
    private let queue = DispatchQueue(label: "VoiceBarDictate.DebugLogger")
    private let maxLogBytes = 2 * 1024 * 1024
    private let trimTargetBytes = 1 * 1024 * 1024

    private init() {
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("VoiceBarDictate", isDirectory: true)

        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        fileURL = logsDirectory.appendingPathComponent("debug.log", isDirectory: false)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        info("Logger initialized at \(fileURL.path)", category: "logger")
    }

    func info(_ message: String, category: String = "app") {
        write(level: "INFO", category: category, message: message)
    }

    func warning(_ message: String, category: String = "app") {
        write(level: "WARN", category: category, message: message)
    }

    func error(_ message: String, category: String = "app") {
        write(level: "ERROR", category: category, message: message)
    }

    private func write(level: String, category: String, message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        let line = "\(timestamp) [\(level)] [\(category)] \(message)"
        logger.log("\(line, privacy: .public)")

        queue.async { [fileURL, maxLogBytes, trimTargetBytes] in
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }

            guard
                let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                let size = attributes[.size] as? NSNumber,
                size.intValue > maxLogBytes,
                let content = try? Data(contentsOf: fileURL)
            else {
                return
            }

            let trimOffset = max(content.count - trimTargetBytes, 0)
            let trimmed = content.subdata(in: trimOffset..<content.count)
            try? trimmed.write(to: fileURL, options: .atomic)
        }
    }
}
