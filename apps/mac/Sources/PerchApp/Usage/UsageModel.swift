import Foundation
import Observation
import PerchKit

/// Owns the usage index and the aggregates the Stats tab renders.
@MainActor
@Observable
final class UsageModel {
    private(set) var today = UsageStore.Totals()
    private(set) var allTime = UsageStore.Totals()
    private(set) var buckets: [UsageStore.Bucket] = []
    private(set) var byModel: [(model: String, tokens: Int, cost: Double)] = []
    private(set) var isIndexing = false
    private(set) var lastIndexedAt: Date?
    private(set) var indexError: String?

    /// Subscription quota, which the transcripts cannot tell us. The statusline bridge's
    /// cache is the one source: it is the only place the quota is published locally, and
    /// reading it needs no credential.
    private(set) var bridgeLimits: UsageLimitsReader.Reading?

    /// Codex publishes the same thing in a different place: every `token_count` line of a
    /// rollout carries the plan's windows. No bridge and no credential — the newest file on
    /// disk is the reading.
    private(set) var codexLimits: UsageLimitsReader.Reading?

    /// Which agent the Stats tab is showing. Everything below follows it: the quota, the
    /// tiles, the sparkline and the per-model rows.
    var agent: UsageStore.Agent = .claude {
        didSet { if agent != oldValue { reload() } }
    }

    /// Which agents this machine has actually run. The selector only appears from two on:
    /// on a machine that has only ever run Claude Code it would be a control with one
    /// setting, and a tab for an agent that never ran here opens onto an empty screen.
    private(set) var agents: [UsageStore.Agent] = [.claude]

    /// Nil means nothing has been read yet, and the panel offers to connect instead of
    /// showing a wrong zero.
    ///
    /// opencode is nil for a different reason, and permanently: it bills each provider
    /// directly and publishes no window anywhere on disk. The view says so rather than
    /// offering the Claude bridge, which would fix nothing there.
    var limits: UsageLimitsReader.Reading? {
        switch agent {
        case .claude: return bridgeLimits
        case .codex: return codexLimits
        case .opencode: return nil
        }
    }

    /// Quota reported by remote hosts, keyed by the alias you gave them. A build server
    /// signed in as a different account has a different budget, and conflating the two
    /// would be worse than not showing it.
    private(set) var remoteLimits: [String: UsageLimitsReader.Reading] = [:]

    @ObservationIgnored private let limitsReader = UsageLimitsReader()

    /// Watches the readings for the moment a window crosses the line, which is the only
    /// part of a quota that is news.
    @ObservationIgnored private var watcher = QuotaWatcher()

    /// What to do about a crossing. Set by `AppModel`, because whether it earns the screen
    /// is a question about quiet scenes and sound, not about usage.
    @ObservationIgnored var onQuotaEvent: ((QuotaWatcher.Event) -> Void)?

    func apply(preferences: Preferences) {
        watcher.threshold = preferences.quotaWarningThreshold
    }

    func recordRemoteLimits(host: String, limits: RateLimits, at date: Date = .now) {
        remoteLimits[host] = UsageLimitsReader.Reading(limits: limits, updatedAt: date)
    }

    var granularity: UsageStore.Granularity = .hour {
        didSet { reload() }
    }

    @ObservationIgnored private var store: UsageStore?
    @ObservationIgnored private var indexer: UsageIndexer?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var limitsTask: Task<Void, Never>?
    /// The cadence that task is on, so a change of pace restarts it rather than waiting
    /// out the sleep it is in the middle of.
    @ObservationIgnored private var limitsInterval: Duration?

    func start() {
        // Before the first cost is computed rather than racing it: yesterday's cached
        // prices are already better than the ones compiled into this build.
        PricingRefresh.loadCache()

        // Independent of the index: quota shows up even if the transcript store fails.
        reloadLimits()
        // The resting bar carries the plan, so it has to keep moving with nothing running
        // and nobody looking. Slowly — the panel raises the pace when it opens.
        startWatchingLimits(every: Self.restingInterval)
        do {
            let store = try UsageStore(path: UsageStore.defaultURL.path)
            self.store = store
            self.indexer = UsageIndexer(store: store)
        } catch {
            // Also to the log, not only to the panel. A store that fails to open takes the
            // token counts down with it, and the user's first sign of that is a screen of
            // zeroes — which reads as "I have not used anything", not as a broken index.
            PerchLog.error("usage store did not open: \(error)")
            indexError = "\(error)"
            return
        }
        refresh()
    }

