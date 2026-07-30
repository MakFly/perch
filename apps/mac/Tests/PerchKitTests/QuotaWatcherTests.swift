import Foundation
import Testing

@testable import PerchKit

private func limits(_ used: Double?, id: String = "five_hour") -> RateLimits {
    var result = RateLimits()
    let window = RateLimitWindow(utilization: used, resetsAt: nil)
    switch id {
    case "five_hour": result.fiveHour = window
    case "seven_day": result.sevenDay = window
    default: result.modelScoped = [NamedWindow(id: id, title: id, window: window)]
    }
    return result
}

/// Perch launching while the week is at 95% is not the week reaching 95%. Without this,
/// every login inside a full window would chime.
@Test func aFirstSightingIsNeverAnEvent() {
    var watcher = QuotaWatcher(threshold: 90)
    #expect(watcher.events(for: limits(97)).isEmpty)
}

@Test func crossingTheLineFiresOnce() {
    var watcher = QuotaWatcher(threshold: 90)
    _ = watcher.events(for: limits(40))

    let crossing = watcher.events(for: limits(91))
    #expect(crossing.count == 1)
    if case .crossed(let window) = crossing.first {
        #expect(window.id == "five_hour")
    } else {
        Issue.record("expected a crossing")
    }

    // Still above: same news, and the reading refreshes every few minutes.
    #expect(watcher.events(for: limits(93)).isEmpty)
    #expect(watcher.events(for: limits(100)).isEmpty)
}

@Test func comingBackUnderTheLineIsAReset() {
    var watcher = QuotaWatcher(threshold: 90)
    _ = watcher.events(for: limits(40))
    _ = watcher.events(for: limits(95))

    let events = watcher.events(for: limits(2))
    #expect(events.count == 1)
    if case .reset = events.first {} else { Issue.record("expected a reset") }
}

@Test func zeroMeansSilent() {
    var watcher = QuotaWatcher(threshold: 0)
    _ = watcher.events(for: limits(10))
    #expect(watcher.events(for: limits(99)).isEmpty)
}

/// Two windows are watched apart: the 5h filling up says nothing about the week.
@Test func windowsAreTrackedIndependently() {
    var watcher = QuotaWatcher(threshold: 90)
    var both = limits(10)
    both.sevenDay = RateLimitWindow(utilization: 10, resetsAt: nil)
    _ = watcher.events(for: both)

    var oneHigh = limits(95)
    oneHigh.sevenDay = RateLimitWindow(utilization: 12, resetsAt: nil)
    let events = watcher.events(for: oneHigh)

    #expect(events.count == 1)
    if case .crossed(let window) = events.first { #expect(window.id == "five_hour") }
}

/// An idle session replaying last week's 95% is not this week reaching 95%. Chiming for it
/// would be bad enough; the fresh 0% that follows would then read as the week coming back.
@Test func aStaleWindowNeitherFiresNorArmsTheNextReading() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func week(_ used: Double, resetsIn seconds: TimeInterval) -> RateLimits {
        RateLimits(sevenDay: RateLimitWindow(utilization: used, resetsAt: now.addingTimeInterval(seconds)))
    }

    var watcher = QuotaWatcher(threshold: 90)
    _ = watcher.events(for: week(40, resetsIn: 3_600), at: now)

    #expect(watcher.events(for: week(95, resetsIn: -360), at: now).isEmpty)
    // The week really did reset, so the 0% behind it is a first sighting of the new window
    // rather than a fall back under the line.
    #expect(watcher.events(for: week(0, resetsIn: 604_800), at: now).isEmpty)
}

/// A stale render between two live ones must not swallow the crossing that follows it.
@Test func aStaleRenderDoesNotEraseWhatWasLastSeen() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func week(_ used: Double, resetsIn seconds: TimeInterval) -> RateLimits {
        RateLimits(sevenDay: RateLimitWindow(utilization: used, resetsAt: now.addingTimeInterval(seconds)))
    }

    var watcher = QuotaWatcher(threshold: 90)
    _ = watcher.events(for: week(40, resetsIn: 3_600), at: now)
    _ = watcher.events(for: week(88, resetsIn: -360), at: now)

    let events = watcher.events(for: week(92, resetsIn: 3_600), at: now)
    #expect(events.count == 1)
    if case .crossed = events.first {} else { Issue.record("expected a crossing") }
}

/// A window the server stops sending is not a window that reset — and when it comes back
/// it is a first sighting again, which is the quiet answer.
@Test func aWindowThatDisappearsIsForgottenRatherThanReported() {
    var watcher = QuotaWatcher(threshold: 90)
    _ = watcher.events(for: limits(40))
    _ = watcher.events(for: limits(95))

    #expect(watcher.events(for: RateLimits()).isEmpty)
    #expect(watcher.events(for: limits(95)).isEmpty)
}
