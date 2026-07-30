import Foundation

/// Anthropic list prices, in US dollars per million tokens.
///
/// Only input and output are published per model; the cache rates are fixed multiples of
/// the input rate, so they are derived rather than duplicated per row:
///   - cache read       0.1x input
///   - cache write 5m   1.25x input
///   - cache write 1h   2x input
public struct ModelPricing: Sendable, Equatable {
    public var inputPerMillion: Double
    public var outputPerMillion: Double

    /// A tenth of input, which is both vendors' published ratio: Anthropic charges 0.1x for
    /// a cache read, and every OpenAI row in the list prices it at exactly a tenth too.
    public var cacheReadPerMillion: Double { inputPerMillion * 0.1 }
    public var cacheWrite5mPerMillion: Double { inputPerMillion * 1.25 }
    public var cacheWrite1hPerMillion: Double { inputPerMillion * 2.0 }

    public init(input: Double, output: Double) {
        self.inputPerMillion = input
        self.outputPerMillion = output
    }
}

public enum Pricing {
    /// Prices as of 2026-07. Sonnet 5 carries a promotional rate through 2026-08-31
    /// ($2/$10); the list price is used here so costs are not understated once it ends.
    ///
    /// This table ships in the binary and is never removed: a refresh overlays it, so a
    /// machine that has been offline for a year still prices what it can rather than
    /// reporting everything at zero.
    ///
    /// A refresh *does* replace the conservative reading above with whatever is published
    /// — LiteLLM tracks the promotional rate, so Sonnet 5 becomes $2/$10 the first time
    /// this machine can reach the network. That is the number actually billed today, and
    /// preferring a live source over a compiled-in guess is the point of the refresh.
    ///
    /// Either way it only moves what happens next: `UsageStore` prices a row when it is
    /// indexed and stores the result, so a price change never rewrites what last month
    /// cost.
    static let bundled: [String: ModelPricing] = [
        "claude-fable-5": ModelPricing(input: 10, output: 50),
        "claude-mythos-5": ModelPricing(input: 10, output: 50),
        "claude-opus-5": ModelPricing(input: 5, output: 25),
        "claude-opus-4-8": ModelPricing(input: 5, output: 25),
        "claude-opus-4-7": ModelPricing(input: 5, output: 25),
        "claude-opus-4-6": ModelPricing(input: 5, output: 25),
        "claude-opus-4-5": ModelPricing(input: 5, output: 25),
        "claude-sonnet-5": ModelPricing(input: 3, output: 15),
        "claude-sonnet-4-6": ModelPricing(input: 3, output: 15),
        "claude-sonnet-4-5": ModelPricing(input: 3, output: 15),
        "claude-haiku-4-5": ModelPricing(input: 1, output: 5),
    ]

    // Prices change, and a model released after a build has no price at all until this is
    // overlaid — which is how a week of Fable usage can read as $0 and be believed.
    //
    // `nonisolated(unsafe)` with a lock rather than an actor: `cost(of:)` is called once
    // per transcript row from a detached indexing task, and awaiting an actor per row
    // would turn a synchronous fold into thousands of hops.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: [String: ModelPricing] = bundled
    /// When the overlay was taken. Nil means nothing but the bundled table has been used,
    /// which is also what the diagnostic report prints.
    nonisolated(unsafe) public private(set) static var refreshedAt: Date?

    /// Overlays fresher prices on the bundled ones. Empty input changes nothing, so a
    /// failed fetch cannot silently zero out the table it was meant to improve.
    public static func apply(_ prices: [String: ModelPricing], at date: Date = .now) {
        guard !prices.isEmpty else { return }
        lock.withLock {
            current = bundled.merging(prices) { _, refreshed in refreshed }
            refreshedAt = date
        }
    }

    /// Back to what shipped. Only the tests need this — but a pricing table that cannot be
    /// put back is a test that leaks into the next one.
    public static func resetToBundled() {
        lock.withLock {
            current = bundled
            refreshedAt = nil
        }
    }

    private static var table: [String: ModelPricing] { lock.withLock { current } }

