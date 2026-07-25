import Foundation

/// Notices when a quota window crosses the line you asked to be told about.
///
/// The number itself is already on screen; what is not is the moment it changes meaning.
/// Nobody watches a percentage climb — they discover it at the point where the next turn
/// is refused, which is exactly when a notification is too late to be useful.
///
/// Two rules keep it from becoming noise:
///
/// - **A first sighting is never an event.** Perch launching while the week is at 95% is
///   not the week reaching 95%; announcing it would mean a chime at every login for the
///   rest of the window.
/// - **A crossing fires once.** Staying above the line is the same news as arriving there,
///   and the reading refreshes every few minutes.
public struct QuotaWatcher: Sendable {
    public enum Event: Sendable, Equatable {
        /// Went from under the threshold to at or over it.
        case crossed(NamedWindow)
        /// Came back under it — the window reset, and the plan is usable again.
        case reset(NamedWindow)
    }

    /// Percentage at which a window is worth mentioning. Zero turns this off entirely.
    public var threshold: Double

    private var lastSeen: [String: Double] = [:]

    public init(threshold: Double = 90) {
        self.threshold = threshold
    }

    public mutating func events(for limits: RateLimits) -> [Event] {
        var events: [Event] = []

        for named in limits.windows {
            guard let now = named.window.utilization else { continue }
            defer { lastSeen[named.id] = now }

            // Nothing to compare against yet: record it and say nothing.
            guard threshold > 0, let before = lastSeen[named.id] else { continue }

            if before < threshold, now >= threshold {
                events.append(.crossed(named))
            } else if before >= threshold, now < threshold {
                events.append(.reset(named))
            }
        }

        // A window the server stopped sending is not a window that reset; forgetting it
        // means the next sighting is treated as a first one, which is the quiet answer.
        let live = Set(limits.windows.map(\.id))
        lastSeen = lastSeen.filter { live.contains($0.key) }

        return events
    }
}
