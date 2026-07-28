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
    }

    /// Reads several transcripts off the main actor and returns what each one ends with.
    ///
    /// Paths, not sessions, so nothing that is not `Sendable` crosses the boundary.
    static func read(paths: [String: String]) async -> [String: TranscriptTurn] {
        await Task.detached(priority: .userInitiated) {
            var turns: [String: TranscriptTurn] = [:]
            for (id, path) in paths {
                if let turn = Transcript.lastTurn(path: path) { turns[id] = turn }
            }
            return turns
        }.value
    }
}
