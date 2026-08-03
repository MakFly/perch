import Foundation
import SQLite3
import Testing

@testable import PerchKit

/// The store is read and written from different threads at the same time, by design:
/// `UsageModel` hands it to a detached task to index while another detached task is
/// deriving the aggregates the panel shows. Whether that is safe is a property of the
/// store, not of the luck of the scheduling — and it used to be neither.
///
/// This test is the falsifier for that. Against a connection that serialises nothing it
/// does not fail: it takes the whole test process down with `SIGSEGV` or `SIGBUS` inside
/// libsqlite3, which is exactly what Perch was doing on the user's machine — four crash
/// reports in one evening, every one of them on `com.apple.root.utility-qos.cooperative`,
/// in `sqlite3_step`, `sqlite3_finalize` or `sqlite3Insert`.
///
/// Measured on 03-08-2026, macOS system SQLite 3.51.0: `sqlite3_threadsafe()` returns
/// **2** — multi-thread, *not* serialized. One connection per thread at a time is the
/// contract; sharing one without a mutex is undefined behaviour rather than a supported
/// configuration.
@Suite(.serialized)
struct SQLiteConcurrencyTests {

    /// Documents the platform fact the whole design rests on, and prints it.
    ///
    /// Named for what it asserts rather than for what was measured: `!= 0` passes on a
    /// serialized build too, deliberately, because the store no longer depends on which of
    /// the two it gets. The value is printed so that a future macOS changing it is visible
    /// in a test log instead of having to be guessed at from a crash. Measured 03-08-2026:
    /// `2` (multi-thread), SQLite 3.51.0.
    @Test func systemSQLiteIsThreadCapable() {
        // 0 = single-thread, 1 = serialized, 2 = multi-thread.
        let mode = sqlite3_threadsafe()
        print("sqlite3_threadsafe() = \(mode), version \(String(cString: sqlite3_libversion()))")
        #expect(mode != 0, "a single-thread SQLite cannot back this app at all")
    }

    /// A statement kept past the closure that lent it one is inert, not a use-after-free.
    ///
    /// `statement(_:_:)` removes the reason to do this, and cannot remove the ability: an
    /// independent review stashed one out of the closure and it compiled and ran. So the
    /// refusal lives in `Statement`, and this is what says so.
    @Test func aFinalizedStatementRefusesToTouchItsHandle() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("perch-escape-\(UUID().uuidString).sqlite").path
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }

        let database = try SQLiteDatabase(path: path)
        try database.execute("CREATE TABLE t (a INTEGER)")

        var escaped: SQLiteDatabase.Statement?
        try database.statement("INSERT INTO t (a) VALUES (?1)") { statement in
            statement.bind(1, 1)
            try statement.step()
            escaped = statement
        }

        let stowaway = try #require(escaped)
        // Every one of these would have run against freed memory before the guard existed.
        stowaway.bind(1, 2)
        stowaway.reset()
        #expect(stowaway.int(0) == 0)
        #expect(stowaway.string(0) == nil)
        #expect(throws: SQLiteDatabase.Failure.self) { try stowaway.step() }
        // And the row from before the escape is still the only one.
        var count = 0
        try database.query("SELECT COUNT(*) FROM t") { count = $0.int(0) }
        #expect(count == 1)
    }

    /// Writes and reads the same store from several threads at once, hard enough and long
    /// enough that an unguarded connection corrupts its own heap.
    ///
    /// `concurrentPerform` rather than `Task.detached`: it runs on real threads whose count
    /// is the machine's core count, so the overlap does not depend on how many threads the
    /// cooperative pool happens to have spun up.
    @Test func concurrentReadsAndWritesDoNotCorruptTheConnection() throws {
        // `concurrentPerform` runs its iterations one after another when there is only one
        // core, so on such a machine nothing here overlaps and the test proves nothing
        // while reporting green. Skipped rather than passed: a vacuous pass on a CI runner
        // is worse than a gap somebody can see.
        try #require(
            ProcessInfo.processInfo.activeProcessorCount > 1,
            "this test is vacuous on a single core")

        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("perch-concurrency-\(UUID().uuidString).sqlite").path
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }

        let store = try UsageStore(path: path)

        // Enough rows that a read is a real scan rather than a lookup that is over before
        // the writer has started.
        try store.insert((0..<2_000).map { event(index: $0, batch: -1) })

        let batches = 24
        DispatchQueue.concurrentPerform(iterations: batches) { batch in
            if batch.isMultiple(of: 2) {
                // Writer: inserts, which prepares, binds, steps and resets inside a
                // transaction. Three of the four observed crashes were on this path.
                for round in 0..<8 {
                    let events = (0..<64).map { event(index: $0, batch: batch * 1_000 + round) }
                    _ = try? store.insert(events)
                }
            } else {
                // Reader: exactly the five aggregates `UsageModel.reload()` asks for.
                for _ in 0..<8 {
                    _ = try? store.totals()
                    _ = try? store.totals(since: Date(timeIntervalSinceNow: -86_400), agent: .claude)
                    _ = try? store.buckets(.day, limit: 30, agent: nil)
                    _ = try? store.totalsByModel(since: nil, agent: nil)
                    _ = try? store.agentsWithUsage()
                }
            }
        }

        // Reaching this line at all is the result. The count is checked too, because a
        // mutex that serialised the calls but let two writers share one transaction would
        // survive the crash and still lose rows.
        let totals = try store.totals()
        #expect(totals.events == 2_000 + (batches / 2) * 8 * 64)
    }

    private func event(index: Int, batch: Int) -> UsageEvent {
        UsageEvent(
            agent: .claude,
            messageId: "msg-\(batch)-\(index)",
            requestId: "req-\(batch)-\(index)",
            timestamp: Date(timeIntervalSince1970: 1_760_000_000 + Double(index)),
            model: "claude-sonnet-4-5",
            inputTokens: 100,
            outputTokens: 50,
            cacheReadTokens: 10,
            cacheWrite5mTokens: 5,
            cacheWrite1hTokens: 1,
            sessionId: "session-\(batch)",
            cwd: "/tmp/perch-concurrency")
    }
}
