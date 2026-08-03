import Foundation
import Testing

@testable import PerchKit

/// Builds a scratch `~/Library/Logs`-shaped directory under a temp path, deleted at the
/// end of each test — the retention and rotation logic must never be exercised against
/// the real `~/Library/Logs/Perch`.
private func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PerchLogTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Tests mirror to a subsystem of their own. `os.Logger` writes to the machine's unified
/// log whatever directory the file half is pointed at, so leaving this at the app's own
/// subsystem meant `log show --predicate 'subsystem == "tech.kweli.perch"'` returning five
/// hundred `concurrent-N` lines from the last test run — noise in exactly the place
/// somebody goes to read what the app did.
private let testSubsystem = "tech.kweli.perch.tests"

private func todayFilename() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = .current
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return "perch-\(formatter.string(from: Date())).log"
}

/// A file older than the 24-hour retention window is deleted on first use; one written
/// an hour ago is left alone. Both are given real modification times on disk — a pure
/// date-comparison helper would prove nothing about whether the purge actually runs
/// against a directory, only that subtraction works.
@Test func purgeDeletesOnlyFilesOlderThanTheRetentionWindow() {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let manager = FileManager.default
    let oldURL = directory.appendingPathComponent("perch-2020-01-01.log")
    let recentURL = directory.appendingPathComponent("perch-yesterday-ish.log")
    manager.createFile(atPath: oldURL.path, contents: Data("stale".utf8))
    manager.createFile(atPath: recentURL.path, contents: Data("fresh".utf8))

    try! manager.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-25 * 60 * 60)], ofItemAtPath: oldURL.path)
    try! manager.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-1 * 60 * 60)], ofItemAtPath: recentURL.path)

    let engine = LogEngine(directory: directory, subsystem: testSubsystem)
    engine.log(.info, "trigger the first-use purge", file: #fileID, line: #line)
    engine.waitUntilIdle()

    #expect(!manager.fileExists(atPath: oldURL.path))
    #expect(manager.fileExists(atPath: recentURL.path))
    #expect(manager.fileExists(atPath: directory.appendingPathComponent(todayFilename()).path))
}

/// Retention does not wait for something to be logged.
///
/// This is the defect an independent review found in the first version: the purge only ran
/// on a write, every call site but the launch line is a failure path, and Perch is left
/// open for weeks — so a process that ran a month without an error kept a month of logs
/// under a policy that says twenty-four hours. Nothing is logged here at all.
@Test func staleFilesArePurgedWithoutAnythingBeingLogged() {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let manager = FileManager.default
    let stale = directory.appendingPathComponent("perch-2020-01-01.log")
    manager.createFile(atPath: stale.path, contents: Data("a month of nothing".utf8))
    try! manager.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-30 * 24 * 60 * 60)],
        ofItemAtPath: stale.path)

    let engine = LogEngine(directory: directory, subsystem: testSubsystem)
    engine.waitUntilIdle()

    #expect(!manager.fileExists(atPath: stale.path))
}

/// The sweep only ever touches this logger's own files.
///
/// It runs unattended once an hour against a directory Perch does not exclusively own, and
/// `removeItem` is recursive: matching on the extension alone deleted a *directory* named
/// `archive.log` and everything inside it. Demonstrated by the same review, so it is
/// pinned here rather than argued about.
@Test func theSweepLeavesAnythingItDidNotWriteAlone() {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let manager = FileManager.default
    let bystanderDirectory = directory.appendingPathComponent("archive.log", isDirectory: true)
    try! manager.createDirectory(at: bystanderDirectory, withIntermediateDirectories: true)
    let treasure = bystanderDirectory.appendingPathComponent("kept.txt")
    manager.createFile(atPath: treasure.path, contents: Data("not ours to delete".utf8))

    // Someone else's log, old enough to be swept if the prefix were not checked.
    let foreign = directory.appendingPathComponent("someone-else-2020-01-01.log")
    manager.createFile(atPath: foreign.path, contents: Data("not ours either".utf8))

    for url in [bystanderDirectory, foreign] {
        try! manager.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-30 * 60 * 60)],
            ofItemAtPath: url.path)
    }

    let engine = LogEngine(directory: directory, subsystem: testSubsystem)
    engine.waitUntilIdle()

    #expect(manager.fileExists(atPath: treasure.path))
    #expect(manager.fileExists(atPath: foreign.path))
}

