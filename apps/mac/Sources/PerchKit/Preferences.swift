import Foundation

/// The settings that are neither about noise nor about what gets in: the shortcut, the
/// notch's own dimensions, how long a silent session survives.
///
/// Kept apart from `QuietSettings` because they change for different reasons — one is
/// "leave me alone", this is "fit my machine".
/// How much of each session the panel spells out.
///
/// Two densities rather than a pile of toggles. The panel hangs off the menu bar, so the
/// real constraint is how many sessions fit before it stops being glanceable — and the
/// answer differs between someone running one agent and someone running six.
public enum PanelLayout: String, Codable, Sendable, CaseIterable {
    /// Project, title, and what it is doing. One line of chrome per session.
    case clean
    /// Everything: what you asked, and the plan it is working through.
    case detailed

    public var title: String {
        switch self {
        case .clean: return "Clean"
        case .detailed: return "Detailed"
        }
    }

    /// Clean drops what you already know — you wrote the prompt — and keeps what changed.
    public var showsPrompt: Bool { self == .detailed }
    public var showsTasks: Bool { self == .detailed }
}

public struct Preferences: Codable, Sendable, Equatable {
    /// Virtual key code for the switcher. `kVK_ANSI_P` by default.
    public var switcherKeyCode: UInt32
    /// Carbon modifier mask. Control + Option by default.
    public var switcherModifiers: UInt32
    public var switcherEnabled: Bool

    /// Points added to what macOS reports for the cutout. Zero means "trust the API",
    /// which is right on every Mac it has been measured on and wrong on some it has not.
    public var notchWidthAdjustment: Double
    public var notchHeightAdjustment: Double

    /// A session with no traffic for this long is treated as gone. Zero means never —
    /// which is correct for CLIs that always send `SessionEnd`, and a slow leak for the
    /// ones that do not.
    public var idleTimeout: TimeInterval

    /// Sessions launched by these apps never reach the panel. For background helpers that
    /// drive an agent without a terminal, where a directory or prompt rule cannot bite.
    public var blockedLaunchers: [String]

    /// Take pre-release builds. The beta feed is the release feed's neighbour rather than
    /// a separate service — one file to publish, one key to sign with.
    public var betaUpdates: Bool

    /// How much of each session a card spells out.
    public var layout: PanelLayout

    /// Show what is left rather than what is spent. The same number either way — but
    /// "12% left" and "88% used" are not the same sentence, and people are split on which
    /// one they read without thinking.
    public var showsRemainingQuota: Bool

    /// Reveal the notch when a quota window crosses this percentage. Zero turns it off.
    /// Ninety by default: late enough to be rare, early enough to still change what you
    /// do next.
    public var quotaWarningThreshold: Double

    /// Read the plan quota from Anthropic directly, rather than only from whatever the
    /// statusline happens to render. Off until asked for: it needs the Claude Code
    /// credential out of the Keychain, and macOS will say so.
    public var directQuota: Bool

    public init(
        switcherKeyCode: UInt32 = 35,  // kVK_ANSI_P
        switcherModifiers: UInt32 = 4096 | 2048,  // controlKey | optionKey
        switcherEnabled: Bool = true,
        notchWidthAdjustment: Double = 0,
        notchHeightAdjustment: Double = 0,
        idleTimeout: TimeInterval = 30 * 60,
        blockedLaunchers: [String] = [],
        betaUpdates: Bool = false,
        layout: PanelLayout = .detailed,
        showsRemainingQuota: Bool = false,
        quotaWarningThreshold: Double = 90,
        directQuota: Bool = false
    ) {
        self.switcherKeyCode = switcherKeyCode
        self.switcherModifiers = switcherModifiers
        self.switcherEnabled = switcherEnabled
        self.notchWidthAdjustment = notchWidthAdjustment
        self.notchHeightAdjustment = notchHeightAdjustment
        self.idleTimeout = idleTimeout
        self.blockedLaunchers = blockedLaunchers
        self.betaUpdates = betaUpdates
        self.layout = layout
        self.showsRemainingQuota = showsRemainingQuota
        self.quotaWarningThreshold = quotaWarningThreshold
        self.directQuota = directQuota
    }

