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

    /// Starts a script and does not wait for it.
    ///
    /// For the one script that outlives the app: `uninstall.sh` quits Perch and then
    /// deletes the bundle, so waiting for it would mean waiting from inside a process it
    /// is about to kill. Detached, the shell keeps running after Perch is gone.
    @discardableResult
    static func start(_ script: URL, _ arguments: [String] = [], log: URL? = nil) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        if let log, FileManager.default.createFile(atPath: log.path, contents: nil),
            let handle = try? FileHandle(forWritingTo: log)
        {
            // Kept, because this is the one action whose output nobody will be around to
            // read: by the time it matters, the window that started it is gone.
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    /// Where the uninstaller is kept so that it survives the app.
    static var stashedUninstaller: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".perch/uninstall.sh")
    }

    /// Copies the uninstaller out of the bundle, next to everything else Perch put on this
    /// machine.
    ///
    /// Dragging an app to the Trash is how people uninstall things, and it takes the
    /// uninstaller with it — leaving fourteen hook entries pointing at a binary that is no
    /// longer there and no obvious way to find that out. A copy outside the bundle is the
    /// difference between "run this" and "edit these files by hand".
    ///
    /// Refreshed on every launch rather than written once: a copy that describes a version
    /// of Perch you no longer have is worse than the one it replaced.
    @discardableResult
    static func stashUninstaller() -> Bool {
        guard let source = url(of: "uninstall.sh") else { return false }
        let destination = stashedUninstaller
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

            // Where this copy came from. The script guesses at `/Applications` and at a
            // repository around itself, and neither guess finds a bundle that was dragged
            // somewhere else — or a development build, once the copy is no longer next to
            // it. The app knows its own path; writing it down is cheaper than guessing.
            let note = destination.deletingLastPathComponent()
                .appendingPathComponent("app-path")
            let path = Bundle.main.bundleURL.path + "\n"
            if (try? String(contentsOf: note, encoding: .utf8)) != path {
                try path.write(to: note, atomically: true, encoding: .utf8)
            }

            let script = try Data(contentsOf: source)
            // Compared before writing: this runs at every launch, and rewriting an
            // identical file is a modification date that means nothing.
            if (try? Data(contentsOf: destination)) != script {
                try script.write(to: destination, options: .atomic)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: destination.path)
            return true
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
