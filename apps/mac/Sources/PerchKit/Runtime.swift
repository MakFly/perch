import Foundation

/// Handshake file the app writes on launch and the hook reads on every invocation.
///
/// Kept in `~/.perch/runtime.json` with mode 0600: the token is what stops any other
/// local process from approving tool calls on your behalf.
public struct RuntimeInfo: Codable, Sendable {
    public var port: UInt16
    public var token: String
    public var pid: Int32
    public var version: Int

    public init(port: UInt16, token: String, pid: Int32) {
        self.port = port
        self.token = token
        self.pid = pid
        self.version = Wire.protocolVersion
    }

    public static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".perch", isDirectory: true)
    }

    public static var url: URL {
        directory.appendingPathComponent("runtime.json")
    }

    /// Nil when the handshake belongs to a process that is gone.
    ///
    /// A crash, a force-quit, or an update that swapped the bundle underneath it all leave
    /// a file pointing at a port nobody is listening on. Without this check every hook and
    /// every CLI call dials that port and waits out its timeout — which is exactly the
    /// stall this is meant to prevent.
    public static func load() -> RuntimeInfo? {
        guard let data = try? Data(contentsOf: url),
            let info = try? JSONDecoder().decode(RuntimeInfo.self, from: data),
            info.isAlive
        else { return nil }
        return info
    }

    /// `kill(pid, 0)` asks the kernel whether the process exists without touching it.
    /// `ESRCH` means gone; `EPERM` means it exists and belongs to someone else, which for
    /// our purposes still counts as alive.
    public var isAlive: Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// True when another live instance already owns the handshake.
    ///
    /// A second copy launched by accident would otherwise overwrite the port and token of
    /// the one actually holding the notch, and every hook would start talking to it.
    public static func isClaimedByAnotherProcess() -> Bool {
        guard let data = try? Data(contentsOf: url),
            let info = try? JSONDecoder().decode(RuntimeInfo.self, from: data)
        else { return false }
        return info.isAlive && info.pid != ProcessInfo.processInfo.processIdentifier
    }

    public func write() throws {
        try FileManager.default.createDirectory(
            at: Self.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
    }

    public static func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// `SystemRandomNumberGenerator` is the platform CSPRNG, so this is fine for a
    /// loopback bearer token and keeps the target free of extra imports.
    public static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32)
            .map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }
            .joined()
    }
}