    /// Tolerant of keys added later: a file written by an older build must not reset the
    /// settings it did know about.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Preferences()
        switcherKeyCode =
            try container.decodeIfPresent(UInt32.self, forKey: .switcherKeyCode)
            ?? defaults.switcherKeyCode
        switcherModifiers =
            try container.decodeIfPresent(UInt32.self, forKey: .switcherModifiers)
            ?? defaults.switcherModifiers
        switcherEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .switcherEnabled) ?? true
        notchWidthAdjustment =
            try container.decodeIfPresent(Double.self, forKey: .notchWidthAdjustment) ?? 0
        notchHeightAdjustment =
            try container.decodeIfPresent(Double.self, forKey: .notchHeightAdjustment) ?? 0
        idleTimeout =
            try container.decodeIfPresent(TimeInterval.self, forKey: .idleTimeout)
            ?? defaults.idleTimeout
        blockedLaunchers =
            try container.decodeIfPresent([String].self, forKey: .blockedLaunchers) ?? []
        betaUpdates = try container.decodeIfPresent(Bool.self, forKey: .betaUpdates) ?? false
        layout =
            try container.decodeIfPresent(PanelLayout.self, forKey: .layout) ?? .detailed
        showsRemainingQuota =
            try container.decodeIfPresent(Bool.self, forKey: .showsRemainingQuota) ?? false
        quotaWarningThreshold =
            try container.decodeIfPresent(Double.self, forKey: .quotaWarningThreshold)
            ?? defaults.quotaWarningThreshold
        directQuota = try container.decodeIfPresent(Bool.self, forKey: .directQuota) ?? false
    }

    /// Clamped rather than validated: a tuning slider should never be able to make the
    /// panel unreachable, and a timeout of ten seconds would hide everything.
    public var sanitised: Preferences {
        var copy = self
        copy.notchWidthAdjustment = min(max(notchWidthAdjustment, -60), 60)
        copy.notchHeightAdjustment = min(max(notchHeightAdjustment, -12), 24)
        if idleTimeout != 0 { copy.idleTimeout = min(max(idleTimeout, 60), 24 * 3_600) }
        // Zero is off. Anything else lands in a range where the warning still leaves room
        // to act: a threshold of 5% would fire on a Monday morning and mean nothing.
        if quotaWarningThreshold != 0 {
            copy.quotaWarningThreshold = min(max(quotaWarningThreshold, 50), 100)
        }
        return copy
    }

    public func blocks(launcher bundleId: String?) -> Bool {
        guard let bundleId, !bundleId.isEmpty else { return false }
        return blockedLaunchers.contains { $0.caseInsensitiveCompare(bundleId) == .orderedSame }
    }
}

extension Preferences {
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".perch/preferences.json")
    }

    public static func load(from url: URL = defaultURL) -> Preferences {
        guard let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(Preferences.self, from: data)
        else { return Preferences() }
        return decoded.sanitised
    }

    public func save(to url: URL = defaultURL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(sanitised).write(to: url, options: .atomic)
        } catch {
            NSLog("perch: could not save preferences: \(error)")
        }
    }
}

/// Renders a Carbon key code and modifier mask the way a menu would.
public enum ShortcutFormatter {
    private static let names: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I",
        38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q",
        15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        49: "Space", 36: "Return", 48: "Tab", 53: "Escape", 50: "`",
    ]

    /// Carbon's masks, which are not the same numbers as AppKit's.
    public static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        var result = ""
        if modifiers & 4096 != 0 { result += "⌃" }
        if modifiers & 2048 != 0 { result += "⌥" }
        if modifiers & 512 != 0 { result += "⇧" }
        if modifiers & 256 != 0 { result += "⌘" }
        result += names[keyCode] ?? "key \(keyCode)"
        return result
    }

    /// AppKit reports modifiers with different bits than Carbon expects, so a recorder has
    /// to translate before anything is registered.
    public static func carbonModifiers(fromCocoa flags: UInt) -> UInt32 {
        var result: UInt32 = 0
        if flags & (1 << 18) != 0 { result |= 4096 }  // control
        if flags & (1 << 19) != 0 { result |= 2048 }  // option
        if flags & (1 << 17) != 0 { result |= 512 }  // shift
        if flags & (1 << 20) != 0 { result |= 256 }  // command
        return result
    }

    /// A shortcut with no modifier would swallow the letter everywhere.
    public static func isUsable(keyCode: UInt32, modifiers: UInt32) -> Bool {
        modifiers & (4096 | 2048 | 256) != 0 && names[keyCode] != nil
    }
}
