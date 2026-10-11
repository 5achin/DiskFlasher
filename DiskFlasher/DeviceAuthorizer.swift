import Foundation

/// Opens a disk device for writing using macOS's `authopen`, which shows the standard
/// administrator prompt and hands the open file descriptor back to the app.
///
/// dd then runs as an ordinary child of the app and writes to that descriptor, so it needs
/// no root shell and macOS attributes its file and drive access to Disk Flasher.
enum DeviceAuthorizer {
    enum Failure: Error {
        case cancelled
        case failed(String)
    }

    static var toolPath = "/usr/libexec/authopen"

    /// Blocks until the user answers the prompt, so call it off the main thread.
    static func open(_ path: String, flags: Int32 = O_RDWR) throws -> Int32 {
        var sockets: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw Failure.failed("The drive could not be opened.")
        }
        defer { close(sockets[0]) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = ["-stdoutpipe", "-o", String(flags), path]
        process.standardOutput = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: false)
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
        } catch {
            close(sockets[1])
            throw Failure.failed(error.localizedDescription)
        }
        close(sockets[1])

        let descriptor = receiveDescriptor(from: sockets[0])
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if let descriptor { return descriptor }
        let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if message.localizedCaseInsensitiveContains("cancel") || message.contains("-60006") {
            throw Failure.cancelled
        }
        throw Failure.failed(message.isEmpty ? "Administrator access was not granted." : message)
    }

    /// Receives one file descriptor sent with SCM_RIGHTS.
    private static func receiveDescriptor(from socket: Int32) -> Int32? {
        var payload = [UInt8](repeating: 0, count: 64)
        var control = [UInt8](repeating: 0, count: 64)
        return payload.withUnsafeMutableBytes { payloadBuffer in
            control.withUnsafeMutableBytes { controlBuffer -> Int32? in
                var vector = iovec(iov_base: payloadBuffer.baseAddress, iov_len: payloadBuffer.count)
                return withUnsafeMutablePointer(to: &vector) { vectorPointer -> Int32? in
                    var message = msghdr()
                    message.msg_iov = vectorPointer
                    message.msg_iovlen = 1
                    message.msg_control = controlBuffer.baseAddress
                    message.msg_controllen = socklen_t(controlBuffer.count)
                    guard recvmsg(socket, &message, 0) >= 0,
                          Int(message.msg_controllen) >= MemoryLayout<cmsghdr>.size + MemoryLayout<Int32>.size else {
                        return nil
                    }
                    let header = controlBuffer.loadUnaligned(as: cmsghdr.self)
                    guard header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS else { return nil }
                    return controlBuffer.loadUnaligned(fromByteOffset: MemoryLayout<cmsghdr>.size, as: Int32.self)
                }
            }
        }
    }
}
