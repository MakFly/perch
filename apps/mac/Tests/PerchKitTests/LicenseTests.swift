import Foundation
import Testing

@testable import PerchKit

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
private func days(_ count: Int, after date: Date = epoch) -> Date {
    date.addingTimeInterval(Double(count) * 86_400)
}

@Test func aFreshInstallIsInTrial() {
    let record = LicenseRecord(trialStartedAt: epoch)
    #expect(License.state(for: record, now: epoch) == .trial(daysLeft: License.trialDays))
    #expect(License.state(for: record, now: epoch).isEntitled)
}

@Test func theTrialRunsOut() {
    let record = LicenseRecord(trialStartedAt: epoch)
    #expect(
        License.state(for: record, now: days(License.trialDays - 1)) == .trial(daysLeft: 1))
    #expect(License.state(for: record, now: days(License.trialDays)) == .trialExpired)
    #expect(!License.state(for: record, now: days(License.trialDays)).isEntitled)
}

@Test func anActivatedCopyIsLicensed() {
    let record = LicenseRecord(
        key: "K", instanceId: "i", seats: 2, activatedAt: epoch, lastVerifiedAt: epoch,
        trialStartedAt: epoch)
    #expect(License.state(for: record, now: epoch) == .licensed(seats: 2))
}

/// Someone who paid should not lose the app on a plane.
@Test func anUnverifiedLicenceKeepsWorkingThroughTheGrace() {
    let record = LicenseRecord(
        key: "K", instanceId: "i", activatedAt: epoch, lastVerifiedAt: epoch,
        trialStartedAt: epoch)

    #expect(License.state(for: record, now: days(10)) == .licensedOffline(since: epoch))
    #expect(License.state(for: record, now: days(10)).isEntitled)

    // Past the grace it stops, but says why rather than pretending the trial came back.
    let expired = License.state(for: record, now: days(License.offlineGraceDays + 1))
    #expect(!expired.isEntitled)
    if case .invalid = expired {} else { Issue.record("expected .invalid, got \(expired)") }
}

/// The failure mode of licensing should always be "too generous".
@Test func aCorruptRecordStartsAFreshTrialRatherThanLockingTheApp() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("perch-licence-\(UUID().uuidString).json")
    try "not json".write(to: url, atomically: true, encoding: .utf8)

    let record = LicenseRecord.load(from: url)
    #expect(record.key == nil)
    #expect(License.state(for: record).isEntitled)

    try? FileManager.default.removeItem(at: url)
}

/// The rule the whole design rests on: nothing on the approval path is gated.
@Test func noFeatureGateTouchesTheApprovalPath() {
    let names = License.Feature.allCases.map(\.rawValue)
    #expect(!names.contains { $0.localizedCaseInsensitiveContains("approv") })
    #expect(!names.contains { $0.localizedCaseInsensitiveContains("permission") })
    #expect(!names.contains { $0.localizedCaseInsensitiveContains("question") })
    #expect(Set(names) == ["leaderboard", "remoteHosts", "switcher", "soundPacks"])
}

@Test func featuresFollowEntitlement() {
    let trial = LicenseState.trial(daysLeft: 3)
    let over = LicenseState.trialExpired

    for feature in License.Feature.allCases {
        #expect(License.allows(feature, trial))
        #expect(!License.allows(feature, over))
    }
}

@Test func stateLabelsReadLikeSentences() {
    #expect(LicenseState.trial(daysLeft: 1).label == "Trial · 1 day left")
    #expect(LicenseState.trial(daysLeft: 4).label == "Trial · 4 days left")
    #expect(LicenseState.licensed(seats: 1).label == "Licensed")
    #expect(LicenseState.licensed(seats: 3).label == "Licensed · 3 Macs")
}

/// A key travels in a form body, so anything in it must survive the trip.
@Test func keysAreEscapedForTheWire() {
    #expect(LemonSqueezyVendor.escape("ABC-123") == "ABC%2D123")
    #expect(!LemonSqueezyVendor.escape("a&b=c").contains("&"))
    #expect(!LemonSqueezyVendor.escape("a&b=c").contains("="))
}
