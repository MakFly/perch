import Foundation

/// Subscription quota, which is a different number from spend.
///
/// `UsageStore` answers "what did this cost"; this answers "how much of the plan is left".
/// Claude Code only publishes it through the statusline: every render, it hands the
/// statusline command a JSON payload on stdin that carries a `rate_limits` object. The
/// bridge in `scripts/usage-bridge.sh` caches that object; this parses the cache.
///
/// Shape verified against the statusline input schema in the Claude Code binary (2.1.220).
public struct RateLimitWindow: Sendable, Equatable {
    /// Percentage of the window consumed, 0–100. Null while the server has nothing to say.
    public var utilization: Double?
    public var resetsAt: Date?

    public init(utilization: Double?, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    public var isExhausted: Bool { (utilization ?? 0) >= 100 }

    /// Remaining share of the window, 0–100.
    public var remaining: Double? { utilization.map { max(0, 100 - $0) } }

    /// How long until the window resets, at the width a notch has room for: `4d17h`,
    /// `2h2m`, `42m`.
    ///
    /// Two units, never three, and the smaller one is dropped once the larger passes a
    /// day — at four days out, the minutes are noise. Nil once it is in the past, so a
    /// stale cache shows nothing rather than a countdown running backwards.
    public func timeLeft(from now: Date = .now) -> String? {
        guard let resetsAt else { return nil }
        let seconds = Int(resetsAt.timeIntervalSince(now))
        guard seconds > 0 else { return nil }

        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24

        if days > 0 { return "\(days)d\(hours % 24)h" }
        if hours > 0 { return "\(hours)h\(minutes % 60)m" }
        return "\(max(1, minutes))m"
    }
}

/// One quota window, with the label the notch shows.
public struct NamedWindow: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var window: RateLimitWindow

    public init(id: String, title: String, window: RateLimitWindow) {
        self.id = id
        self.title = title
        self.window = window
    }
}

public struct RateLimits: Sendable, Equatable {
    public var fiveHour: RateLimitWindow?
    public var sevenDay: RateLimitWindow?
    public var sevenDayOpus: RateLimitWindow?
    public var sevenDaySonnet: RateLimitWindow?
    /// Per-model weekly windows the server may add. Additive: only present when emitted.
    public var modelScoped: [NamedWindow]
    /// When the account has none — API key, Bedrock, Vertex — there is nothing to show.
    public var available: Bool

    public init(
        fiveHour: RateLimitWindow? = nil,
        sevenDay: RateLimitWindow? = nil,
        sevenDayOpus: RateLimitWindow? = nil,
        sevenDaySonnet: RateLimitWindow? = nil,
        modelScoped: [NamedWindow] = [],
        available: Bool = true
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.modelScoped = modelScoped
        self.available = available
    }

    /// Everything worth a row, in the order the panel lists them. Windows the server left
    /// null are dropped rather than shown as zero — "0% used" and "unknown" are not the
    /// same claim.
    public var windows: [NamedWindow] {
        var result: [NamedWindow] = []
        func add(_ id: String, _ title: String, _ window: RateLimitWindow?) {
            guard let window, window.utilization != nil else { return }
            result.append(NamedWindow(id: id, title: title, window: window))
        }
        add("five_hour", "5h session", fiveHour)
        add("seven_day", "7d all models", sevenDay)
        add("seven_day_opus", "7d Opus", sevenDayOpus)
        add("seven_day_sonnet", "7d Sonnet", sevenDaySonnet)
        result.append(contentsOf: modelScoped.filter { $0.window.utilization != nil })
        return result
    }

    /// The window closest to running out, which is the one the notch summarises.
    public var tightest: NamedWindow? {
        windows.max { ($0.window.utilization ?? 0) < ($1.window.utilization ?? 0) }
    }

    public var isEmpty: Bool { windows.isEmpty }
}

extension RateLimits {
    /// Parses the object cached by the bridge. Tolerates a bare `rate_limits` object as
    /// well as the whole statusline payload, because both are useful to feed in.
    public static func parse(_ data: Data) -> RateLimits? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // `rate_limits_available: false` means the plan has no windows at all.
        if let available = root["rate_limits_available"] as? Bool, !available {
            return RateLimits(available: false)
        }

        let limits = (root["rate_limits"] as? [String: Any]) ?? root

        func at(_ key: String) -> RateLimitWindow? {
            guard let raw = limits[key] as? [String: Any] else { return nil }
            return window(from: raw)
        }

        var result = RateLimits(
            fiveHour: at("five_hour"),
            sevenDay: at("seven_day"),
            sevenDayOpus: at("seven_day_opus"),
            sevenDaySonnet: at("seven_day_sonnet")
        )

        // `limits[]` and `model_scoped` both carry named per-model weekly windows.
        let named =
            (limits["model_scoped"] as? [[String: Any]])
            ?? (limits["limits"] as? [[String: Any]]) ?? []
        result.modelScoped = named.compactMap { (entry) -> NamedWindow? in
            guard let name = entry["name"] as? String else { return nil }
            return NamedWindow(id: name, title: name, window: window(from: entry))
        }

        return result
    }

    /// Two spellings are live at once. The schema compiled into the CLI says
    /// `utilization` with an ISO 8601 `resets_at`; what actually arrives on a real
    /// statusline render is `used_percentage` with `resets_at` as a Unix epoch. Reading
    /// only one of them yields a confident, wrong number, so read both.
    private static func window(from raw: [String: Any]) -> RateLimitWindow {
        let utilization =
            number(raw["utilization"])
            ?? number(raw["used_percentage"])
            ?? number(raw["utilization_percentage"])

        let resets: Date?
        switch raw["resets_at"] {
        case let text as String:
            resets = TranscriptParser.parseTimestamp(text)
        case let epoch as NSNumber:
            resets = Date(timeIntervalSince1970: epoch.doubleValue)
        default:
            resets = nil
        }

        return RateLimitWindow(utilization: utilization, resetsAt: resets)
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let double as Double: return double
        case let int as Int: return Double(int)
        case let value as NSNumber: return value.doubleValue
        default: return nil
        }
    }
}

/// Reads the file the statusline bridge writes, and remembers when it last changed so the
/// panel can say "updated 2m ago" instead of showing a stale number as if it were live.
public struct UsageLimitsReader: Sendable {
    public let url: URL

    public init(url: URL = UsageLimitsReader.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".perch/cache/rate-limits.json")
    }

    public struct Reading: Sendable, Equatable {
        public var limits: RateLimits
        public var updatedAt: Date?

        public init(limits: RateLimits, updatedAt: Date?) {
            self.limits = limits
            self.updatedAt = updatedAt
        }
    }

    /// Nil when the bridge was never installed, or has not seen a render yet — which the
    /// panel shows as an offer to connect rather than as an error.
    public func read() -> Reading? {
        guard let data = try? Data(contentsOf: url), let limits = RateLimits.parse(data) else {
            return nil
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
        return Reading(limits: limits, updatedAt: modified as? Date)
    }
}
