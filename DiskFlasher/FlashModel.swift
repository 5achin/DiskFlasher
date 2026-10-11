import Foundation

@MainActor
final class FlashModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case flashing
        case succeeded(String)
        case failed(String)
    }

    @Published var isoURL: URL?
    @Published var disks: [Disk] = []
    @Published var selectedDiskID: Disk.ID?
    @Published var status: Status = .idle
    @Published var bytesWritten: Int64 = 0
    @Published var isoSize: Int64 = 0

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
        guard size <= disk.size else {
            status = .failed("The ISO is larger than \(disk.name).")
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

        isoSize = size
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
        let command = [
            "/usr/sbin/diskutil unmountDisk \(disk.devicePath)",
            "/bin/dd if=\(Shell.quote(isoURL.path)) of=\(disk.rawDevicePath) bs=4m status=progress 2>\(Shell.quote(logURL.path))",
            "/usr/sbin/diskutil eject \(disk.devicePath)",
        ].joined(separator: " && ")
        let result = await Shell.run("/usr/bin/osascript", ["-e", Self.appleScript(runningAsAdmin: command)])
        monitor.cancel()

        if result.status == 0 {
            bytesWritten = size
            status = .succeeded("Your bootable USB is ready. \(disk.name) has been ejected.")
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