    /// Indexing walks the whole transcript directory, so it runs off the main actor and
    /// only the aggregate reload comes back on.
    func refresh() {
        // Checked here rather than only at launch: this app is left open for weeks, and a
        // price list that is only ever read at startup is one that goes stale on exactly
        // the machines that use Perch most. A no-op while the cache is fresh.
        Task { await PricingRefresh.refreshIfStale() }

        guard let indexer, !isIndexing else { return }
        isIndexing = true

        Task {
            let result: Result<UsageIndexer.Progress, Error> = await Task.detached(priority: .utility) {
                do { return .success(try indexer.indexAll()) } catch { return .failure(error) }
            }.value

            var hasNewRows = true
            switch result {
            case .success(let progress):
                indexError = nil
                lastIndexedAt = .now
                hasNewRows = progress.eventsInserted > 0
                // A price list that has just learned a model does not retroactively price
                // what was indexed before it — unless it is asked to. Idempotent, but not
                // free: the predicate is `cost = 0`, which no index covers, so it is a scan
                // of the whole table. Only worth paying for when the table has just grown.
                //
                // Detached, like every other store call here. This was the one left on the
                // main actor, where it was measured at 77 ms of scan on a 132 000-row store
                // before it writes anything — and now that the connection is behind a lock,
                // it also waits there for whatever detached read holds it. The notch draws
                // on this thread; it should not be counting tokens on it.
                if hasNewRows, let store {
                    await Task.detached(priority: .utility) { _ = try? store.repriceUnpriced() }
                        .value
                }
            case .failure(let error):
                PerchLog.error("indexing failed: \(error)")
                indexError = "\(error)"
            }
            isIndexing = false

            // The aggregates are five queries over every row ever indexed, one of them
            // grouping the whole history through `strftime`. A pass that inserted nothing
            // cannot have changed any of their answers, and under a working agent this runs
            // every ten seconds — so it used to re-derive the same numbers all day. The
            // quota is re-read either way: it moves whether or not this machine spent it.
            if hasNewRows || !hasLoadedAggregates {
                hasLoadedAggregates = true
                reload()
            } else {
                reloadLimits()
            }
        }
    }

    /// Whether the tiles have ever been filled. The first pass on a fresh launch inserts
    /// nothing on a machine that is already indexed, and skipping it would open the panel
    /// onto zeroes.
    @ObservationIgnored private var hasLoadedAggregates = false

    /// How long the coalescing may hold out before it has to let a refresh through.
    ///
    /// The debounce cancels and reschedules on every hook event, which is right for a burst
    /// and wrong for a turn: a session calling a tool every second or two resets the timer
    /// before it ever fires, so the numbers freeze for exactly as long as the agent is
    /// working — which is exactly when they move. Seen on screen as a plan bar reading 2%
    /// that jumped to 8% the moment a tab was switched, because switching is what forced a
    /// read.
    private static let maximumWait: TimeInterval = 10

