import Foundation
import PerchKit

/// Keeps the price table current without making the app depend on being able to reach the
/// network.
///
/// Three states, in order of preference: a cache written by a previous refresh, a fetch
/// that succeeded just now, and the table compiled into the binary. The last one is never
/// removed — a model whose price changed is a rounding error, while a model with *no*
/// price reads as $0, which is a number people believe.
enum PricingRefresh {
    /// LiteLLM's list: maintained daily, a plain file rather than an API with a key, and
    /// already what this category standardised on. Overridable so a release can be pinned
    /// to a mirror without a new build.
    static var sourceURL: URL {
        let fallback =
            "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
        let configured = ProcessInfo.processInfo.environment["PERCH_PRICING_URL"]
        return URL(string: configured ?? fallback) ?? URL(string: fallback)!
    }

    /// A day. Prices move on the scale of quarters, and a menu-bar app that fetches two
    /// megabytes on every launch is one people notice for the wrong reason.
    static let maximumAge: TimeInterval = 24 * 3_600

    /// Applies whatever a previous run cached. Synchronous and cheap — a few hundred bytes
    /// — so it can run before the first cost is computed rather than racing it.
    @discardableResult
    static func loadCache(from url: URL = PricingCache.defaultURL) -> Date? {
        let decoder = JSONDecoder()
        // Matches what `refresh` writes. A default decoder would read the ISO string as a
        // malformed number and throw away a perfectly good cache.
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
            let cache = try? decoder.decode(PricingCache.self, from: data)
        else { return nil }

        Pricing.apply(cache.modelPricing, at: cache.updatedAt)
        return cache.updatedAt
    }

    /// Fetches only when the cache is old enough to be worth replacing.
    static func refreshIfStale(
        cacheURL: URL = PricingCache.defaultURL,
        now: Date = .now
    ) async {
        let cachedAt = Pricing.refreshedAt
        if let cachedAt, now.timeIntervalSince(cachedAt) < maximumAge { return }
        await refresh(cacheURL: cacheURL, now: now)
    }

    /// Every failure path leaves the previous table in place and says nothing: a price
    /// list is not worth an error the user has to dismiss.
    static func refresh(cacheURL: URL = PricingCache.defaultURL, now: Date = .now) async {
        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = 20
        // The file is a couple of megabytes and is fetched once a day; letting the system
        // cache decide would mean sometimes fetching it twice and sometimes not at all.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return }

        let prices = PricingTable.parse(data)
        // A handful of rows means the file changed shape, or a proxy answered with
        // something that happens to be JSON. Both are reasons to keep what we have.
        guard prices.count >= 4 else { return }

        Pricing.apply(prices, at: now)

        let cache = PricingCache(updatedAt: now, prices: prices)
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(cache).write(to: cacheURL, options: .atomic)
        } catch {
            // Applied in memory either way: an unwritable cache costs one fetch tomorrow.
            NSLog("perch: could not write the pricing cache: \(error)")
        }
    }
}