/// A line's timestamp has to be readable beside a `.ips` crash report, which macOS writes
/// in local time. UTC here would mean correlating the two through a mental offset — and a
/// reviewer of this change got that wrong by two hours, on this exact file.
/// The zone is pinned rather than read from the machine, because the first version of this
/// test asserted the timestamp was not UTC and CI runs in UTC — where a correct local
/// timestamp *is* `Z`. It went red on a runner having done nothing wrong, which is the
/// signature of a test measuring its environment instead of its subject.
@Test func linesAreTimestampedInLocalTimeLikeTheCrashReports() {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    // Nine hours off UTC and no daylight saving, so the offset is unmistakable and stable.
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let engine = LogEngine(directory: directory, timeZone: tokyo, subsystem: testSubsystem)
    engine.log(.error, "something to timestamp", file: #fileID, line: #line)

    let day = DateFormatter()
    day.dateFormat = "yyyy-MM-dd"
    day.timeZone = tokyo
    day.locale = Locale(identifier: "en_US_POSIX")
    let url = directory.appendingPathComponent("perch-\(day.string(from: Date())).log")

    let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    let stamp = String(contents.prefix(19))  // yyyy-MM-ddTHH:mm:ss

    // The assertion is on the *text*, not on the instant it denotes. Parsing the line back
    // and checking it is near `now` is what the first version of this test did, and it
    // passed against a UTC timestamp — of course it did: `2026-08-03T20:32:35Z` and
    // `2026-08-03T22:32:35+02:00` are the same moment. What has to match the crash reports
    // is the wall clock somebody reads off the line.
    let wallClock = DateFormatter()
    wallClock.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    wallClock.timeZone = tokyo
    wallClock.locale = Locale(identifier: "en_US_POSIX")

    #expect(
        stamp == wallClock.string(from: Date())
            || stamp == wallClock.string(from: Date(timeIntervalSinceNow: -1)))
    // And the offset is spelled out, so nobody has to know which zone the Mac was in. True
    // on any runner now, because the zone under test is not the runner's.
    #expect(contents.hasPrefix(stamp + "+09:00"))
    // The file the line landed in agrees with the line about which day it is.
    #expect(FileManager.default.fileExists(atPath: url.path))
}

