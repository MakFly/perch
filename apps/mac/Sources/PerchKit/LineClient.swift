import Darwin
import Foundation

/// A blocking, dependency-free loopback client speaking one-JSON-object-per-line.
///
/// Deliberately built on BSD sockets rather than Network.framework: the hook binary runs
/// on every permission prompt, so process start-up cost matters more than ergonomics.
public struct LineClient {
    public enum Failure: Error {
        case socketUnavailable
        case connectFailed
        case writeFailed
        case timedOut
        case closed
    }

    private let port: UInt16
    private let timeout: TimeInterval

    public init(port: UInt16, timeout: TimeInterval) {
        self.port = port
        self.timeout = timeout
    }

    /// Sends one line and waits for one line back.
    public func roundTrip(_ line: Data) throws -> Data {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socketUnavailable }
        defer { close(fd) }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        setTimeouts(fd)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw Failure.connectFailed }

        var payload = line
        if payload.last != Wire.delimiter { payload.append(Wire.delimiter) }
        try writeAll(fd, payload)

        return try readLine(fd)
    }

    private func setTimeouts(_ fd: Int32) {
        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { throw Failure.writeFailed }
            while sent < buffer.count {
                let n = Darwin.send(fd, base.advanced(by: sent), buffer.count - sent, 0)
                if n <= 0 { throw Failure.writeFailed }
                sent += n
            }
        }
    }

    private func readLine(_ fd: Int32) throws -> Data {
        var accumulated = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.recv(fd, &chunk, chunk.count, 0)
            if n > 0 {
                accumulated.append(contentsOf: chunk[0..<n])
                if let index = accumulated.firstIndex(of: Wire.delimiter) {
                    return accumulated[accumulated.startIndex..<index]
                }
                continue
            }
            if n == 0 { throw Failure.closed }
            throw errno == EAGAIN || errno == EWOULDBLOCK ? Failure.timedOut : Failure.closed
        }
    }
}
