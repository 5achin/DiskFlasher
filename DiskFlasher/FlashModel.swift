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

    /// The running dd, kept so Cancel can stop it.
    private var ddProcess: Process?
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
        // Read a byte now so any macOS prompt for access to the folder appears before the password prompt.
        guard let probe = try? FileHandle(forReadingFrom: isoURL),
              let firstByte = try? probe.read(upToCount: 1), !firstByte.isEmpty else {
            status = .failed("Disk Flasher can’t read \(isoURL.lastPathComponent). Allow access if macOS asks, or check Privacy & Security > Files & Folders in System Settings.")
            return
        }
        try? probe.close()

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

        isoSize = total
        bytesWritten = 0
        isCancelling = false
        status = .flashing
        defer { isCancelling = false }

        // Same steps as flash_iso.sh: unmount, dd to the raw device, eject.
        let unmount = await Shell.run("/usr/sbin/diskutil", ["unmountDisk", disk.devicePath])
        guard unmount.status == 0 else {
            status = .failed(unmount.errorOutput.isEmpty ? "\(disk.name) could not be unmounted." : unmount.errorOutput)
            return
        }

        let devicePath = options.outputPath(for: disk)
        let device: Int32
        do {
            device = try await Task.detached { try DeviceAuthorizer.open(devicePath) }.value
        } catch DeviceAuthorizer.Failure.cancelled {
            status = .idle
            return
        } catch DeviceAuthorizer.Failure.failed(let message) {
            status = .failed(Self.explain(message, devicePath: devicePath))
            return
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        guard !isCancelling else {
            close(device)
            status = .idle
            return
        }

        // dd's standard output is the opened drive, and /dev/fd/1 makes dd treat it as its output file.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/dd")
        process.arguments = options.operands(input: isoURL.path, output: "/dev/fd/1")
        process.standardOutput = FileHandle(fileDescriptor: device, closeOnDealloc: true)
        let errors = Pipe()
        process.standardError = errors

        let log = ProgressLog()
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let written = log.append(handle.availableData)
            Task { @MainActor in
                if let written { self?.bytesWritten = written }
            }
        }

        let exitStatus: Int32? = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
                ddProcess = process
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: nil)
            }
        }
        ddProcess = nil
        errors.fileHandleForReading.readabilityHandler = nil
        _ = log.append(errors.fileHandleForReading.availableData)

        if isCancelling {
            status = .cancelled("Flashing was cancelled. \(disk.name) is partially written and unusable until you flash it again or erase it in Disk Utility.")
        } else if exitStatus == 0 {
            bytesWritten = total
            if options.ejectWhenDone {
                let eject = await Shell.run("/usr/sbin/diskutil", ["eject", disk.devicePath])
                status = .succeeded(eject.status == 0
                    ? "Your bootable USB is ready. \(disk.name) has been ejected."
                    : "Your bootable USB is ready, but \(disk.name) could not be ejected. Eject it before unplugging it.")
            } else {
                status = .succeeded("Your bootable USB is ready. Eject \(disk.name) before unplugging it.")
            }
        } else {
            status = .failed(log.lastError.map { Self.explain($0, devicePath: devicePath) } ?? "Flashing failed.")
        }
        await refreshDisks()
    }

    /// Stops a running flash. The drive is left partially written.
    func cancel() {
        guard isFlashing else { return }
        isCancelling = true
        ddProcess?.terminate()
    }

    /// Adds what to do about it when macOS privacy protection is what refused access.
    private static func explain(_ message: String, devicePath: String) -> String {
        guard message.contains("Operation not permitted") else { return message }
        return "\(message). macOS blocked access to the drive. Allow Disk Flasher under Privacy & Security > Files & Folders > Removable Volumes in System Settings, then try again."
    }
}

/// Collects dd's standard error: `status=progress` lines and any error message.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    /// Adds output and returns the latest byte count it contains, if any.
    func append(_ data: Data) -> Int64? {
        let chunk = String(decoding: data, as: UTF8.self)
        lock.withLock { text = String((text + chunk).suffix(4096)) }
        return chunk.matches(of: /([0-9]+) bytes/).last.flatMap { Int64($0.1) }
    }

    var lastError: String? {
        lock.withLock { text }
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .last { $0.hasPrefix("dd:") }
            .map(String.init)
    }
}
