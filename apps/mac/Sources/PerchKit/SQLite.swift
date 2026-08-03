import Foundation
import SQLite3

/// A very small SQLite wrapper — just enough for the usage index.
///
/// System SQLite rather than a package dependency: the schema is a handful of tables,
/// and keeping the app free of external dependencies means it builds and installs
/// without a network round-trip.
///
/// **One connection, one thread at a time — enforced here.** The store is handed to
/// detached tasks that index and aggregate at the same time, so this connection genuinely
/// is shared across threads. That used to rely on the system SQLite being built serialized;
/// it is not. Measured on 03-08-2026 against macOS's SQLite 3.51.0, `sqlite3_threadsafe()`
/// returns **2** — multi-thread, meaning the library takes no mutex on the connection and
/// two threads inside it corrupt its heap. It did: four crashes in one evening, `SIGSEGV`
/// and `SIGBUS` in `sqlite3_step`, `sqlite3_finalize` and `sqlite3Insert`, always from the
/// cooperative pool.
///
/// Both guards below are load-bearing, and for different failures — measured by ablating
/// them independently against `SQLiteConcurrencyTests`, rather than assumed:
///
/// | lock | FULLMUTEX | outcome                                              |
/// |------|-----------|------------------------------------------------------|
/// |  ✗   |     ✗     | `SIGSEGV`, 3 runs of 3 — the shipped bug              |
/// |  ✗   |     ✓     | no crash, and **2 512 of 8 144 rows silently lost**   |
/// |  ✓   |     ✗     | passes                                               |
/// |  ✓   |     ✓     | passes — what ships                                  |
///
/// So `FULLMUTEX` alone is enough to stop the *memory corruption*: it is not the second
/// line of defence this comment first claimed it was. What the lock adds is the thing a
/// per-call mutex cannot give — a `BEGIN` from another thread cannot land inside this
/// thread's transaction, and `changes()` still describes the statement that just ran. The
/// row loss in the second line is what that costs when only the mutex is there.
///
/// The cost of the lock is that a long write
/// blocks a read on the same connection — WAL cannot help, there being only one connection
/// to be concurrent with. Accepted: the batches are one transcript file's worth and the
/// aggregates are milliseconds. Splitting reads and writes onto two connections is the
/// answer if that ever stops being true, and it has to come with its own falsifying test.
public final class SQLiteDatabase {
    public enum Failure: Error, CustomStringConvertible {
        case open(String)
        case statement(String)

        public var description: String {
            switch self {
            case .open(let message): return "sqlite open failed: \(message)"
            case .statement(let message): return "sqlite error: \(message)"
            }
        }
    }

    private var handle: OpaquePointer?

    /// Recursive because `transaction` holds it across a body that calls back in through
    /// `statement`, `execute` and `query` — a plain mutex would deadlock on the first
    /// insert. Recursion here is the API being usable, not a shortcut around a design.
    private let lock = NSRecursiveLock()

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Opens the database, creating it if it does not exist.
    ///
    /// `readOnly` is for the databases Perch does not own — opencode keeps its sessions in
    /// one, and reading somebody else's store is a guest's job: no file is created, nothing
    /// is written, and the journal mode is left exactly as its owner set it. The pragmas
    /// below are configuration of *our* index, not of whatever we are being shown.
    public init(path: String, readOnly: Bool = false) throws {
        var handle: OpaquePointer?
        // FULLMUTEX asks SQLite for its own per-connection mutex. It is not what makes this
        // class safe — the lock above is — but with a library compiled `SQLITE_THREADSAFE=2`
        // this flag is the only thing that turns that mutex on, and leaving it off is what
        // let the old design fail silently for as long as it did.
        let flags =
            (readOnly
            ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
            | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw Failure.open(message)
        }
        self.handle = handle
        guard !readOnly else { return }
        // WAL keeps the indexer's writes from blocking the UI's reads.
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
    }

    deinit {
        sqlite3_close(handle)
    }

