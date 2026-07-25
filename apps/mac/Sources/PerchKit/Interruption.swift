import Foundation

/// What just happened, from the point of view of "should this take over the screen".
public enum InterruptionKind: String, Codable, Sendable, CaseIterable {
    case sessionStart
    case taskAcknowledge
    case taskComplete
    case taskError
    case approvalNeeded
    case questionAsked
    case contextLimit
    case idleReminder
    case usageWarning
    case usageReset

    /// What the settings pane calls it.
    public var title: String {
        switch self {
        case .sessionStart: return "Session start"
        case .taskAcknowledge: return "Prompt submitted"
        case .taskComplete: return "Task complete"
        case .taskError: return "Task error"
        case .approvalNeeded: return "Approval needed"
        case .questionAsked: return "Question asked"
        case .contextLimit: return "Context limit"
        case .idleReminder: return "Idle reminder"
        case .usageWarning: return "Usage almost full"
        case .usageReset: return "Usage refreshed"
        }
    }

    /// Something is blocked until the user acts, as opposed to merely informative.
    public var isBlocking: Bool {
        self == .approvalNeeded || self == .questionAsked
    }
}

/// A time range that may cross midnight, in minutes from midnight.
public struct QuietHours: Codable, Sendable, Equatable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    /// `22:00 → 07:00` is a real range, not an empty one, so the comparison flips when the
    /// end is earlier than the start. Agents running overnight is the whole use case.
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if start == end { return false }
        return start < end
            ? (minutes >= start && minutes < end)
            : (minutes >= start || minutes < end)
    }
}

/// What the machine is doing that Perch should not interrupt.
public struct Scene: Sendable, Equatable {
    public var isFocusActive: Bool
    public var isScreenObscured: Bool
    public var isScreenShared: Bool
    /// Bundle id of whatever is frontmost, so Perch can tell when you are already looking
    /// at the terminal that is asking.
    public var frontmostBundleId: String?

    public init(
        isFocusActive: Bool = false,
        isScreenObscured: Bool = false,
        isScreenShared: Bool = false,
        frontmostBundleId: String? = nil
    ) {
        self.isFocusActive = isFocusActive
        self.isScreenObscured = isScreenObscured
        self.isScreenShared = isScreenShared
        self.frontmostBundleId = frontmostBundleId
    }
}

public struct QuietSettings: Codable, Sendable, Equatable {
    public var duringFocus: Bool
    public var whenScreenObscured: Bool
    public var whenScreenShared: Bool
    public var quietHours: QuietHours?
    /// Off by default: a panel that opens on its own is startling the first time.
    public var autoExpandOnComplete: Bool
    public var soundEnabled: Bool
    /// Don't take the screen when you are already looking at the terminal that is asking.
    public var smartSuppression: Bool
    /// Tell me when a turn ends somewhere I cannot see. On by default, unlike the panel
    /// and the sound: a notification is the quietest of the three, and a finished turn
    /// that produces nothing at all is the complaint this whole app answers.
    public var notifiesOnComplete: Bool

    public init(
        duringFocus: Bool = true,
        whenScreenObscured: Bool = true,
        whenScreenShared: Bool = true,
        quietHours: QuietHours? = nil,
        autoExpandOnComplete: Bool = false,
        soundEnabled: Bool = true,
        smartSuppression: Bool = true,
        notifiesOnComplete: Bool = true
    ) {
        self.duringFocus = duringFocus
        self.whenScreenObscured = whenScreenObscured
        self.whenScreenShared = whenScreenShared
        self.quietHours = quietHours
        self.autoExpandOnComplete = autoExpandOnComplete
        self.soundEnabled = soundEnabled
        self.smartSuppression = smartSuppression
        self.notifiesOnComplete = notifiesOnComplete
    }

    /// Added after the file format shipped, so an existing `quiet.json` decodes without it.
    enum CodingKeys: String, CodingKey {
        case duringFocus, whenScreenObscured, whenScreenShared, quietHours
        case autoExpandOnComplete, soundEnabled, smartSuppression, notifiesOnComplete
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        duringFocus = try container.decodeIfPresent(Bool.self, forKey: .duringFocus) ?? true
        whenScreenObscured =
            try container.decodeIfPresent(Bool.self, forKey: .whenScreenObscured) ?? true
        whenScreenShared =
            try container.decodeIfPresent(Bool.self, forKey: .whenScreenShared) ?? true
        quietHours = try container.decodeIfPresent(QuietHours.self, forKey: .quietHours)
        autoExpandOnComplete =
            try container.decodeIfPresent(Bool.self, forKey: .autoExpandOnComplete) ?? false
        soundEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
        smartSuppression =
            try container.decodeIfPresent(Bool.self, forKey: .smartSuppression) ?? true
        notifiesOnComplete =
            try container.decodeIfPresent(Bool.self, forKey: .notifiesOnComplete) ?? true
    }
}