    /// Coalesces the bursts of hook events a single Claude Code turn produces into one
    /// re-index, instead of scanning per tool call — but never for longer than
    /// `maximumWait`.
    func scheduleRefresh(after delay: Duration = .seconds(3)) {
        // Nothing indexed yet, or nothing for a while: run now and let the burst coalesce
        // from here. An index already running will call `reload` when it finishes, so the
        // trailing one is still scheduled rather than dropped.
        let overdue = lastIndexedAt.map { Date.now.timeIntervalSince($0) >= Self.maximumWait }
        if overdue ?? true, !isIndexing {
            refresh()
            return
        }

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// How often the quota is re-read while the panel is open, and while it is not.
    ///
    /// Both matter now that the resting bar carries the plan: a number beside the cutout
    /// that only moves when the panel is opened is the bug this file already fixed once,
    /// put somewhere else. Slow at rest because the bridge writes every ten seconds and a
    /// window moves by a point a minute at the very most; quick while it is being read.
    static let watchedInterval: Duration = .seconds(2)
    static let restingInterval: Duration = .seconds(30)

    /// Re-reads the quota, on whichever cadence fits what is on screen.
    ///
    /// A handful of small files, so this is cheap either way. Nothing else here polls: the
    /// tokens follow the hooks, which is when there is new usage to read, while the quota
    /// moves whether or not this machine is the one spending it.
    func startWatchingLimits(every interval: Duration = watchedInterval) {
        // Restarted rather than left alone, so switching cadence takes effect now instead
        // of at the end of a thirty-second sleep.
        guard interval != limitsInterval || limitsTask == nil else { return }
        limitsTask?.cancel()
        limitsInterval = interval
        limitsTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.reloadLimits()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Nothing stops this any more — the resting bar reads the quota too, so there is no
    /// moment when nobody is looking. What used to be a stop is now a change of pace.

    /// Cheap enough to do on every reload: one small file, read off the main actor's hot
    /// path only in the sense that it is a few hundred bytes.
    func reloadLimits() {
        bridgeLimits = limitsReader.read()
        codexLimits = CodexQuota.read()
        noticeCrossings()
    }

    /// One door for every reading, wherever it came from, so a crossing is noticed exactly
    /// once and the same way.
    private func noticeCrossings() {
        // Both agents in one call. The watcher forgets any window it is not shown, so
        // announcing them in turn would have each one wipe the other's history — and a
        // Codex week at 94% is exactly the thing worth being told about, whichever tab
        // happens to be open.
        var combined = bridgeLimits?.limits ?? RateLimits()
        combined.modelScoped += codexLimits?.limits.modelScoped ?? []
        guard !combined.isEmpty else { return }
        for event in watcher.events(for: combined) { onQuotaEvent?(event) }
    }

    /// The daily counters the leaderboard publishes, read off the main actor.
    ///
    /// A window rather than everything: the server upserts on `(builder, day, model)`, so
    /// re-sending recent days repairs a day that was indexed late and costs nothing, while
    /// restating years of history on every publish would be kilobytes to say what has not
    /// changed.
    ///
    /// Returns nil when the index failed to open — which is the case where publishing
    /// zeroes would look like a quiet week rather than a broken install.
    func publishPayload(windowDays: Int) async -> Leaderboard.PublishPayload? {
        guard let store else { return nil }
        let since = Calendar.current.date(byAdding: .day, value: -windowDays, to: .now)

        return await Task.detached(priority: .utility) { () -> Leaderboard.PublishPayload? in
            guard let models = try? store.dailyByModel(since: since),
                let activity = try? store.dailyActivity(since: since)
            else { return nil }
            return Leaderboard.payload(models: models, activity: activity)
        }.value
    }

    /// Aggregates, read off the main actor.
    ///
    /// These are four SQLite queries over a table with tens of thousands of rows. Running
    /// them on the main actor made the notch miss hover events and the CLI time out while
    /// they ran — a panel that stops responding because it is counting tokens has its
    /// priorities backwards. Found by the hover smoke test failing intermittently.
    private func reload() {
        reloadLimits()
        guard let store else { return }
        let startOfDay = Calendar.current.startOfDay(for: .now)
        let granularity = granularity
        let bucketCount = bucketCount
        let agent = agent

        Task {
            let result = await Task.detached(priority: .utility) {
                () -> Result<Aggregates, Error> in
                do {
                    return .success(
                        Aggregates(
                            today: try store.totals(since: startOfDay, agent: agent),
                            allTime: try store.totals(agent: agent),
                            buckets: try store.buckets(
                                granularity, limit: bucketCount, agent: agent),
                            byModel: try store.totalsByModel(since: startOfDay, agent: agent),
                            agents: try store.agentsWithUsage()))
                } catch {
                    return .failure(error)
                }
            }.value

            switch result {
            case .success(let aggregates):
                today = aggregates.today
                allTime = aggregates.allTime
                buckets = aggregates.buckets
                byModel = aggregates.byModel
                // Always at least the tab you are on: a fresh install has indexed nothing,
                // and an empty list would take the selector away mid-look.
                agents = aggregates.agents.isEmpty ? [agent] : aggregates.agents
            case .failure(let error):
                PerchLog.error("reading the aggregates failed: \(error)")
                indexError = "\(error)"
            }
        }
    }

    /// One hop back to the main actor instead of four.
    private struct Aggregates: Sendable {
        var today: UsageStore.Totals
        var allTime: UsageStore.Totals
        var buckets: [UsageStore.Bucket]
        var byModel: [(model: String, tokens: Int, cost: Double)]
        var agents: [UsageStore.Agent]
    }

    /// How many buckets the sparkline shows — one screen's worth per granularity.
    private var bucketCount: Int {
        switch granularity {
        case .minute: return 60
        case .hour: return 24
        case .day: return 30
        case .month: return 12
        }
    }
}
