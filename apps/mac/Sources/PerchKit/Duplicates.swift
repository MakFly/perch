import Foundation

/// Recognises the same hook event arriving twice.
///
/// Claude Code merges the hook settings of every scope it reads and runs all of them, so a
/// project install sitting on top of a global one fires both copies for one event: two
/// rows in the feed, two sounds, and — for `PermissionRequest` — two blocked sessions
/// waiting on what is really one decision.
///
/// `install-hooks.sh` refuses to create that overlap now, but a settings file is something
/// several tools write to, and Perch cannot be the only thing standing between a
/// hand-edited one and a panel that shows everything twice.
public struct DuplicateFilter: Sendable {
    /// Both copies are spawned by the same Claude Code invocation, so they arrive
    /// milliseconds apart. Two seconds is generous for that, and short enough that a tool
    /// you genuinely ran twice in a row still gets its own row.
    public var window: TimeInterval
    private var seen: [String: Date] = [:]

    public init(window: TimeInterval = 2) {
        self.window = window
    }

    /// True the first time a key is seen, false while a copy of it is still inside the
    /// window.
    ///
    /// A repeat does not extend the window: a key that keeps arriving is admitted again
    /// once its first sighting ages out, so a mis-detection costs one dropped row rather
    /// than a session that goes quiet for good.
    public mutating func admit(_ key: String, at now: Date = .now) -> Bool {
        seen = seen.filter { now.timeIntervalSince($0.value) < window }
        guard seen[key] == nil else { return false }
        seen[key] = now
        return true
    }
}

extension PerchRequest {
    /// Identifies one Claude Code event, so that a second copy of it can be recognised.
    ///
    /// Keyed on the payload Claude Code sent, never on the wrapper Perch adds around it:
    /// two hook entries for the same event differ by their `--source` flag and by the
    /// process that ran them, while the payload they were both handed is byte-identical —
    /// which is exactly what makes a duplicate a duplicate.
    ///
    /// `nil` when there is nothing to key on: an unparseable payload has no fingerprint of
    /// its own, and treating every one of those as the same event would drop real rows.
    public var duplicateKey: String? {
        guard raw != nil || payload.sessionId != nil else { return nil }

        let encoder = JSONEncoder()
        // Sorted, so two encodings of the same object cannot differ by key order alone.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded: Data? = raw.flatMap { try? encoder.encode($0) }
            ?? (try? encoder.encode(payload))
        guard let encoded else { return nil }

        return "\(event):\(Self.fingerprint(encoded))"
    }

    /// FNV-1a. Not a security property — the key never leaves the process, and a collision
    /// would cost one row in a feed — so a few lines beat pulling in a hash framework.
    private static func fingerprint(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 36)
    }
}
