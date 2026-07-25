import Foundation

/// Whether Perch's hooks are still installed, and whether the sessions running right now
/// are actually using them.
///
/// Two different failures look identical from the notch — an empty panel:
///
/// - **Stripped.** Another tool rewrote `settings.json` and dropped Perch's entries. This
///   happens more than you would think: several agent tools manage that file.
/// - **Stale.** The hooks are there, but a session that started before they were installed
///   will never call them. Claude Code reads hooks once, at session start.
///
/// Telling them apart matters because the fixes are opposite: reinstall, or restart.
///
/// A third, quieter one is counted here too: hooks installed in *both* a project and the
/// global file. Claude Code runs both scopes, so the panel is fed everything twice. Perch
/// drops the copies rather than showing them, which is what makes this worth reporting —
/// otherwise the misconfiguration is invisible until something else trips over it.
public struct HookHealth: Sendable, Equatable {
    public var sitesChecked: Int
    public var sitesWithHooks: Int
    /// Sessions seen since Perch started. Zero, with hooks installed, is the "restart"
    /// case rather than the "reinstall" case.
    public var sessionsSeen: Int
    public var runningSince: Date
    /// Project settings files that install Perch on top of a global install. Every event
    /// from those projects arrives twice.
    public var duplicatedSites: Int

    public init(
        sitesChecked: Int, sitesWithHooks: Int, sessionsSeen: Int, runningSince: Date,
        duplicatedSites: Int = 0
    ) {
        self.sitesChecked = sitesChecked
        self.sitesWithHooks = sitesWithHooks
        self.sessionsSeen = sessionsSeen
        self.runningSince = runningSince
        self.duplicatedSites = duplicatedSites
    }

    public enum Advice: Sendable, Equatable {
        case fine
        /// Hooks are installed but nothing has called them yet.
        case restartSessions
        /// Some site lost its Perch entries.
        case reinstallHooks(missing: Int)
        /// Nothing is installed anywhere.
        case notInstalled
        /// A project install duplicates the global one, so every event fires twice.
        case installedTwice(sites: Int)
    }

    /// Grace before nagging. A session that has not done anything in the first minute is
    /// not evidence of anything — you may simply not have typed yet.
    public static let quietPeriod: TimeInterval = 90

    public func advice(now: Date = .now) -> Advice {
        guard sitesChecked > 0 else { return .notInstalled }
        if sitesWithHooks == 0 { return .notInstalled }
        if sitesWithHooks < sitesChecked {
            return .reinstallHooks(missing: sitesChecked - sitesWithHooks)
        }
        // Nothing arriving at all outranks everything arriving twice: one is an empty
        // panel, the other is a panel that works and wastes a little.
        if sessionsSeen == 0, now.timeIntervalSince(runningSince) > Self.quietPeriod {
            return .restartSessions
        }
        if duplicatedSites > 0 { return .installedTwice(sites: duplicatedSites) }
        return .fine
    }
}

/// Reads the settings files Perch recorded when it installed hooks, and reports which of
/// them still mention it.
public enum HookWatcher {
    /// Sites Perch wrote to, plus the two global ones, which are always worth checking
    /// even if the registry has been lost.
    public static func sites(home: String = NSHomeDirectory()) -> [String] {
        var paths = [
            "\(home)/.claude/settings.json",
            "\(home)/.codex/hooks.json",
        ]

        let registry = URL(fileURLWithPath: home).appendingPathComponent(".perch/hook-sites.json")
        if let data = try? Data(contentsOf: registry),
            let recorded = try? JSONDecoder().decode([String].self, from: data)
        {
            paths.append(contentsOf: recorded)
        }

        // A project may have been deleted since; a site that is gone is not a site that
        // lost its hooks.
        return Array(Set(paths)).filter { FileManager.default.fileExists(atPath: $0) }.sorted()
    }

    public static func check(
        home: String = NSHomeDirectory(),
        sessionsSeen: Int,
        runningSince: Date
    ) -> HookHealth {
        let paths = sites(home: home)
        let withHooks = paths.filter { path in
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                return false
            }
            return text.contains("perch-hook") || text.contains("perch-remote-hook")
        }

        // A project install is not extra coverage on top of a global one: Claude Code
        // merges the scopes and runs both entries, so those projects send everything
        // twice. Codex is left out — its hooks file has no project scope to collide with.
        let global = "\(home)/.claude/settings.json"
        let duplicated =
            withHooks.contains(global)
            ? withHooks.filter { $0 != global && $0.hasSuffix("/.claude/settings.json") }.count
            : 0

        return HookHealth(
            sitesChecked: paths.count,
            sitesWithHooks: withHooks.count,
            sessionsSeen: sessionsSeen,
            runningSince: runningSince,
            duplicatedSites: duplicated)
    }
}
