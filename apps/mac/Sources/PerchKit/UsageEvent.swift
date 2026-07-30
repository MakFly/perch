import Foundation

/// One billed model response, as recorded by whichever agent produced it.
public struct UsageEvent: Sendable, Equatable {
    /// Which agent this came from.
    ///
    /// Carried rather than inferred. The model name used to be enough — nothing but Codex
    /// wrote `gpt-*` into this table — but opencode runs whatever model you point it at,
    /// Claude and GPT included, so the name stopped being evidence of anything. What the
    /// reader knows for certain is which store it read.
    public var agent: UsageStore.Agent = .claude
    /// `message.id` and `requestId` together identify a response. Transcripts repeat
    /// entries constantly — resumed sessions, sidechains, duplicated files — and on this
    /// machine 56% of usage lines are repeats, so this pair is the deduplication key.
    public var messageId: String
    public var requestId: String

    public var timestamp: Date
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    /// Cache writes are split by TTL because they are billed differently:
    /// 1.25x input for the 5-minute cache, 2x for the 1-hour one.
    public var cacheWrite5mTokens: Int
    public var cacheWrite1hTokens: Int
    public var sessionId: String?
    public var cwd: String?
    /// What the agent says it was billed, when it says so.
    ///
    /// Nil means "ask the price list", which is the case for Claude Code and Codex: neither
    /// records a price, so Perch computes one. opencode does record it, per message and per
    /// provider — including for models the bundled table will never carry — and a figure
    /// from the thing that paid it beats one Perch derived.
    public var cost: Double?

    public var cacheWriteTokens: Int { cacheWrite5mTokens + cacheWrite1hTokens }

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
    }

    public init(
        agent: UsageStore.Agent = .claude,
        messageId: String,
        requestId: String,
        timestamp: Date,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWrite5mTokens: Int,
        cacheWrite1hTokens: Int,
        sessionId: String? = nil,
        cwd: String? = nil,
        cost: Double? = nil
    ) {
        self.agent = agent
        self.cost = cost
        self.messageId = messageId
        self.requestId = requestId
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWrite5mTokens = cacheWrite5mTokens
        self.cacheWrite1hTokens = cacheWrite1hTokens
        self.sessionId = sessionId
        self.cwd = cwd
    }
}
