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

    /// Nil means the bridge has nothing yet, and the panel offers to connect instead of
    /// showing a wrong zero.
    var limits: UsageLimitsReader.Reading? { bridgeLimits }

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

    func start() {
        // Before the first cost is computed rather than racing it: yesterday's cached
        // prices are already better than the ones compiled into this build.
        PricingRefresh.loadCache()

        // Independent of the index: quota shows up even if the transcript store fails.
        reloadLimits()
        do {
            let store = try UsageStore(path: UsageStore.defaultURL.path)
            self.store = store
            self.indexer = UsageIndexer(store: store)
        } catch {
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

            switch result {
            case .success:
                indexError = nil
                lastIndexedAt = .now
            case .failure(let error):
                indexError = "\(error)"
            }
            isIndexing = false
            reload()
        }
    }

    /// Coalesces the bursts of hook events a single Claude Code turn produces into one
    /// re-index, instead of scanning per tool call.
    func scheduleRefresh(after delay: Duration = .seconds(3)) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// Cheap enough to do on every reload: one small file, read off the main actor's hot
    /// path only in the sense that it is a few hundred bytes.
    func reloadLimits() {
        bridgeLimits = limitsReader.read()
        noticeCrossings()
    }

    /// One door for every reading, wherever it came from, so a crossing is noticed exactly
    /// once and the same way.
    private func noticeCrossings() {
        guard let reading = limits else { return }
        for event in watcher.events(for: reading.limits) { onQuotaEvent?(event) }
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

        Task {
            let result = await Task.detached(priority: .utility) {
                () -> Result<Aggregates, Error> in
                do {
                    return .success(
                        Aggregates(
                            today: try store.totals(since: startOfDay),
                            allTime: try store.totals(),
                            buckets: try store.buckets(granularity, limit: bucketCount),
                            byModel: try store.totalsByModel(since: startOfDay)))
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
            case .failure(let error):
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
