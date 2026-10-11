import Foundation

/// The dd operands the app exposes. Defaults match flash_iso.sh: `bs=4m` to the raw device, then eject.
struct FlashOptions: Equatable {
    enum BlockSize: String, CaseIterable, Identifiable {
        case k512 = "512k", m1 = "1m", m2 = "2m", m4 = "4m", m8 = "8m", m16 = "16m", m32 = "32m"

        var id: String { rawValue }

        var bytes: Int64 {
            switch self {
            case .k512: 512 * 1024
            case .m1: 1 << 20
            case .m2: 2 << 20
            case .m4: 4 << 20
            case .m8: 8 << 20
            case .m16: 16 << 20
            case .m32: 32 << 20
            }
        }

        var label: String {
            self == .k512 ? "512 KB" : "\(bytes >> 20) MB"
        }
    }

    var blockSize: BlockSize = .m4
    /// Write to /dev/rdiskN (unbuffered, much faster) rather than /dev/diskN.
    var useRawDevice = true
    /// conv=sync
    var padBlocks = false
    /// conv=noerror
    var continueOnReadErrors = false
    /// conv=fsync
    var flushBeforeFinishing = false
    /// oflag=sync
    var synchronousWrites = false
    /// oflag=direct
    var bypassCache = false
    /// count=n, in blocks
    var count: Int?
    /// skip=n, in blocks
    var skip: Int?
    /// seek=n, in blocks
    var seek: Int?
    /// speed=n, entered in MB per second
    var speedLimit: Int?
    /// Not a dd operand: run `diskutil eject` after a successful flash.
    var ejectWhenDone = true

    func outputPath(for disk: Disk) -> String {
        useRawDevice ? disk.rawDevicePath : disk.devicePath
    }

    /// The flags the drive is opened with. Synchronous writes are requested here because dd
    /// can't switch them on for a drive that is already open.
    var openFlags: Int32 {
        synchronousWrites ? O_RDWR | O_SYNC : O_RDWR
    }

    /// The dd operands in the order they are passed. There is no `of=`: dd writes to its
    /// standard output, which the app sets to the already opened drive.
    func operands(input: String) -> [String] {
        var operands = ["if=\(input)", "bs=\(blockSize.rawValue)"]
        if let count = positive(count) { operands.append("count=\(count)") }
        if let skip = positive(skip) { operands.append("skip=\(skip)") }
        if let seek = positive(seek) { operands.append("seek=\(seek)") }
        if let speedLimit = positive(speedLimit) { operands.append("speed=\(Int64(speedLimit) << 20)") }

        if bypassCache { operands.append("oflag=direct") }

        var conv: [String] = []
        if padBlocks { conv.append("sync") }
        if continueOnReadErrors { conv.append("noerror") }
        if flushBeforeFinishing { conv.append("fsync") }
        if !conv.isEmpty { operands.append("conv=\(conv.joined(separator: ","))") }

        operands.append("status=progress")
        return operands
    }

    /// How many bytes dd will write from an image of the given size, after padding, skip and count.
    func bytesToCopy(inputSize: Int64) -> Int64 {
        var streamed = inputSize
        if padBlocks, streamed % blockSize.bytes > 0 {
            streamed += blockSize.bytes - streamed % blockSize.bytes
        }
        var bytes = max(streamed - Int64(positive(skip) ?? 0) * blockSize.bytes, 0)
        if let count = positive(count) {
            bytes = min(bytes, Int64(count) * blockSize.bytes)
        }
        return bytes
    }

    /// The offset on the drive just past the last byte dd will write.
    func endOffset(inputSize: Int64) -> Int64 {
        Int64(positive(seek) ?? 0) * blockSize.bytes + bytesToCopy(inputSize: inputSize)
    }

    private func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }
}
