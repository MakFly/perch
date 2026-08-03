import Foundation
import os

/// Durable, on-disk log for Perch.
///
/// Before this file existed the app spoke only through a handful of scattered `NSLog`
/// calls, which land in the unified log and scroll out of `log show`'s default window
/// within hours. After four crashes in one evening left no record of what the app had
/// been doing, every call site moved here: one file per day under the standard user log
/// location, so Console.app and Finder's Go to Folder both find it without being told
/// where to look, plus a live mirror to `os.Logger` for anyone already watching Console.
public enum PerchLog {
    public enum Level: String, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case error = "ERROR"
    }

    /// NEVER pass secret material here. The only credential Perch holds is the bearer
    /// token in `~/.perch/runtime.json` (see `RuntimeInfo`/`EventServer`) — a log line
    /// that included it would turn a debugging aid into a second place that leaks the
    /// thing the token exists to protect. Log that a request was rejected, not what it
    /// carried.
    public static func debug(_ message: String, file: String = #fileID, line: Int = #line) {
        engine.log(.debug, message, file: file, line: line)
    }

    public static func info(_ message: String, file: String = #fileID, line: Int = #line) {
        engine.log(.info, message, file: file, line: line)
    }

    public static func error(_ message: String, file: String = #fileID, line: Int = #line) {
        engine.log(.error, message, file: file, line: line)
    }

    /// Blocks until everything logged so far is on disk.
    ///
    /// For the way out, and for tests. `info` and `debug` return before their line is
    /// written, which is right while the app is running and wrong at the moment it stops:
    /// the process can exit with the last lines still on the queue, and "Perch is quitting"
    /// is precisely the line whose absence is supposed to mean a crash. Anywhere else,
    /// calling this is asking the app to wait on a disk.
    public static func flush() {
        engine.waitUntilIdle()
    }

    static let engine = LogEngine()
}

