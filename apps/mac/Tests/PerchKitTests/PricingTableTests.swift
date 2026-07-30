import Foundation
import Testing

@testable import PerchKit

private let liteLLM = """
{
  "sample_spec": {"note": "this is a documentation row, not a model"},
  "claude-opus-9": {
    "litellm_provider": "anthropic",
    "input_cost_per_token": 0.000012,
    "output_cost_per_token": 0.00006
  },
  "claude-sonnet-9": {
    "litellm_provider": "anthropic",
    "input_cost_per_token": 3e-06,
    "output_cost_per_token": 1.5e-05
  },
  "vertex_ai/claude-opus-9": {
    "litellm_provider": "vertex_ai-anthropic_models",
    "input_cost_per_token": 0.00009,
    "output_cost_per_token": 0.0009
  },
  "gpt-nine": {
    "litellm_provider": "openai",
    "input_cost_per_token": 0.000002,
    "output_cost_per_token": 0.000008
  },
  "azure/gpt-nine": {
    "litellm_provider": "azure",
    "input_cost_per_token": 0.00002,
    "output_cost_per_token": 0.00008
  },
  "o-nine": {
    "litellm_provider": "openai",
    "input_cost_per_token": 0.000004,
    "output_cost_per_token": 0.000016
  },
  "claude-broken": {
    "litellm_provider": "anthropic",
    "input_cost_per_token": "not a number",
    "output_cost_per_token": 0.00001
  },
  "claude-free": {
    "litellm_provider": "anthropic",
    "input_cost_per_token": 0,
    "output_cost_per_token": 0
  }
}
"""

@Test func perTokenDollarsBecomePerMillion() {
    let prices = PricingTable.parse(Data(liteLLM.utf8))
    #expect(prices["claude-opus-9"]?.inputPerMillion == 12)
    #expect(prices["claude-opus-9"]?.outputPerMillion == 60)
    #expect(prices["claude-sonnet-9"]?.inputPerMillion == 3)
}

/// The same model is listed again under `vertex_ai/`, `bedrock/` and `azure/` at different
/// prices, and neither a Claude Code transcript nor a Codex rollout is ever any of those.
/// Taking the wrong row would misprice every session by a factor of seven.
@Test func onlyEachVendorsOwnRowsAreKept() {
    let prices = PricingTable.parse(Data(liteLLM.utf8))
    #expect(prices["vertex_ai/claude-opus-9"] == nil)
    #expect(prices["azure/gpt-nine"] == nil)
    #expect(prices["sample_spec"] == nil)
}

/// Codex publishes what it spent, and it spends it on models the list knows. Without their
/// prices the tokens would show up under a flat zero, which reads as "free" rather than as
/// "unpriced".
@Test func openAIsOwnGPTRowsAreKeptToo() {
    let prices = PricingTable.parse(Data(liteLLM.utf8))
    #expect(prices["gpt-nine"]?.inputPerMillion == 2)
    #expect(prices["gpt-nine"]?.outputPerMillion == 8)
    // A cache read is a tenth of input for both vendors, which is what the shared
    // derivation in `ModelPricing` assumes.
    #expect(prices["gpt-nine"]?.cacheReadPerMillion == 0.2)
    // OpenAI publishes plenty that Codex never runs; only the `gpt-` family is kept.
    #expect(prices["o-nine"] == nil)
}

/// A price that does not parse is dropped rather than guessed, and zero is not a price.
@Test func unusableRowsAreDropped() {
    let prices = PricingTable.parse(Data(liteLLM.utf8))
    #expect(prices["claude-broken"] == nil)
    #expect(prices["claude-free"] == nil)
    #expect(prices.count == 3)
}

@Test func nonsenseParsesToNothingRatherThanCrashing() {
    #expect(PricingTable.parse(Data("not json".utf8)).isEmpty)
    #expect(PricingTable.parse(Data("[1,2,3]".utf8)).isEmpty)
}

/// The price table is process-wide, so these run one at a time — and they only ever move
/// `claude-mythos-5`, which no other test asserts a price for. A suite that reprices Opus
/// while the suite next to it is checking Opus is a flake waiting for a slow machine.
@Suite(.serialized)
struct PricingOverlayTests {
    /// The overlay is a layer, never a replacement: a model the refresh does not mention
    /// keeps the price it shipped with instead of falling to zero.
    @Test func refreshedPricesOverlayTheBundledOnesWithoutErasingThem() {
        defer { Pricing.resetToBundled() }

        Pricing.apply(["claude-mythos-5": ModelPricing(input: 99, output: 199)])

        #expect(Pricing.pricing(for: "claude-mythos-5")?.inputPerMillion == 99)
        #expect(Pricing.pricing(for: "claude-opus-5")?.inputPerMillion == 5)
        // Dated snapshots still resolve through the longest-prefix match.
        #expect(Pricing.pricing(for: "claude-mythos-5-20260101")?.outputPerMillion == 199)
        #expect(Pricing.refreshedAt != nil)
    }

    /// An empty result is what a failed fetch looks like, and it must not be applied.
    @Test func anEmptyRefreshChangesNothing() {
        defer { Pricing.resetToBundled() }

        Pricing.apply([:])
        #expect(Pricing.refreshedAt == nil)
        #expect(Pricing.pricing(for: "claude-mythos-5")?.inputPerMillion == 10)
    }
}

@Test func theCacheRoundTripsThroughItsOwnFormat() throws {
    let prices = ["claude-opus-5": ModelPricing(input: 7, output: 21)]
    let cache = PricingCache(updatedAt: Date(timeIntervalSince1970: 1_700_000_000), prices: prices)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let restored = try decoder.decode(PricingCache.self, from: encoder.encode(cache))
    #expect(restored.modelPricing["claude-opus-5"]?.inputPerMillion == 7)
    #expect(restored.updatedAt == cache.updatedAt)
}
