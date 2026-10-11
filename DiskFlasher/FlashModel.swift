import Foundation

@MainActor
final class FlashModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case flashing
        case succeeded(String)
        case cancelled(String)
        case failed(String)
    }

    @Published var isoURL: URL?
    @Published var disks: [Disk] = []
    @Published var selectedDiskID: Disk.ID?
    @Published var status: Status = .idle
    @Published var bytesWritten: Int64 = 0
    @Published var isoSize: Int64 = 0
    @Published var options = FlashOptions()

    /// The operands of the dd command as it will be run, for display.
    var commandOperands: [String] {
        let input = isoURL?.path ?? "image.iso"
        let output = selectedDisk.map(options.outputPath) ?? (options.useRawDevice ? "/dev/rdiskN" : "/dev/diskN")
        return options.operands(input: input, output: output)
    }

    /// Set while a flash is running; creating this file tells the privileged script to stop dd.
    private var cancelFileURL: URL?
    @Published private(set) var isCancelling = false

    var selectedDisk: Disk? {
        disks.first { $0.id == selectedDiskID }
    }

    var isFlashing: Bool { status == .flashing }

    var canFlash: Bool {
        isoURL != nil && selectedDisk != nil && !isFlashing
    }

    var progress: Double {
        isoSize > 0 ? min(Double(bytesWritten) / Double(isoSize), 1) : 0
    }

    func refreshDisks() async {
        disks = await DiskService.externalDisks()
        if selectedDisk == nil {
            selectedDiskID = disks.first?.id
        }
    }

    func flash() async {
        guard let isoURL, let disk = selectedDisk, !isFlashing else { return }

        let size = (try? isoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size > 0 else {
            status = .failed("The ISO file could not be read.")
            return
        }
        let options = options
        let total = options.bytesToCopy(inputSize: size)
        guard total > 0 else {
            status = .failed("With these options there is nothing to copy. Check Skip and Count.")
            return
        }
        guard options.endOffset(inputSize: size) <= disk.size else {
            status = .failed("The data would not fit on \(disk.name).")
            return
        }
        // Disk numbers can be reassigned when drives are replugged, so check
        // that the identifier still points at the drive that was chosen.
        guard let current = await DiskService.info(for: disk.id),
              current.name == disk.name, current.size == disk.size else {
            status = .failed("\(disk.devicePath) is no longer the drive you selected. Refresh the list and try again.")
            await refreshDisks()
            return
        }

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskFlasher-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: logURL) }

        let cancelURL = logURL.deletingPathExtension().appendingPathExtension("cancel")
        cancelFileURL = cancelURL
        isCancelling = false
        defer {
            try? FileManager.default.removeItem(at: cancelURL)
            cancelFileURL = nil
            isCancelling = false
        }

        isoSize = total
        bytesWritten = 0
        status = .flashing

        let monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if let written = Self.bytesTransferred(inLogAt: logURL) {
                    self?.bytesWritten = written
                }
            }
        }

        // Same steps as flash_iso.sh: unmount, dd to the raw device, eject.
        // dd runs in the background so the script can stop it when the cancel file appears.
        let cancelPath = Shell.quote(cancelURL.path)
        let dd = options.operands(input: isoURL.path, output: options.outputPath(for: disk))
            .map(Shell.quote)
            .joined(separator: " ")
        var steps = [
            "/usr/sbin/diskutil unmountDisk \(disk.devicePath) || exit 1",
            "/bin/dd \(dd) 2>\(Shell.quote(logURL.path)) & pid=$!",
            "while kill -0 $pid 2>/dev/null; do if [ -e \(cancelPath) ]; then kill $pid; wait $pid; exit 99; fi; sleep 0.5; done",
            "wait $pid || exit 1",
        ]
        if options.ejectWhenDone {
            steps.append("/usr/sbin/diskutil eject \(disk.devicePath)")
        }
        let command = steps.joined(separator: "; ")
        let result = await Shell.run("/usr/bin/osascript", ["-e", Self.appleScript(runningAsAdmin: command)])
        monitor.cancel()

        if isCancelling && result.status != 0 {
            status = .cancelled("Flashing was cancelled. \(disk.name) is partially written and unusable until you flash it again or erase it in Disk Utility.")
        } else if result.status == 0 {
            bytesWritten = total
            status = .succeeded(options.ejectWhenDone
                ? "Your bootable USB is ready. \(disk.name) has been ejected."
                : "Your bootable USB is ready. Eject \(disk.name) before unplugging it.")
        } else if result.errorOutput.contains("-128") {
            status = .idle
        } else {
            let ddError = (try? String(contentsOf: logURL, encoding: .utf8))?
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .last { $0.hasPrefix("dd:") }
                .map(String.init)
            status = .failed(ddError ?? (result.errorOutput.isEmpty ? "Flashing failed." : result.errorOutput))
        }
        await refreshDisks()
    }

    /// Stops a running flash. The drive is left partially written.
    func cancel() {
        guard isFlashing, let cancelFileURL else { return }
        isCancelling = true
        FileManager.default.createFile(atPath: cancelFileURL.path, contents: nil)
    }

    /// Wraps a shell command in AppleScript that asks macOS for an administrator password.
    private static func appleScript(runningAsAdmin command: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    /// Reads the latest byte count from dd's `status=progress` output.
    nonisolated private static func bytesTransferred(inLogAt url: URL) -> Int64? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data.suffix(512), as: UTF8.self)
        guard let match = text.matches(of: /([0-9]+) bytes/).last else { return nil }
        return Int64(match.1)
    }
}
