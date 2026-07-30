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

// MARK: - One reading per session

private func reading(fiveHour: Double, sevenDay: Double, resets: Double = 1_785_421_200)
    -> RateLimits
{
    RateLimits(
        fiveHour: RateLimitWindow(
            utilization: fiveHour, resetsAt: Date(timeIntervalSince1970: resets)),
        sevenDay: RateLimitWindow(
            utilization: sevenDay, resetsAt: Date(timeIntervalSince1970: resets + 588_000)))
}

/// Measured on a real machine: three sessions open, all on one account, republishing every
/// ten seconds — 43%, 20% and 10% of the same five-hour window at the same instant. The
/// busy one is right and the two idle ones are frozen at what they saw hours ago, so the
/// single file showed whichever landed last and the panel cycled through all three.
@Test func theBusiestSessionsReadingWinsOverTheFrozenOnes() throws {
    let merged = try #require(
        RateLimits.merged([reading(fiveHour: 20, sevenDay: 4),
                           reading(fiveHour: 43, sevenDay: 9),
                           reading(fiveHour: 10, sevenDay: 2)]))

    #expect(merged.fiveHour?.utilization == 43)
    #expect(merged.sevenDay?.utilization == 9)
}

/// Higher only means newer *within* a window. Once the window has turned over, the reading
/// that belongs to the new one wins however small it is — otherwise a reset would never
/// show, and the panel would sit at 98% into the next week.
@Test func aWindowThatHasTurnedOverBeatsAHigherNumberFromTheOldOne() throws {
    let old = reading(fiveHour: 98, sevenDay: 88)
    let new = reading(fiveHour: 3, sevenDay: 1, resets: 1_785_421_200 + 18_000)

    let merged = try #require(RateLimits.merged([old, new]))
    #expect(merged.fiveHour?.utilization == 3)
    #expect(merged.sevenDay?.utilization == 1)
}

/// Per-model weeks are merged by name, not by position: a session that reports only the
/// Opus window must not shift the Sonnet one onto it.
@Test func perModelWindowsAreMergedByName() throws {
    let opus = RateLimits(modelScoped: [
        NamedWindow(
            id: "seven_day_opus", title: "7d Opus",
            window: RateLimitWindow(utilization: 12, resetsAt: nil))
    ])
    let both = RateLimits(modelScoped: [
        NamedWindow(
            id: "seven_day_opus", title: "7d Opus",
            window: RateLimitWindow(utilization: 40, resetsAt: nil)),
        NamedWindow(
            id: "seven_day_sonnet", title: "7d Sonnet",
            window: RateLimitWindow(utilization: 7, resetsAt: nil)),
    ])

    let merged = try #require(RateLimits.merged([opus, both]))
    #expect(merged.modelScoped.map(\.id) == ["seven_day_opus", "seven_day_sonnet"])
    #expect(merged.modelScoped.first?.window.utilization == 40)
}

/// An API key signed in beside a subscription reports no windows at all. It must not erase
/// the plan the other session can see.
@Test func anAccountWithoutAPlanDoesNotEraseOneWithIt() throws {
    let merged = try #require(
        RateLimits.merged([RateLimits(available: false), reading(fiveHour: 30, sevenDay: 5)]))

    #expect(merged.available)
    #expect(merged.fiveHour?.utilization == 30)
}

@Test func nothingToMergeIsNothingRatherThanZero() {
    #expect(RateLimits.merged([]) == nil)
}

/// The directory is what the bridge writes now; the single file is what a bridge older
/// than it wrote, and dropping that would show "not connected" on a machine whose quota is
/// sitting right there.
@Test func theReaderPrefersTheSessionFilesAndFallsBackToTheOldOne() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("perch-limits-\(UUID().uuidString)")
    let directory = root.appendingPathComponent("rate-limits")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let legacy = root.appendingPathComponent("rate-limits.json")
    try Data(#"{"rate_limits":{"five_hour":{"used_percentage":11}}}"#.utf8).write(to: legacy)

    let reader = UsageLimitsReader(url: legacy, directory: directory)
    #expect(reader.read()?.limits.fiveHour?.utilization == 11)

    for (name, used) in [("a", 20.0), ("b", 43.0)] {
        try Data(#"{"rate_limits":{"five_hour":{"used_percentage":\#(used)}}}"#.utf8)
            .write(to: directory.appendingPathComponent("\(name).json"))
    }
    #expect(reader.read()?.limits.fiveHour?.utilization == 43)
}
