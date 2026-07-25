import Foundation

/// The second source for plan quota: Anthropic's own usage endpoint.
///
/// The statusline bridge is the only *local* source, and it has one flaw — it publishes
/// nothing until a statusline renders. Someone whose statusline is off, or who has not
/// opened Claude Code today, sees an empty panel where a number belongs.
///
/// This asks the API instead. It needs the credential Claude Code already holds, which is
/// why it is off until switched on: reading another app's Keychain item is not something
/// to do quietly on someone's behalf.
public enum QuotaEndpoint {
    public static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// The headers Claude Code's own OAuth calls carry. `anthropic-beta` is what marks the
    /// token as an OAuth credential rather than an API key; without it the endpoint has no
    /// reason to recognise the bearer.
    public static func request(token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Reads the response into the same shape the bridge produces, so everything
    /// downstream — the bars, the strip, the threshold watcher — cannot tell the two
    /// sources apart.
    ///
    /// Deliberately reuses `RateLimits.parse`: it already tolerates the two live spellings
    /// of a window and both the wrapped and bare forms, and an endpoint that reports the
    /// same numbers is unlikely to invent a third.
    public static func parse(_ data: Data) -> RateLimits? {
        guard let limits = RateLimits.parse(data) else { return nil }
        // Parsed, but nothing recognisable in it: treated as a miss so the caller can keep
        // the bridge's reading rather than replace it with an empty one.
        guard !limits.isEmpty || limits.available == false else { return nil }
        return limits
    }

    /// What to show when a response could not be read: the first line of it, with anything
    /// token-shaped removed. A quota body is numbers and timestamps — but a response from
    /// a proxy in the way could be anything, and this ends up in a diagnostic report that
    /// people paste in public.
    public static func describe(unreadable data: Data, limit: Int = 200) -> String {
        let text = String(decoding: data.prefix(limit * 4), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")

        // Splitting on spaces would work on prose and fails on JSON, where a token and the
        // field after it are one unbroken run — the scrub then eats the explanation it was
        // supposed to preserve. Matching the token shapes themselves keeps the sentence.
        let pattern = "sk-ant[A-Za-z0-9_-]*|[A-Za-z0-9_-]{40,}"
        let scrubbed =
            (try? NSRegularExpression(pattern: pattern))
            .map { expression in
                expression.stringByReplacingMatches(
                    in: text, range: NSRange(text.startIndex..., in: text),
                    withTemplate: "…")
            } ?? "(unreadable)"

        return String(scrubbed.prefix(limit))
    }
}
