import Foundation
import SQLite3

/// A very small SQLite wrapper — just enough for the usage index.
///
/// System SQLite rather than a package dependency: the schema is a handful of tables,
/// and keeping the app free of external dependencies means it builds and installs
/// without a network round-trip.
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

    /// Opens the database, creating it if it does not exist.
    ///
    /// `readOnly` is for the databases Perch does not own — opencode keeps its sessions in
    /// one, and reading somebody else's store is a guest's job: no file is created, nothing
    /// is written, and the journal mode is left exactly as its owner set it. The pragmas
    /// below are configuration of *our* index, not of whatever we are being shown.
    public init(path: String, readOnly: Bool = false) throws {
        var handle: OpaquePointer?
        let flags =
            readOnly
            ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
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
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw Failure.statement("\(lastError) — while running: \(sql)")
        }
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
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

    public func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            throw Failure.statement("\(lastError) — while preparing: \(sql)")
        }
        return Statement(statement)
    }

    /// Convenience for one-shot queries.
    public func query(_ sql: String, bind: (Statement) -> Void = { _ in }, row: (Statement) -> Void)
        throws
    {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        bind(statement)
        while try statement.step() { row(statement) }
    }

    public final class Statement {
        private let handle: OpaquePointer
        /// SQLite must copy bound text: Swift string buffers do not outlive the call.
        private static let transient = unsafeBitCast(
            -1, to: sqlite3_destructor_type.self)

        init(_ handle: OpaquePointer) {
            self.handle = handle
        }

        public func bind(_ index: Int32, _ value: String?) {
            guard let value else {
                sqlite3_bind_null(handle, index)
                return
            }
            sqlite3_bind_text(handle, index, value, -1, Self.transient)
        }

        public func bind(_ index: Int32, _ value: Int) {
            sqlite3_bind_int64(handle, index, Int64(value))
        }

        public func bind(_ index: Int32, _ value: Double) {
            sqlite3_bind_double(handle, index, value)
        }

        @discardableResult
        public func step() throws -> Bool {
            let result = sqlite3_step(handle)
            switch result {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default:
                throw Failure.statement("step failed with code \(result)")
            }
        }

        public func reset() {
            sqlite3_reset(handle)
            sqlite3_clear_bindings(handle)
        }

        public func finalize() {
            sqlite3_finalize(handle)
        }

        public func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(handle, column)) }
        public func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }

        public func string(_ column: Int32) -> String? {
            guard let text = sqlite3_column_text(handle, column) else { return nil }
            return String(cString: text)
        }
    }
}
