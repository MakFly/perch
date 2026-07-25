import Foundation

/// Reads Claude Code transcripts into the usage store, resuming where it left off.
public struct UsageIndexer {
    public struct Progress: Sendable {
        public var filesScanned = 0
        public var eventsInserted = 0
        public var bytesRead = 0

        public init() {}
    }

    private let store: UsageStore
    private let root: URL
    /// Chunk size for tailing. Transcripts reach hundreds of megabytes, so the file is
    /// streamed rather than read whole.
    private let chunkSize = 4 * 1024 * 1024

    public init(store: UsageStore, root: URL? = nil) {
        self.store = store
        self.root = root
            ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public func transcriptURLs() -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
        else { return [] }

        return enumerator.compactMap { entry in
            guard let url = entry as? URL, url.pathExtension == "jsonl" else { return nil }
            return url
        }
    }

    /// Indexes every transcript that has grown since the last run.
    @discardableResult
    public func indexAll(onProgress: ((Progress) -> Void)? = nil) throws -> Progress {
        var progress = Progress()
        for url in transcriptURLs() {
            let result = try index(url)
            progress.filesScanned += 1
            progress.eventsInserted += result.inserted
            progress.bytesRead += result.bytesRead
            onProgress?(progress)
        }
        return progress
    }

    /// Reads one transcript from its stored offset onward.
    @discardableResult
    public func index(_ url: URL) throws -> (inserted: Int, bytesRead: Int) {
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

                if let event = parse(line: Data(line)) {
                    events.append(event)
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
}
