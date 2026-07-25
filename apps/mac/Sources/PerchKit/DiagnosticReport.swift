import Foundation

/// A report you can paste into a bug thread without reading it line by line first.
///
/// Everything Perch knows is either a path, a project name or a command — all three of
/// which say more about you than about the bug. So the report is assembled from facts that
/// have been scrubbed on the way in, not scrubbed afterwards: home directories become `~`,
/// project names become a stable hash, and nothing that came out of a prompt appears at
/// all.
public struct DiagnosticReport: Sendable {
    public var lines: [String] = []

    public init() {}

    public mutating func section(_ title: String) {
        lines.append("")
        lines.append("## \(title)")
    }

    public mutating func field(_ name: String, _ value: String) {
        lines.append("\(name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(value)")
    }

    public var text: String { lines.joined(separator: "\n") }

    /// `/Users/kevin/lab/thing` → `~/lab/thing`. The username is the giveaway, and it is
    /// in every path Perch handles.
    public static func scrub(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty else { return path }
        return path.replacingOccurrences(of: home, with: "~")
    }

    /// A project name is a client name often enough that it should not travel. This keeps
    /// two lines about the same project recognisably about the same project, without
    /// saying which.
    public static func anonymise(_ name: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "project-" + String(hash % 100_000, radix: 36)
    }
}
