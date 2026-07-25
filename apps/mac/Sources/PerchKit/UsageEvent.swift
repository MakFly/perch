import Foundation

/// One billed model response, as recorded in a Claude Code transcript.
public struct UsageEvent: Sendable, Equatable {
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

    public var cacheWriteTokens: Int { cacheWrite5mTokens + cacheWrite1hTokens }

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
    }

    public init(
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
        cwd: String? = nil
    ) {
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