/// Not `private`: `PerchKitTests` builds its own instance against a temp directory so
/// tests never touch the real `~/Library/Logs/Perch`.
///
/// `@unchecked Sendable`: every stored property below is either immutable or touched
/// only from `queue`, which is what actually makes concurrent `log()` calls safe — the
/// queue serializes the file append, so two threads logging at once cannot interleave
/// or lose a line the way a raw `FileHandle` shared across threads could.
final class LogEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tech.kweli.perch.log")
    private let directory: URL
    private let retention: TimeInterval
    private let oslog: Logger

    // Neither formatter is documented thread-safe; both are touched only from `queue`,
    // alongside the rest of the file-handling state below.
    //
    /// Local time with an offset, not UTC.
    ///
    /// The default `ISO8601DateFormatter` writes `Z`, and this file exists to be read
    /// beside two artefacts that are both in local time: the day in its own filename, and
    /// the `.ips` crash reports in `~/Library/Logs/DiagnosticReports`. A reviewer of this
    /// change lost real time deciding whether a 20:53 crash came before or after a 20:33
    /// log line, because the two were two hours apart in the wrong direction. Correlating
    /// a crash with what the app was doing is the only job this file has.
    private let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()
    private let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private var handle: FileHandle?
    private var openDay: String?
    /// The path `handle` was opened on, so the sweep can recognise its own writer's file
    /// rather than reconstructing the name and hoping the two conventions stay in step.
    private var openURL: URL?
    private var directoryReady = false
    /// Held so it is not deallocated the moment `init` returns — a `DispatchSourceTimer`
    /// that nobody keeps stops firing, silently.
    private var sweeper: DispatchSourceTimer?

    static let defaultDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/Perch", isDirectory: true)

    init(
        directory: URL = LogEngine.defaultDirectory,
        retention: TimeInterval = 24 * 60 * 60,
        sweepInterval: TimeInterval = 60 * 60,
        subsystem: String = "tech.kweli.perch",
        category: String = "app"
    ) {
        self.directory = directory
        self.retention = retention
        self.oslog = Logger(subsystem: subsystem, category: category)
        startSweeping(every: sweepInterval)
    }

    /// Deletes what is past its window now, and keeps doing so on a timer.
    ///
    /// The obvious place to purge is "on the first write of a new day", and that is what
    /// this did first — but it made the retention a promise the code could not keep. Every
    /// call site but the launch line is on a failure path, and Perch is an app left open
    /// for weeks: a process that runs for a month without an error never writes, so it
    /// never purges, and a month-old file stays on disk under a policy that says 24 hours.
    /// The day-rollover trigger was wrong a second way — yesterday's file has a fresh mtime
    /// at midnight, so it survives that sweep and is only reconsidered at the next one,
    /// which stretched a 24-hour window to nearly 48.
    ///
    /// A timer on the same serial queue answers both, and costs one directory listing an
    /// hour whether or not anything is being logged. That is the granularity of the
    /// promise: nothing survives more than `retention` plus one sweep.
    private func startSweeping(every interval: TimeInterval) {
        // The first sweep is an ordinary block on the queue rather than the timer's first
        // fire: enqueued here, it is guaranteed to run before anything submitted after
        // `init` returns, which is what lets a test observe it with a plain drain instead
        // of sleeping and hoping.
        queue.async { [weak self] in self?.purgeOldFiles() }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(60))
        timer.setEventHandler { [weak self] in self?.purgeOldFiles() }
        timer.resume()
        sweeper = timer
    }

    func log(_ level: PerchLog.Level, _ message: String, file: String, line: Int) {
        mirror(level, message)

        // The timestamp is captured here, not when the write finally runs on `queue`,
        // so log lines stay ordered by when the caller actually logged rather than by
        // scheduling jitter on a queue under load.
        let now = Date()

        // Errors are written synchronously; everything else is fire-and-forget.
        //
        // This logger exists because four crashes left no record, and a queued write does
        // not survive the process that queued it: the line explaining what went wrong just
        // before a `SIGSEGV` is exactly the line an async append loses. Errors are rare —
        // seven call sites, all of them failure paths — so paying for the write on the
        // caller's thread costs nothing anyone can perceive, and buys the one line that
        // matters. The unified log keeps its own copy either way, but only the file is
        // where this app promised to put it.
        guard level != .error else {
            queue.sync { append(level: level, message: message, file: file, line: line, at: now) }
            return
        }

        queue.async { [weak self] in
            self?.append(level: level, message: message, file: file, line: line, at: now)
        }
    }

    /// Blocks until every write queued before this call has landed on disk. Reached
    /// through `PerchLog.flush()` on the way out, and directly by tests: `log()` is
    /// fire-and-forget by design, so assertions on file contents need a drain point.
    func waitUntilIdle() {
        queue.sync {}
    }

    private func mirror(_ level: PerchLog.Level, _ message: String) {
        switch level {
        case .debug: oslog.debug("\(message, privacy: .public)")
        case .info: oslog.info("\(message, privacy: .public)")
        case .error: oslog.error("\(message, privacy: .public)")
        }
    }

    // MARK: - Disk writes — everything below runs on `queue`

    private func append(level: PerchLog.Level, message: String, file: String, line: Int, at date: Date) {
        guard let fileHandle = handle(for: date) else { return }
        let logLine = "\(timestamp.string(from: date)) [\(level.rawValue)] \(file):\(line) \(message)\n"
        guard let data = logLine.data(using: .utf8) else { return }
        // A logger that throws into its caller is worse than one that silently drops a
        // line: `try?` is deliberate here, not an oversight.
        try? fileHandle.write(contentsOf: data)
    }

    private func handle(for date: Date) -> FileHandle? {
        ensureDirectory()
        let today = day.string(from: date)

        if openDay == today, let handle { return handle }
        closeOpenFile()

        let url = directory.appendingPathComponent("perch-\(today).log")
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: url) else { return nil }
        opened.seekToEndOfFile()
        handle = opened
        openDay = today
        openURL = url
        return opened
    }

    private func closeOpenFile() {
        handle?.closeFile()
        handle = nil
        openDay = nil
        openURL = nil
    }

    private func ensureDirectory() {
        guard !directoryReady else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directoryReady = true
    }

    /// 24-hour retention. This was an explicit user decision over a longer
    /// default — a crash log is only useful for reconstructing the evening it happened
    /// in, and Console.app already retains everything mirrored via `os.Logger` for
    /// whoever needs more history.
    private func purgeOldFiles() {
        let manager = FileManager.default

        // This sweep now knows to drop the handle on a file it deletes itself, but it is
        // not the only thing that can delete one: a user clearing ~/Library/Logs, a cleanup
        // tool, a restore. The symptom is the same and just as quiet — writes keep
        // succeeding into an unlinked inode until the day rolls over. Checked here rather
        // than per line: once an hour is free, and a `stat` before every write is not.
        if let openURL, !manager.fileExists(atPath: openURL.path) { closeOpenFile() }

        guard
            let entries = try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
        else { return }

        let cutoff = Date().addingTimeInterval(-retention)
        // Only this logger's own files. `removeItem` is recursive, so an extension match
        // alone would delete a *directory* called `something.log` and everything under it —
        // demonstrated, not imagined. Requiring the `perch-` prefix and a regular file
        // keeps a sweep that runs unattended every hour from reaching anything it did not
        // write. A symlink is not a regular file, so it is left alone too, target included.
        for url in entries
        where url.pathExtension == "log" && url.lastPathComponent.hasPrefix("perch-") {
            guard
                let values = try? url.resourceValues(forKeys: [
                    .contentModificationDateKey, .isRegularFileKey,
                ]),
                values.isRegularFile == true,
                let modified = values.contentModificationDate,
                modified < cutoff
            else { continue }

            // Deleting the file this engine is holding open would not fail, and that is the
            // danger: `unlink` leaves the descriptor valid, so every later `write` succeeds
            // into an inode no path points at and the lines are gone without a symptom. The
            // handle is dropped first, so the next line reopens the path and lands somewhere
            // readable.
            //
            // Reachable: the autumn DST change makes a local day 25 hours long, so a file
            // first written at 00:10 is past a 24-hour window at 23:30 of the same local
            // day while `openDay` still matches. This sweep runs unattended every hour and
            // did not exist before the retention fix — the purge used to run only inside
            // `handle(for:)`, before the file was open, where it could not race it.
            // Compared by name, not by `URL` equality: `contentsOfDirectory(at:)` hands back
            // paths with every symlink resolved, so a directory reached through one yields
            // `/private/var/…` against a constructed `/var/…` and `==` is false for the same
            // file. That is not hypothetical — it is how the first version of this guard
            // failed, silently, with the test still red. Both sides are entries of
            // `directory`, so the last component identifies them.
            if url.lastPathComponent == openURL?.lastPathComponent { closeOpenFile() }
            try? manager.removeItem(at: url)
        }
    }
}
