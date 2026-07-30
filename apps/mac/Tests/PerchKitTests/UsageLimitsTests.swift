import Foundation
import Testing

@testable import PerchKit

/// The payload Claude Code hands the statusline, trimmed to what the bridge caches.
private let payload = """
    {
      "rate_limits_available": true,
      "rate_limits": {
        "five_hour":  {"utilization": 42.5, "resets_at": "2026-07-25T18:00:00Z"},
        "seven_day":  {"utilization": 88,   "resets_at": "2026-07-29T00:00:00Z"},
        "seven_day_opus":   {"utilization": null, "resets_at": null},
        "seven_day_sonnet": {"utilization": 12.5, "resets_at": "2026-07-29T00:00:00Z"}
      }
    }
    """.data(using: .utf8)!

@Test func parsesTheStatuslinePayload() throws {
    let limits = try #require(RateLimits.parse(payload))

    #expect(limits.available)
    #expect(limits.fiveHour?.utilization == 42.5)
    #expect(limits.sevenDay?.utilization == 88)
    #expect(limits.sevenDaySonnet?.utilization == 12.5)
    #expect(limits.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_785_002_400))
}

/// A window the server left null is unknown, not empty. Showing it as 0% used would be a
/// claim we cannot make.
@Test func nullWindowsAreDroppedRatherThanShownAsZero() throws {
    let limits = try #require(RateLimits.parse(payload))
    let ids = limits.windows.map(\.id)

    #expect(ids == ["five_hour", "seven_day", "seven_day_sonnet"])
    #expect(!ids.contains("seven_day_opus"))
}

@Test func tightestWindowIsTheOneClosestToRunningOut() throws {
    let limits = try #require(RateLimits.parse(payload))
    #expect(limits.tightest()?.id == "seven_day")
    #expect(limits.sevenDay?.remaining == 12)
}

/// API keys, Bedrock and Vertex have no plan windows at all.
@Test func unavailableLimitsParseToNothingToShow() throws {
    let raw = #"{"rate_limits_available": false, "rate_limits": null}"#.data(using: .utf8)!
    let limits = try #require(RateLimits.parse(raw))

    #expect(!limits.available)
    #expect(limits.isEmpty)
}

/// The cache may hold a bare `rate_limits` object rather than the whole payload.
@Test func parsesABareLimitsObject() throws {
    let raw = #"{"five_hour": {"utilization": 7, "resets_at": null}}"#.data(using: .utf8)!
    let limits = try #require(RateLimits.parse(raw))

    #expect(limits.fiveHour?.utilization == 7)
    #expect(limits.fiveHour?.resetsAt == nil)
    #expect(limits.windows.count == 1)
}

@Test func perModelWeeklyWindowsAreAdditive() throws {
    let raw = """
        {"rate_limits": {"five_hour": {"utilization": 5, "resets_at": null},
         "limits": [{"name": "claude-opus-5", "utilization": 61, "resets_at": null}]}}
        """.data(using: .utf8)!
    let limits = try #require(RateLimits.parse(raw))

    #expect(limits.windows.map(\.id) == ["five_hour", "claude-opus-5"])
    #expect(limits.tightest()?.id == "claude-opus-5")
}

/// What a real statusline render actually delivers, captured from the bridge. It does not
/// match the schema compiled into the CLI — `used_percentage` instead of `utilization`,
/// and `resets_at` as a Unix epoch instead of ISO 8601. Reading only the documented
/// spelling produced a confident 0%.
@Test func parsesTheShapeRealRendersActuallySend() throws {
    let raw = """
        {"rate_limits":{"five_hour":{"used_percentage":0,"resets_at":1785003000},
         "seven_day":{"used_percentage":26,"resets_at":1785405600}},
         "rate_limits_available":null}
        """.data(using: .utf8)!
    let limits = try #require(RateLimits.parse(raw))

    #expect(limits.fiveHour?.utilization == 0)
    #expect(limits.sevenDay?.utilization == 26)
    #expect(limits.sevenDay?.resetsAt == Date(timeIntervalSince1970: 1_785_405_600))
    // A genuine zero is data, not a missing window: it must still be listed.
    #expect(limits.windows.map(\.id) == ["five_hour", "seven_day"])
    #expect(limits.tightest()?.id == "seven_day")
}

@Test func garbageIsRejectedRatherThanGuessed() {
    #expect(RateLimits.parse(Data("not json".utf8)) == nil)
}

