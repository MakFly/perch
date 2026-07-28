import AppKit
import Foundation

/// Running the scripts the README documents, from the panel.
///
/// The behaviour lives in `scripts/`, not in Swift: one place to fix, and what happened is
/// inspectable afterwards in the files it touched. This only finds them and runs them.
///
/// **They are not always there.** The path is derived from the app bundle, which works in
/// the development layout (`apps/mac/build/Perch.app`) and not for a copy dragged out of
/// the DMG into `/Applications`. Every caller therefore has to handle `nil` — offering a
/// button that silently does nothing is worse than offering none.
enum RepoScripts {

    /// The repository's `scripts/` directory, if this build is running from inside it.
    static var directory: URL? {
        let root = Bundle.main.bundleURL
            .deletingLastPathComponent()  // build/
            .deletingLastPathComponent()  // mac/
            .deletingLastPathComponent()  // apps/
            .deletingLastPathComponent()  // repository root
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        return FileManager.default.fileExists(atPath: scripts.path) ? scripts : nil
    }

    static func url(of name: String) -> URL? {
        guard let script = directory?.appendingPathComponent(name) else { return nil }
        return FileManager.default.isExecutableFile(atPath: script.path) ? script : nil
    }

    /// Runs a script and reports whether it exited cleanly. Output is discarded: what these
    /// scripts change is on disk, and that is what the caller re-reads.
    @discardableResult
    static func run(_ name: String, _ arguments: [String] = []) -> Bool {
        guard let script = url(of: name) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// What to paste into a terminal when the script cannot be reached from here.
    static func command(for name: String) -> String {
        url(of: name).map { "\($0.path)" } ?? "./scripts/\(name)"
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
