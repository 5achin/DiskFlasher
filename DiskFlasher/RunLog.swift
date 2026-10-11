import Foundation

/// Appends timestamped lines to ~/Library/Logs/DiskFlasher/DiskFlasher.log, the standard
/// place for an app's logs on macOS (Console shows it under Log Reports).
enum RunLog {
    static let fileURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/DiskFlasher/DiskFlasher.log")

    private static let queue = DispatchQueue(label: "RunLog")
    private static let maximumSize = 1 << 20

    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    static func write(_ message: String) {
        let date = Date()
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            rotateIfNeeded()
            if !manager.fileExists(atPath: fileURL.path) {
                manager.createFile(atPath: fileURL.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            let line = "\(timestamp.string(from: date)) \(message.replacingOccurrences(of: "\n", with: "\n    "))\n"
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    /// Keeps one previous log, DiskFlasher.old.log, once the current one passes 1 MB.
    private static func rotateIfNeeded() {
        let manager = FileManager.default
        guard let size = try? manager.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
              size > maximumSize else { return }
        let oldURL = fileURL.deletingPathExtension().appendingPathExtension("old.log")
        try? manager.removeItem(at: oldURL)
        try? manager.moveItem(at: fileURL, to: oldURL)
    }
}