/// How loudly Perch is allowed to say something.
public enum Interruption: Sendable, Equatable {
    /// Open the panel and play the sound.
    case full
    /// Mark it, silently. A dot still appears, so nothing is lost — it just does not take
    /// the screen while you are presenting.
    case quiet
    /// Do not even mark it.
    case none
}

public enum InterruptionPolicy {
    /// Screen-sharing is the case that matters most: a permission card opening mid-demo
    /// puts a stranger's command on a projector. So quiet scenes silence *everything*,
    /// blocking requests included — they still queue and still show a dot, and the session
    /// is still held, so nothing is lost by waiting.
    public static func decide(
        _ kind: InterruptionKind,
        scene: Scene,
        settings: QuietSettings,
        /// Where the session asking this is running, when we know.
        host: String? = nil,
        at date: Date = .now,
        calendar: Calendar = .current
    ) -> Interruption {
        if isQuietScene(scene: scene, settings: settings)
            || settings.quietHours?.contains(date, calendar: calendar) == true
        {
            return .quiet
        }

        // You are already looking at the terminal that is asking. Taking the screen to
        // tell you what is on it would be a step backwards.
        if settings.smartSuppression, let host, host == scene.frontmostBundleId {
            return .quiet
        }

        // Something is blocked on an answer: that always earns the panel.
        if kind.isBlocking { return .full }

        // Completions are the noisy ones, and the reason people turn notifications off.
        if kind == .taskComplete && !settings.autoExpandOnComplete { return .quiet }

        return .full
    }

    /// Whether something that already happened is worth a macOS notification.
    ///
    /// This is not the panel decision repeated. The panel is for things you can see; a
    /// notification is for the case where you cannot — full screen in another app, on
    /// another Space, on a display the notch is not on. So it deliberately fires even
    /// when the panel chose to stay closed, and stops for the two reasons that outrank
    /// being told anything: the room is not yours (screen shared, locked, Focus, quiet
    /// hours), or you are already looking at the terminal that raised it.
    ///
    /// Never for blocking kinds: an approval owns the panel, and a notification racing it
    /// would be a second place to answer the same question.
    public static func notifies(
        _ kind: InterruptionKind,
        scene: Scene,
        settings: QuietSettings,
        host: String? = nil,
        at date: Date = .now,
        calendar: Calendar = .current
    ) -> Bool {
        guard settings.notifiesOnComplete, !kind.isBlocking else { return false }
        if isQuietScene(scene: scene, settings: settings) { return false }
        if settings.quietHours?.contains(date, calendar: calendar) == true { return false }
        if let host, host == scene.frontmostBundleId { return false }
        return true
    }

    public static func isQuietScene(scene: Scene, settings: QuietSettings) -> Bool {
        (settings.duringFocus && scene.isFocusActive)
            || (settings.whenScreenObscured && scene.isScreenObscured)
            || (settings.whenScreenShared && scene.isScreenShared)
    }

    /// Sound follows the panel, and never plays for something we chose not to show.
    public static func playsSound(
        _ kind: InterruptionKind,
        scene: Scene,
        settings: QuietSettings,
        host: String? = nil,
        at date: Date = .now,
        calendar: Calendar = .current
    ) -> Bool {
        guard settings.soundEnabled else { return false }
        return decide(
            kind, scene: scene, settings: settings, host: host, at: date, calendar: calendar)
            == .full
    }
}

extension QuietSettings {
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".perch/quiet.json")
    }

    public static func load(from url: URL = defaultURL) -> QuietSettings {
        guard let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(QuietSettings.self, from: data)
        else { return QuietSettings() }
        return decoded
    }

    public func save(to url: URL = defaultURL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
        } catch {
            NSLog("perch: could not save quiet settings: \(error)")
        }
    }
}