    private var lastError: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
    }

    public func execute(_ sql: String) throws {
        try withLock {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw Failure.statement("\(lastError) — while running: \(sql)")
            }
        }
    }

    /// Runs `body` as one unit: BEGIN, the work, COMMIT — with no other thread able to
    /// reach this connection in between.
    ///
    /// The lock is as much about correctness as about memory. A transaction is per
    /// *connection*, not per thread, so even a connection SQLite was mutexing for us would
    /// let a second thread's `BEGIN` land inside this one's, and its statements commit with
    /// ours or roll back with our failure. There is one connection, so serialising the
    /// whole body is the only shape of this that means anything.
    ///
    /// `body` runs holding the lock, so it must not block on anything that could be waiting
    /// on this connection — a `DispatchQueue.main.sync`, or an `await` on the main actor
    /// while a main-actor caller is queued behind this lock, would deadlock. Every body in
    /// the tree today is straight-line SQL, which is the only kind that is safe here.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try withLock {
            try execute("BEGIN")
            do {
                let result = try body()
                try execute("COMMIT")
                return result
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    /// Prepares a statement and hands it to `body`, holding the connection for as long as
    /// `body` uses it, then finalizes it.
    ///
    /// Scoped rather than returned on purpose. A `prepare` that hands a live statement back
    /// to the caller hands out a pointer into this connection with no lock attached to it,
    /// which is precisely how binds and steps ended up running on two threads at once.
    ///
    /// It removes the *reason* to hold a statement past the closure; it does not make it
    /// impossible. `Statement` is a class, and a caller can still assign it out — proven,
    /// not assumed. So the guarantee is enforced in `Statement` itself, which refuses to
    /// touch a handle it has already finalized rather than trusting this paragraph. The
    /// previous version of this file explained at length why a race could not happen, and
    /// was believed for months; a comment is not a mechanism.
    public func statement<T>(_ sql: String, _ body: (Statement) throws -> T) throws -> T {
        try withLock {
            let statement = try prepare(sql)
            defer { statement.finalize() }
            return try body(statement)
        }
    }

    /// Caller must hold the lock.
    private func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            throw Failure.statement("\(lastError) — while preparing: \(sql)")
        }
        return Statement(statement)
    }

    /// Convenience for one-shot queries. The whole walk is one critical section: a `row`
    /// callback runs while this thread still owns the connection, so reading a column is
    /// as protected as stepping to it.
    public func query(_ sql: String, bind: (Statement) -> Void = { _ in }, row: (Statement) -> Void)
        throws
    {
        try withLock {
            let statement = try prepare(sql)
            defer { statement.finalize() }
            bind(statement)
            while try statement.step() { row(statement) }
        }
    }

    public final class Statement {
        private let handle: OpaquePointer
        /// A finalized statement's handle is freed memory. Every method below returns
        /// instead of touching it, so a caller that kept a reference past the closure that
        /// lent it one gets nothing back rather than a use-after-free — one branch, in
        /// exchange for the worst outcome this class can produce.
        private var isFinalized = false
        /// SQLite must copy bound text: Swift string buffers do not outlive the call.
        private static let transient = unsafeBitCast(
            -1, to: sqlite3_destructor_type.self)

        init(_ handle: OpaquePointer) {
            self.handle = handle
        }

        public func bind(_ index: Int32, _ value: String?) {
            guard !isFinalized else { return }
            guard let value else {
                sqlite3_bind_null(handle, index)
                return
            }
            sqlite3_bind_text(handle, index, value, -1, Self.transient)
        }

        public func bind(_ index: Int32, _ value: Int) {
            guard !isFinalized else { return }
            sqlite3_bind_int64(handle, index, Int64(value))
        }

        public func bind(_ index: Int32, _ value: Double) {
            guard !isFinalized else { return }
            sqlite3_bind_double(handle, index, value)
        }

        @discardableResult
        public func step() throws -> Bool {
            // Throwing rather than returning false: a caller stepping a finalized
            // statement is asking for rows that will never come, and answering "no more
            // rows" would let it finish successfully having read nothing.
            guard !isFinalized else {
                throw Failure.statement("step on a statement that was already finalized")
            }
            let result = sqlite3_step(handle)
            switch result {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default:
                throw Failure.statement("step failed with code \(result)")
            }
        }

        public func reset() {
            guard !isFinalized else { return }
            sqlite3_reset(handle)
            sqlite3_clear_bindings(handle)
        }

        public func finalize() {
            // Idempotent: finalizing twice would be a double free, and this is called from
            // a `defer` that a caller could also have reached by hand.
            guard !isFinalized else { return }
            isFinalized = true
            sqlite3_finalize(handle)
        }

        public func int(_ column: Int32) -> Int {
            guard !isFinalized else { return 0 }
            return Int(sqlite3_column_int64(handle, column))
        }

        public func double(_ column: Int32) -> Double {
            guard !isFinalized else { return 0 }
            return sqlite3_column_double(handle, column)
        }

        public func string(_ column: Int32) -> String? {
            guard !isFinalized, let text = sqlite3_column_text(handle, column) else { return nil }
            return String(cString: text)
        }
    }
}
