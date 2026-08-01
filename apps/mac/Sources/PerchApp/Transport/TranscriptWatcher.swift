import Foundation
import PerchKit

/// Keeps the last turn on each card current, while the panel is open.
///
/// Deliberately **not** on the hook path. A hook call holds the CLI that made it — the
/// session sits blocked until Perch answers — so a megabyte read and a JSON parse per event
/// would be paid by the agent, in a place where the whole design is to get out of the way.
/// The path is recorded from the payload, which is free, and the reading happens here.
///
/// Nor on the main actor: this is the same mistake the aggregates made, where four queries
/// on the main thread made the notch miss hover events. Every read is detached, and only
/// the result comes back.
@MainActor
final class TranscriptWatcher {
    /// Fast enough to read as live, slow enough that a session writing continuously is not
    /// re-parsed for every token. A reply arrives in bursts anyway.
    private static let interval: Duration = .milliseconds(700)

    private var task: Task<Void, Never>?

    /// What a file looked like when it was last read.
    ///
    /// A transcript that has not been written to since the previous tick ends with exactly
    /// what it ended with then, so re-reading it produces the turn already on the card. That
    /// re-read is not cheap — a 1 MB window off the end of the file and every line in it
    /// through `JSONSerialization`, measured at 12.5ms against a real transcript — and it
    /// happened for every visible session, every 700ms, whether or not anything was
    /// happening. On a panel showing six sessions of which one is working, five of those
    /// reads were answering a question that had not changed.
    private struct Stamp: Sendable, Equatable {
        var size: Int
        var modified: Date
    }

    private var stamps: [String: Stamp] = [:]

    /// Starts refreshing, and does one pass immediately so opening the panel does not
    /// show a stale turn for most of a second.
    func start(_ refresh: @escaping @MainActor () async -> Void) {
        guard task == nil else { return }
        task = Task { [interval = Self.interval] in
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        // The panel is closed; the next opening should read everything once rather than
        // trust stamps taken before it. Also keeps this from growing with every transcript
        // the app has ever watched.
        stamps = [:]
    }

    /// Reads several transcripts off the main actor and returns what each one ends with.
    ///
    /// Paths, not sessions, so nothing that is not `Sendable` crosses the boundary.
    ///
    /// Only the files that moved come back. A session left out keeps the turn it already
    /// has: `SessionTracker.record` never blanks a turn it is not handed a replacement for,
    /// which is the same property that lets a hook firing mid-read leave the card alone.
    func read(paths: [String: String]) async -> [String: TranscriptTurn] {
        let known = stamps
        let result = await Task.detached(priority: .userInitiated) {
            var turns: [String: TranscriptTurn] = [:]
            var seen: [String: Stamp] = [:]
            for (id, path) in paths {
                let stamp = Self.stamp(of: path)
                // Unchanged since the last pass: nothing to say about it.
                if let stamp {
                    seen[path] = stamp
                    if known[path] == stamp { continue }
                }
                if let turn = Transcript.lastTurn(path: path) { turns[id] = turn }
            }
            return (turns: turns, stamps: seen)
        }.value

        stamps = result.stamps
        return result.turns
    }

    /// Size and modification date in one call, which is one `stat` against the megabyte the
    /// read below would otherwise cost.
    private nonisolated static func stamp(of path: String) -> Stamp? {
        guard
            let values = try? URL(fileURLWithPath: path)
                .resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
            let size = values.fileSize, let modified = values.contentModificationDate
        else { return nil }
        return Stamp(size: size, modified: modified)
    }
}