@Test func exhaustionIsReportedAtAHundredPercent() {
    #expect(RateLimitWindow(utilization: 100, resetsAt: nil).isExhausted)
    #expect(!RateLimitWindow(utilization: 99.9, resetsAt: nil).isExhausted)
    #expect(RateLimitWindow(utilization: nil, resetsAt: nil).remaining == nil)
}

// MARK: - Countdown

/// A percentage answers "how much is left"; the countdown answers "how long until it comes
/// back", which is the question people actually have at 90%.
@Test func theCountdownIsTwoUnitsWideAtMost() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func left(_ seconds: TimeInterval) -> String? {
        RateLimitWindow(utilization: 50, resetsAt: now.addingTimeInterval(seconds))
            .timeLeft(from: now)
    }

    #expect(left(42 * 60) == "42m")
    #expect(left(2 * 3_600 + 2 * 60) == "2h2m")
    // Past a day the minutes are noise, so they go.
    #expect(left(4 * 86_400 + 17 * 3_600 + 30 * 60) == "4d17h")
    #expect(left(86_400) == "1d0h")
}

/// A cache written before a reset would otherwise count backwards for ever.
@Test func aWindowThatAlreadyResetShowsNothing() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(
        RateLimitWindow(utilization: 50, resetsAt: now.addingTimeInterval(-60))
            .timeLeft(from: now) == nil)
    #expect(RateLimitWindow(utilization: 50, resetsAt: nil).timeLeft(from: now) == nil)
    // Under a minute still reads as a minute rather than as "0m".
    #expect(
        RateLimitWindow(utilization: 50, resetsAt: now.addingTimeInterval(20))
            .timeLeft(from: now) == "1m")
}

// MARK: - Staleness

/// Several sessions render through one bridge into one cache, and each sends the quota its
/// own last API response carried. A session idle since yesterday therefore publishes
/// yesterday's numbers today: a file written seconds ago holding a week that reset hours
/// ago. The reset having passed is what gives it away.
@Test func aWindowWhoseResetHasPassedIsStale() {
    let now = Date(timeIntervalSince1970: 1_000_000)

    #expect(RateLimitWindow(utilization: 95, resetsAt: now.addingTimeInterval(-60)).isStale(from: now))
    #expect(!RateLimitWindow(utilization: 95, resetsAt: now.addingTimeInterval(60)).isStale(from: now))
    // Nothing to date it by is not the same as knowing it is old.
    #expect(!RateLimitWindow(utilization: 95, resetsAt: nil).isStale(from: now))
}

/// The notch summarises one window, and a week that already reset is not the one running
/// out — however high the number it last reported.
@Test func theTightestWindowSkipsStaleOnes() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let limits = RateLimits(
        fiveHour: RateLimitWindow(utilization: 40, resetsAt: now.addingTimeInterval(3_600)),
        sevenDay: RateLimitWindow(utilization: 95, resetsAt: now.addingTimeInterval(-360)))

    #expect(limits.tightest(from: now)?.id == "five_hour")
}

/// With nothing current to point at there is no better answer, so the highest is still
/// returned — the views draw it as unknown rather than as a percentage.
@Test func everythingStaleStillPointsSomewhere() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let limits = RateLimits(
        fiveHour: RateLimitWindow(utilization: 40, resetsAt: now.addingTimeInterval(-7_200)),
        sevenDay: RateLimitWindow(utilization: 95, resetsAt: now.addingTimeInterval(-360)))

    #expect(limits.tightest(from: now)?.id == "seven_day")
}

/// The bug this comes from: the week reset at noon, and five minutes later the panel still
/// read 95% because an idle session had just replayed the old window.
@Test func theWeekThatAlreadyResetIsNotStillAtNinetyFive() throws {
    let raw = """
        {"rate_limits":{"five_hour":{"used_percentage":0,"resets_at":1785340800},
         "seven_day":{"used_percentage":95,"resets_at":1785405600}}}
        """.data(using: .utf8)!
    let limits = try #require(RateLimits.parse(raw))
    // Both windows reset before this instant.
    let now = Date(timeIntervalSince1970: 1_785_405_960)

    #expect(limits.sevenDay?.isStale(from: now) == true)
    #expect(limits.sevenDay?.timeLeft(from: now) == nil)
    // The reading is still listed — dropping it would empty the panel into "not connected".
    #expect(limits.windows.map(\.id) == ["five_hour", "seven_day"])
}
