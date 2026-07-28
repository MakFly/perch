import Foundation

/// The public leaderboard: what is published, and what comes back.
///
/// The whole feature is opt-in and the opt-in is meaningful, so the boundary is drawn
/// here rather than in the view: `PublishPayload` is the *only* thing that can leave the
/// machine, and it is a list of daily counters. There is no field on it that could carry a
/// prompt, a path, a project name or a command, which is a stronger guarantee than
/// remembering not to fill one in.
public enum Leaderboard {

    // MARK: - Identity

    /// Who this Mac publishes as.
    ///
    /// The token is the credential and the server only stores its hash, so this file is
    /// the single copy. It is written at mode 600 for that reason.
    public struct Identity: Codable, Sendable, Equatable {
        public var handle: String
        public var token: String
        public var displayName: String
        public var team: String?
        public var visibility: Visibility
        public var lastPublishedAt: Date?

        public init(
            handle: String,
            token: String,
            displayName: String,
            team: String? = nil,
            visibility: Visibility = .public,
            lastPublishedAt: Date? = nil
        ) {
            self.handle = handle
            self.token = token
            self.displayName = displayName
            self.team = team
            self.visibility = visibility
            self.lastPublishedAt = lastPublishedAt
        }
    }

    public enum Visibility: String, Codable, Sendable, CaseIterable {
        /// On the board and reachable at `/u/<handle>`.
        case `public`
        /// Publishes, but is not listed and has no public profile.
        case `private`
    }

    // MARK: - Wire types

    public struct PublishDay: Codable, Sendable, Equatable {
        public var day: String
        public var model: String
        public var inputTokens: Int
        public var outputTokens: Int
        public var cacheReadTokens: Int
        public var cacheWriteTokens: Int
        public var costUsd: Double
        public var focusSeconds: Int
        public var sessions: Int
    }

    public struct PublishPayload: Codable, Sendable, Equatable {
        public var days: [PublishDay]
    }

    public struct Registration: Codable, Sendable {
        public var handle: String
        public var token: String
    }

    public struct Row: Codable, Sendable, Identifiable, Equatable {
        public var rank: Int
        public var handle: String
        public var displayName: String
        public var team: String?
        public var agent: String
        public var model: String
        public var outputTokens: Int
        public var totalTokens: Int
        public var costUsd: Double
        public var focusSeconds: Int
        public var sessions: Int

        public var id: String { handle }
    }

    public struct Period: Codable, Sendable, Equatable {
        public var kind: String
        public var start: String
        public var end: String
        public var label: String
        public var offset: Int
    }

    public struct Board: Codable, Sendable, Equatable {
        public var mode: String
        public var period: Period
        public var rows: [Row]
        public var you: Row?

        /// True when the server is generating its numbers because it has no database.
        /// Surfaced in the panel: a demo board that presents itself as real is worse than
        /// no board.
        public var isDemo: Bool { mode == "demo" }
    }

    // MARK: - Building what gets published

    /// How far back a publish reaches.
    ///
    /// A rolling window rather than a lifetime: the server upserts on
    /// `(builder, day, model)`, so re-sending recent days is free and repairs a day that
    /// was indexed late. Sending everything on every publish would be a megabyte a time to
    /// restate history that cannot change.
    public static let publishWindowDays = 45

    /// Fold the local index into the wire shape.
    ///
    /// Focus and sessions are per *day*, not per model, so they are attached to the day's
    /// dominant model and zeroed on the rest. Repeating them on every model row would
    /// count one hour of work once per model touched in it — which on a normal day is
    /// three.
    public static func payload(
        models: [UsageStore.DailyModelUsage],
        activity: [UsageStore.DailyActivity]
    ) -> PublishPayload {
        let activityByDay = Dictionary(uniqueKeysWithValues: activity.map { ($0.day, $0) })

        // Model *ids* are collapsed to display names first, and rows that collapse onto
        // the same name are merged. The server's key is `(builder, day, model)` and it
        // upserts, so emitting `claude-haiku-4-5` and `claude-haiku-4-5-20251001` as two
        // rows named `Haiku 4.5` would not add them up — the second would silently
        // replace the first, and a day would quietly lose half its tokens.
        var merged: [String: [String: UsageStore.DailyModelUsage]] = [:]
        for row in models {
            // `<synthetic>` is what Claude Code records for a reply it produced without a
            // model — an interrupt, a local error. It has no tokens and no cost, and a
            // board row for it would be a model nobody ran.
            guard row.inputTokens + row.outputTokens + row.cacheReadTokens
                + row.cacheWriteTokens > 0
            else { continue }

            let name = ModelName.display(row.model)
            var day = merged[row.day] ?? [:]
            if var existing = day[name] {
                existing.inputTokens += row.inputTokens
                existing.outputTokens += row.outputTokens
                existing.cacheReadTokens += row.cacheReadTokens
                existing.cacheWriteTokens += row.cacheWriteTokens
                existing.cost += row.cost
                day[name] = existing
            } else {
                var copy = row
                copy.model = name
                day[name] = copy
            }
            merged[row.day] = day
        }

        var days: [PublishDay] = []
        for (day, rows) in merged.sorted(by: { $0.key < $1.key }) {
            let ordered = rows.values.sorted { $0.model < $1.model }
            let dominant = ordered.max { $0.outputTokens < $1.outputTokens }?.model
            let dayActivity = activityByDay[day]

            for row in ordered {
                let carriesDayTotals = row.model == dominant
                days.append(
                    PublishDay(
                        day: day,
                        model: row.model,
                        inputTokens: row.inputTokens,
                        outputTokens: row.outputTokens,
                        cacheReadTokens: row.cacheReadTokens,
                        cacheWriteTokens: row.cacheWriteTokens,
                        costUsd: row.cost,
                        focusSeconds: carriesDayTotals ? (dayActivity?.focusSeconds ?? 0) : 0,
                        sessions: carriesDayTotals ? (dayActivity?.sessions ?? 0) : 0))
            }
        }
        return PublishPayload(days: days)
    }

    /// A handle the server will accept, derived from whatever was typed.
    ///
    /// Done here rather than only server-side so the field can reject a name *before* it
    /// is submitted — discovering that `Jean Dupont` is not a handle after a round trip is
    /// a worse way to learn it.
    public static func normalise(handle: String) -> String {
        let lowered = handle.lowercased().folding(
            options: [.diacriticInsensitive], locale: Locale(identifier: "en_US"))
        let kept = lowered.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character : "-"
        }
        var result = String(kept)
        while result.contains("--") { result = result.replacingOccurrences(of: "--", with: "-") }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return String(result.prefix(31))
    }

    public static func isValid(handle: String) -> Bool {
        let handle = handle.lowercased()
        guard handle.count >= 2, handle.count <= 31 else { return false }
        guard let first = handle.first, first.isLetter || first.isNumber else { return false }
        return handle.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }
}

// MARK: - Persistence

extension Leaderboard.Identity {
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".perch/leaderboard.json")
    }

    public static func load(from url: URL = defaultURL) -> Leaderboard.Identity? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Leaderboard.Identity.self, from: data)
    }

    public func save(to url: URL = defaultURL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        // The token is the only copy of the credential, so the file is not world-readable.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func remove(at url: URL = defaultURL) {
        try? FileManager.default.removeItem(at: url)
    }
}
