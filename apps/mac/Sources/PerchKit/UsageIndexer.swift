import Foundation

/// Reads agent transcripts into the usage store, resuming where it left off.
///
/// Three shapes. Claude Code writes a conversation whose assistant lines carry their own
/// usage; Codex writes a typed event stream where the counters arrive on a line of their own
/// and the model belongs to the line before it. Which parser a file gets is decided by the
/// root it was found under — the two never mix, and a rollout that wandered into `~/.claude`
/// would be skipped rather than misread.
///
/// opencode writes no transcript at all: its sessions live in a SQLite database, so it is
/// read by `OpencodeUsage` and resumed by a timestamp rather than by a byte offset.
public struct UsageIndexer {
    public struct Progress: Sendable {
        public var filesScanned = 0
        public var eventsInserted = 0
        public var bytesRead = 0

        public init() {}
    }

    /// Which agent wrote a store, and therefore how to read what is in it.
    ///
    /// The same vocabulary the index is keyed on: two enumerations with identical cases,
    /// each having to be kept in step with the other, is a bug waiting for the fourth agent.
    public typealias Source = UsageStore.Agent

    private let store: UsageStore
    private let roots: [(url: URL, source: Source)]
    /// opencode's database, or nil when this indexer is pointed at a directory for a test.
    private let opencodeDatabase: URL?
    /// Chunk size for tailing. Transcripts reach hundreds of megabytes, so the file is
    /// streamed rather than read whole.
    private let chunkSize = 4 * 1024 * 1024

    public static var claudeRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public static var codexRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    public init(
        store: UsageStore,
        roots: [(url: URL, source: Source)]? = nil,
        opencodeDatabase: URL? = OpencodeUsage.defaultDatabaseURL
    ) {
        self.store = store
        self.roots = roots ?? [(Self.claudeRoot, .claude), (Self.codexRoot, .codex)]
        self.opencodeDatabase = opencodeDatabase
    }

    /// One root, for tests and for anyone pointing this at a copied directory.
    public init(store: UsageStore, root: URL, source: Source = .claude) {
        self.init(store: store, roots: [(root, source)], opencodeDatabase: nil)
    }

