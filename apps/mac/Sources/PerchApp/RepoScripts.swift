import AppKit
import Foundation

/// Running the scripts the README documents, from the panel.
///
/// The behaviour lives in `scripts/`, not in Swift: one place to fix, and what happened is
/// inspectable afterwards in the files it touched. This only finds them and runs them.
///
/// **Two places, in this order.** A shipped build carries its own copy in
/// `Contents/Resources/scripts`, so an app dragged out of the DMG into `/Applications` can
/// wire up the CLIs it found — without it, the onboarding's one button was a no-op on every
/// machine that installed Perch the way people actually install things. A development build
/// falls back to the repository around it (`apps/mac/build/Perch.app`), where the scripts
/// are the originals rather than a copy and an edit takes effect without a rebuild.
///
/// Still optional, and callers still handle `nil`: a bundle assembled without the copy is a
/// valid bundle, and a button that silently does nothing is worse than no button.
enum RepoScripts {

    /// The `scripts/` directory to run from: bundled first, repository second.
    static var directory: URL? {
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("scripts", isDirectory: true)
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }

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
