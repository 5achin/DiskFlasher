import Foundation

struct ShellResult {
    let status: Int32
    let output: Data
    let errorOutput: String
}

enum Shell {
    /// Runs a command off the main thread and returns once it exits.
    static func run(_ executable: String, _ arguments: [String]) async -> ShellResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ShellResult(status: -1, output: Data(), errorOutput: error.localizedDescription))
                    return
                }
                let output = out.fileHandleForReading.readDataToEndOfFile()
                let errorData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: ShellResult(
                    status: process.terminationStatus,
                    output: output,
                    errorOutput: String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }
    }

    /// Quotes a string for use as a single word in /bin/sh.
    static func quote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