    /// Every transcript under the roots, with its size already read.
    ///
    /// `fileSizeKey` is asked for here rather than fetched per file later: the enumerator
    /// gets its attributes in batches from the directory walk it is already doing, so the
    /// size arrives free and `resourceValues` below reads it back without a syscall. Asking
    /// each file separately was four thousand `stat` calls per pass.
    public func transcriptURLs() -> [(url: URL, source: Source)] {
        roots.flatMap { root in
            guard
                let enumerator = FileManager.default.enumerator(
                    at: root.url,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles])
            else { return [(url: URL, source: Source)]() }

            return enumerator.compactMap { entry in
                guard let url = entry as? URL, url.pathExtension == "jsonl" else { return nil }
                return (url, root.source)
            }
        }
    }

    /// Indexes every transcript that has grown since the last run, then opencode's store.
    ///
    /// A pass is dominated by the files that have *not* moved. A machine that has been used
    /// for a while has thousands of finished transcripts and one or two live ones, and this
    /// runs every ten seconds while an agent works — so the cheap answer for "nothing to do
    /// here" is the one that decides what the pass costs. It is now a dictionary lookup and
    /// a size comparison, against one query for the whole cursor table; it used to be a
    /// `stat` and a prepared statement per file.
    ///
    /// A file whose size is exactly where the cursor stopped is taken as unchanged. That
    /// gives up one case the per-file `stat` used to catch: a transcript replaced by a
    /// different file of byte-identical length, which would keep the stale offset instead of
    /// being re-read from zero. These files are append-only JSONL written by the agents
    /// themselves, so the case does not arise, and paying four thousand syscalls every ten
    /// seconds to rule it out is the wrong trade.
    @discardableResult
    public func indexAll(onProgress: ((Progress) -> Void)? = nil) throws -> Progress {
        var progress = Progress()
        let cursors = store.allCursors()
        for (url, source) in transcriptURLs() {
            if let cursor = cursors[url.path],
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                size == cursor.offset
            {
                progress.filesScanned += 1
                onProgress?(progress)
                continue
            }

            let result = try index(url, source: source, cursor: cursors[url.path])
            progress.filesScanned += 1
            progress.eventsInserted += result.inserted
            progress.bytesRead += result.bytesRead
            onProgress?(progress)
        }

        if let inserted = try indexOpencode() {
            // One store, counted as one thing scanned: it is a database, not a directory of
            // files, and inventing a file count for it would be a number that means nothing.
            progress.filesScanned += 1
            progress.eventsInserted += inserted
            onProgress?(progress)
        }
        return progress
    }

    /// Drains opencode's database, resuming from the timestamp the last pass reached.
    ///
    /// Nil when there is nothing to read — no configured database, or opencode has never run
    /// here. The watermark lives in `file_cursor` beside the byte offsets: same question,
    /// "where did I stop", answered in the units this source has. A different inode means
    /// the store was replaced, and the whole thing is read again.
    @discardableResult
    func indexOpencode() throws -> Int? {
        guard let url = opencodeDatabase else { return nil }
        let inode = (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { $0[.systemFileNumber] as? Int } ?? 0

        let cursor = store.cursor(forPath: url.path)
        let watermark = cursor?.inode == inode ? (cursor?.offset ?? 0) : 0

        guard let reading = try OpencodeUsage.read(databaseURL: url, since: watermark) else {
            return nil
        }
        let inserted = try store.insert(reading.events)
        try store.setCursor(
            UsageStore.Cursor(offset: reading.watermark, inode: inode), forPath: url.path)
        return inserted
    }

    /// Reads one transcript from its stored offset onward.
    @discardableResult
    public func index(_ url: URL, source: Source = .claude) throws -> (
        inserted: Int, bytesRead: Int
    ) {
        try index(url, source: source, cursor: store.cursor(forPath: url.path))
    }

    /// The same, for a caller that has already read the cursor table.
    @discardableResult
    func index(_ url: URL, source: Source, cursor storedCursor: UsageStore.Cursor?) throws -> (
        inserted: Int, bytesRead: Int
    ) {
        let path = url.path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let inode = (attributes?[.systemFileNumber] as? Int) ?? 0
        let size = (attributes?[.size] as? Int) ?? 0

        var start = 0
        if let cursor = storedCursor {
            // A different inode means the file was replaced; a smaller size means it was
            // truncated. Either way the stored offset is meaningless — start over.
            let sameFile = cursor.inode == inode && size >= cursor.offset
            start = sameFile ? cursor.offset : 0
        }

        guard size > start else { return (0, 0) }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return (0, 0) }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(start))

        var events: [UsageEvent] = []
        var consumed = start
        var pending = Data()
        // A rollout is read with state: the session and the model are declared above the
        // lines that carry the counters. Resuming into the middle of one therefore has to
        // recover them first, or every counter until the next turn is dropped.
        var rollout = start > 0 ? CodexRollout.primed(for: url) : CodexRollout()

        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            pending.append(chunk)

            // Only whole lines are parsed; a trailing partial line stays buffered and is
            // left outside the committed offset so the next run re-reads it.
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                consumed += pending.distance(from: pending.startIndex, to: newline) + 1
                pending = pending[pending.index(after: newline)...]

                let data = Data(line)
                switch source {
                case .claude:
                    if let event = parse(line: data) { events.append(event) }
                case .codex:
                    if let event = parseCodex(line: data, into: &rollout) {
                        events.append(event)
                    }
                case .opencode:
                    // opencode has no transcript to walk; `indexOpencode` reads its
                    // database. Nothing files a `.jsonl` under it, so this is unreachable
                    // rather than unhandled.
                    break
                }
            }
        }

        let inserted = try store.insert(events)
        try store.setCursor(UsageStore.Cursor(offset: consumed, inode: inode), forPath: path)
        return (inserted, consumed - start)
    }

    private func parse(line: Data) -> UsageEvent? {
        // Skip the JSON parse for the majority of lines, which carry no usage at all.
        guard let text = String(data: line, encoding: .utf8),
            TranscriptParser.mightContainUsage(text)
        else { return nil }
        return TranscriptParser.parse(line: line)
    }

    private func parseCodex(line: Data, into rollout: inout CodexRollout) -> UsageEvent? {
        guard let text = String(data: line, encoding: .utf8), CodexRollout.mightMatter(text)
        else { return nil }
        return rollout.read(line: line)
    }
}