    /// Transcripts contain both aliases and dated IDs (`claude-haiku-4-5-20251001`), and
    /// occasionally a bare family name or `<synthetic>`. Match the longest known prefix
    /// so a new dated snapshot still prices correctly.
    public static func pricing(for model: String) -> ModelPricing? {
        // One snapshot per lookup: the table can be replaced by a refresh mid-index, and
        // pricing half a row at the old rate and half at the new one would be worse than
        // either.
        let table = Self.table
        if let exact = table[model] { return exact }

        let match = table.keys
            .filter { model.hasPrefix($0) }
            .max(by: { $0.count < $1.count })
        if let match { return table[match] }

        // Bare family names appear in older transcripts.
        switch model {
        case "opus": return table["claude-opus-4-8"]
        case "sonnet": return table["claude-sonnet-5"]
        case "haiku": return table["claude-haiku-4-5"]
        default: return nil
        }
    }

    /// Cost in US dollars. Returns 0 for models with no published price — synthetic
    /// entries and local models are real rows in the transcript but cost nothing.
    public static func cost(of event: UsageEvent) -> Double {
        guard let price = pricing(for: event.model) else { return 0 }
        let million = 1_000_000.0
        return (Double(event.inputTokens) * price.inputPerMillion
            + Double(event.outputTokens) * price.outputPerMillion
            + Double(event.cacheReadTokens) * price.cacheReadPerMillion
            + Double(event.cacheWrite5mTokens) * price.cacheWrite5mPerMillion
            + Double(event.cacheWrite1hTokens) * price.cacheWrite1hPerMillion) / million
    }

    public static var knownModels: [String] { Array(table.keys).sorted() }
}

/// Reads a published price list into the shape Perch prices with.
///
/// The source is LiteLLM's `model_prices_and_context_window.json`, which is what every
/// tool in this category ends up using: it is maintained daily, and it is a plain file
/// rather than an API with a key. Perch keeps only the Anthropic rows and only the two
/// numbers it needs, so what lands in `~/.perch` is a few hundred bytes rather than two
/// megabytes of every model that has ever existed.
public enum PricingTable {
    /// Per-token dollars in the file; per-million everywhere in Perch.
    private static let million = 1_000_000.0

    public static func parse(_ data: Data) -> [String: ModelPricing] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        var prices: [String: ModelPricing] = [:]
        for (name, value) in root {
            guard let entry = value as? [String: Any] else { continue }
            // Each vendor's own rows only. The same models are listed again under
            // `vertex_ai/`, `bedrock/` and `azure/` at different prices, and neither a
            // Claude Code transcript nor a Codex rollout is ever any of those.
            //
            // OpenAI is here because Codex publishes what it spent and the price list
            // knows the models it spends it on — `gpt-5.6-terra` included. What this
            // computes is what the tokens would have cost through the API; on a Plus or a
            // Max plan that is a measure of what you used, not a bill. The same caveat has
            // always applied to the Claude figures beside it.
            switch entry["litellm_provider"] as? String {
            case "anthropic": guard name.hasPrefix("claude") else { continue }
            case "openai": guard name.hasPrefix("gpt-") else { continue }
            default: continue
            }

            guard let input = number(entry["input_cost_per_token"]),
                let output = number(entry["output_cost_per_token"]),
                input > 0, output > 0
            else { continue }

            prices[name] = ModelPricing(input: input * million, output: output * million)
        }
        return prices
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let double as Double: return double
        case let int as Int: return Double(int)
        case let value as NSNumber: return value.doubleValue
        // Some rows carry the cost as a string. A price that does not parse is dropped
        // rather than guessed.
        case let text as String: return Double(text)
        default: return nil
        }
    }
}

/// What Perch writes to `~/.perch/cache/pricing.json`: the pruned table, and when it was
/// taken. Small enough to read at launch without thinking about it, and legible enough to
/// check by eye when a cost looks wrong.
public struct PricingCache: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var input: Double
        public var output: Double
    }

    public var updatedAt: Date
    public var prices: [String: Entry]

    public init(updatedAt: Date, prices: [String: ModelPricing]) {
        self.updatedAt = updatedAt
        self.prices = prices.mapValues {
            Entry(input: $0.inputPerMillion, output: $0.outputPerMillion)
        }
    }

    public var modelPricing: [String: ModelPricing] {
        prices.mapValues { ModelPricing(input: $0.input, output: $0.output) }
    }

    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".perch/cache/pricing.json")
    }
}