/// A sweep that deletes the file being written to must not leave the writer writing into
/// nothing.
///
/// This is a regression the timer introduced, not an original defect: under the first
/// design the purge only ever ran *before* the handle was opened, inside `handle(for:)`,
/// so it could not race a file it was already holding. Moving it onto a timer changed what
/// it runs against. `unlink` does not invalidate an open descriptor — `write(2)` keeps
/// succeeding into an inode no path points at — so nothing fails, nothing throws, and every
/// line after the sweep is simply gone.
///
/// Reachable in production two ways: the autumn DST change makes a local day 25 hours long,
/// so a file first written at 00:10 is older than a 24-hour window at 23:30 of the *same*
/// local day, while `openDay` still matches; and any `retention` shorter than a day does it
/// on an ordinary afternoon.
///
/// Asserted on the bytes read back from the path, never on the write returning — the handle
/// is exactly what lies here.
@Test func aSweptFileDoesNotLeaveTheLoggerWritingIntoAnUnlinkedInode() throws {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    // Short enough that the file this engine has just opened is past its window before the
    // next sweep, which is the DST case in miniature.
    let engine = LogEngine(
        directory: directory, retention: 0.5, sweepInterval: 0.5, subsystem: testSubsystem)
    engine.log(.error, "before the sweep", file: #fileID, line: #line)

    let url = directory.appendingPathComponent(todayFilename())
    #expect(FileManager.default.fileExists(atPath: url.path))

    // Let the sweep run and take the open file with it.
    Thread.sleep(forTimeInterval: 1.5)

    engine.log(.error, "after the sweep", file: #fileID, line: #line)

    let onDisk = (try? String(contentsOf: url, encoding: .utf8)) ?? "<no file>"
    #expect(onDisk.contains("after the sweep"), "line went to an unlinked inode: \(onDisk)")
}

/// A log file deleted by somebody else is noticed too, not only one this sweep deleted.
///
/// The sweep drops its handle on a file it removes itself; nothing else did. But a user
/// emptying `~/Library/Logs`, a cleanup tool, or a restore produces the same unlinked
/// descriptor and the same silence — and without the app restarting or the day rolling
/// over, nothing would ever reopen. Bounded to the sweep interval, deliberately: a `stat`
/// before every line would cost more than the failure it prevents.
@Test func aLogFileDeletedByAnotherHandIsReopened() {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let engine = LogEngine(
        directory: directory, retention: 24 * 60 * 60, sweepInterval: 0.5,
        subsystem: testSubsystem)
    engine.log(.error, "before somebody else deleted it", file: #fileID, line: #line)

    let url = directory.appendingPathComponent(todayFilename())
    #expect(FileManager.default.fileExists(atPath: url.path))

    // Not the sweep: the file is well inside the retention window. Somebody else.
    try! FileManager.default.removeItem(at: url)
    Thread.sleep(forTimeInterval: 1.0)

    engine.log(.error, "after somebody else deleted it", file: #fileID, line: #line)

    let onDisk = (try? String(contentsOf: url, encoding: .utf8)) ?? "<no file>"
    #expect(onDisk.contains("after somebody else deleted it"), "still unlinked: \(onDisk)")
}

/// An error is on disk by the time the call returns, with no drain point in between.
///
/// The reason this logger was asked for is that four crashes left no record of what the
/// app was doing. A queued write does not survive the process that queued it, so the last
/// line before a fault — always an error — has to be written on the caller's thread.
/// Deliberately no `waitUntilIdle()` here: waiting is what would make this test pass
/// against an async write, which is the very thing it exists to rule out.
@Test func anErrorIsOnDiskBeforeTheCallReturns() {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let engine = LogEngine(directory: directory, subsystem: testSubsystem)
    engine.log(.error, "the last thing before the fault", file: #fileID, line: #line)

    let url = directory.appendingPathComponent(todayFilename())
    let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    #expect(contents.contains("the last thing before the fault"))
    #expect(contents.contains(" [ERROR] "))
}

/// Many threads logging at once must produce exactly one well-formed line per call,
/// none interleaved and none lost — the property the serial queue exists to guarantee.
@Test func concurrentWritesProduceOneLinePerCallWithNoInterleaving() {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let engine = LogEngine(directory: directory, subsystem: testSubsystem)
    let count = 500

    DispatchQueue.concurrentPerform(iterations: count) { index in
        engine.log(.info, "concurrent-\(index)", file: #fileID, line: #line)
    }
    engine.waitUntilIdle()

    let url = directory.appendingPathComponent(todayFilename())
    let contents = try! String(contentsOf: url, encoding: .utf8)
    let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)

    #expect(lines.count == count)

    var seenIndices = Set<Int>()
    for line in lines {
        // A well-formed line: an ISO8601 timestamp, the level, the call site, then the
        // message — corruption from interleaved writes would show up as a line missing
        // one of these or carrying fragments of two.
        #expect(line.contains(" [INFO] "))
        guard
            let marker = line.range(of: "concurrent-"),
            let index = Int(line[marker.upperBound...])
        else {
            Issue.record("line is not well-formed: \(line)")
            continue
        }
        seenIndices.insert(index)
    }
    #expect(seenIndices.count == count)
}
