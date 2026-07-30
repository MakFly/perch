import Foundation

/// Reads agent transcripts into the usage store, resuming where it left off.
///
/// Two shapes, two directories. Claude Code writes a conversation whose assistant lines
/// carry their own usage; Codex writes a typed event stream where the counters arrive on a
/// line of their own and the model belongs to the line before it. Which parser a file gets
/// is decided by the root it was found under — the two never mix, and a rollout that
/// wandered into `~/.claude` would be skipped rather than misread.
public struct UsageIndexer {
    public struct Progress: Sendable {
        public var filesScanned = 0
        public var eventsInserted = 0
        public var bytesRead = 0

        public init() {}
    }

    /// Which agent wrote a directory, and therefore how to read what is in it.
    public enum Source: Sendable {
        case claude
        case codex
    }

    private let store: UsageStore
    private let roots: [(url: URL, source: Source)]
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

    public init(store: UsageStore, roots: [(url: URL, source: Source)]? = nil) {
        self.store = store
        self.roots = roots ?? [(Self.claudeRoot, .claude), (Self.codexRoot, .codex)]
    }

    /// One root, for tests and for anyone pointing this at a copied directory.
    public init(store: UsageStore, root: URL, source: Source = .claude) {
        self.init(store: store, roots: [(root, source)])
    }

    public func transcriptURLs() -> [(url: URL, source: Source)] {
        roots.flatMap { root in
            guard
                let enumerator = FileManager.default.enumerator(
                    at: root.url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles])
            else { return [(url: URL, source: Source)]() }

            return enumerator.compactMap { entry in
                guard let url = entry as? URL, url.pathExtension == "jsonl" else { return nil }
                return (url, root.source)
            }
        }
    }

    /// Indexes every transcript that has grown since the last run.
    @discardableResult
    public func indexAll(onProgress: ((Progress) -> Void)? = nil) throws -> Progress {
        var progress = Progress()
        for (url, source) in transcriptURLs() {
            let result = try index(url, source: source)
            progress.filesScanned += 1
            progress.eventsInserted += result.inserted
            progress.bytesRead += result.bytesRead
            onProgress?(progress)
        }
        return progress
    }

    /// Reads one transcript from its stored offset onward.
    @discardableResult
    public func index(_ url: URL, source: Source = .claude) throws -> (
        inserted: Int, bytesRead: Int
    ) {
        let path = url.path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let inode = (attributes?[.systemFileNumber] as? Int) ?? 0
        let size = (attributes?[.size] as? Int) ?? 0

        var start = 0
        if let cursor = store.cursor(forPath: path) {
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
