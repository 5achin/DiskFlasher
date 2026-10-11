import Foundation

/// Feeds a disk image to dd through a named pipe.
///
/// The dd started by the administrator prompt runs outside the app, so macOS privacy
/// protection stops it opening files in folders like Downloads ("Operation not permitted").
/// The app can read the image the user chose, so it reads the file itself and dd reads the pipe.
final class ImageStreamer {
    let pipeURL: URL
    private let lock = NSLock()
    private var isStopped = false

    init?(directory: URL = FileManager.default.temporaryDirectory) {
        pipeURL = directory.appendingPathComponent("DiskFlasher-\(UUID().uuidString).pipe")
        guard mkfifo(pipeURL.path, 0o600) == 0 else { return nil }
    }

    deinit {
        unlink(pipeURL.path)
    }

    /// Makes a running `stream` call return promptly.
    func stop() {
        lock.withLock { isStopped = true }
    }

    private var stopped: Bool {
        lock.withLock { isStopped }
    }

    /// Writes the whole image into the pipe, then closes it so dd sees the end of input.
    /// Blocks until finished or stopped, so call it off the main thread.
    /// - Parameters:
    ///   - blockSize: When set, the stream is padded with zeros to a multiple of this size (dd's `conv=sync`).
    ///   - skippingReadErrors: Replace unreadable parts of the image with zeros and carry on (dd's `conv=noerror,sync`).
    /// - Returns: An error message, or nil on success or when stopped.
    func stream(imageAt url: URL, paddingTo blockSize: Int64?, skippingReadErrors: Bool) -> String? {
        guard let input = try? FileHandle(forReadingFrom: url),
              let size = try? input.seekToEnd(),
              (try? input.seek(toOffset: 0)) != nil else {
            return "The disk image could not be opened."
        }
        defer { try? input.close() }

        // Opened read-write so this never blocks waiting for dd, which only starts
        // once the administrator password has been entered.
        let pipe = open(pipeURL.path, O_RDWR | O_NONBLOCK)
        guard pipe >= 0 else { return "The pipe to dd could not be opened." }
        defer { close(pipe) }

        let chunkSize = 1 << 20
        var offset: UInt64 = 0
        while offset < size, !stopped {
            let wanted = Int(min(UInt64(chunkSize), size - offset))
            var chunk: Data
            do {
                chunk = try input.read(upToCount: wanted) ?? Data()
            } catch {
                guard skippingReadErrors else {
                    return "The disk image could not be read: \(error.localizedDescription)"
                }
                chunk = Data(count: wanted)
                try? input.seek(toOffset: offset + UInt64(wanted))
            }
            if chunk.isEmpty { break }
            guard write(chunk, to: pipe) else { return nil }
            offset += UInt64(chunk.count)
        }

        if let blockSize, blockSize > 0, !stopped {
            let remainder = Int64(offset) % blockSize
            if remainder > 0 {
                _ = write(Data(count: Int(blockSize - remainder)), to: pipe)
            }
        }
        return nil
    }

    /// Writes all of `data`, waiting whenever the pipe is full. Returns false if stopped first.
    private func write(_ data: Data, to pipe: Int32) -> Bool {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            var written = 0
            while written < buffer.count {
                if stopped { return false }
                let result = Darwin.write(pipe, buffer.baseAddress! + written, buffer.count - written)
                if result > 0 {
                    written += result
                } else if result < 0, errno == EAGAIN || errno == EINTR {
                    var descriptor = pollfd(fd: pipe, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&descriptor, 1, 100)
                } else {
                    return false
                }
            }
            return true
        }
    }
}
