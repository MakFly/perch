import Foundation
import Testing

@testable import PerchKit

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
private func later(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

/// Hooks present, sessions flowing: nothing to say.
@Test func aWorkingInstallSaysNothing() {
    let health = HookHealth(
        sitesChecked: 2, sitesWithHooks: 2, sessionsSeen: 3, runningSince: epoch)
    #expect(health.advice(now: later(600)) == .fine)
}

/// The two failures that look identical from the notch have opposite fixes, which is the
/// whole reason this exists.
@Test func hooksInstalledButUnusedMeansRestart() {
    let health = HookHealth(
        sitesChecked: 2, sitesWithHooks: 2, sessionsSeen: 0, runningSince: epoch)
    #expect(health.advice(now: later(600)) == .restartSessions)
}

@Test func aSiteThatLostItsHooksMeansReinstall() {
    let health = HookHealth(
        sitesChecked: 3, sitesWithHooks: 1, sessionsSeen: 5, runningSince: epoch)
    #expect(health.advice(now: later(600)) == .reinstallHooks(missing: 2))
}

@Test func nothingInstalledAnywhereSaysSo() {
    #expect(
        HookHealth(sitesChecked: 0, sitesWithHooks: 0, sessionsSeen: 0, runningSince: epoch)
            .advice(now: later(600)) == .notInstalled)
    #expect(
        HookHealth(sitesChecked: 2, sitesWithHooks: 0, sessionsSeen: 0, runningSince: epoch)
            .advice(now: later(600)) == .notInstalled)
}

/// A session that has done nothing in the first minute is not evidence of anything — you
/// may simply not have typed yet. Nagging then would be wrong every morning.
@Test func theWarningWaitsBeforeAppearing() {
    let health = HookHealth(
        sitesChecked: 1, sitesWithHooks: 1, sessionsSeen: 0, runningSince: epoch)

    #expect(health.advice(now: later(10)) == .fine)
    #expect(health.advice(now: later(HookHealth.quietPeriod + 1)) == .restartSessions)
}

/// A project deleted since is not a project that lost its hooks.
@Test func sitesThatNoLongerExistAreNotCounted() throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("perch-home-\(UUID().uuidString)")
    let claude = home.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    try #"{"hooks":{"Stop":[{"hooks":[{"command":"/x/perch-hook Stop"}]}]}}"#
        .write(
            to: claude.appendingPathComponent("settings.json"), atomically: true,
            encoding: .utf8)

    let perch = home.appendingPathComponent(".perch")
    try FileManager.default.createDirectory(at: perch, withIntermediateDirectories: true)
    try #"["/gone/project/.claude/settings.json"]"#.write(
        to: perch.appendingPathComponent("hook-sites.json"), atomically: true, encoding: .utf8)

    let health = HookWatcher.check(home: home.path, sessionsSeen: 1, runningSince: epoch)
    #expect(health.sitesChecked == 1)
    #expect(health.sitesWithHooks == 1)
    #expect(health.advice(now: later(600)) == .fine)

    try? FileManager.default.removeItem(at: home)
}

/// Hooks in a project *and* in the global file: Claude Code runs both, so everything
/// arrives twice. Perch drops the copies, which is exactly why this has to be reported —
/// nothing on screen would look wrong.
@Test func aProjectInstallOnTopOfTheGlobalOneIsDetected() throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("perch-home-\(UUID().uuidString)")
    let hooks = #"{"hooks":{"Stop":[{"hooks":[{"command":"/x/perch-hook Stop"}]}]}}"#

    let claude = home.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    try hooks.write(
        to: claude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

    let project = home.appendingPathComponent("work/app/.claude")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let projectSettings = project.appendingPathComponent("settings.json")
    try hooks.write(to: projectSettings, atomically: true, encoding: .utf8)

    let perch = home.appendingPathComponent(".perch")
    try FileManager.default.createDirectory(at: perch, withIntermediateDirectories: true)
    try #"["\#(projectSettings.path)"]"#.write(
        to: perch.appendingPathComponent("hook-sites.json"), atomically: true, encoding: .utf8)

    let health = HookWatcher.check(home: home.path, sessionsSeen: 4, runningSince: epoch)
    #expect(health.sitesWithHooks == 2)
    #expect(health.duplicatedSites == 1)
    #expect(health.advice(now: later(600)) == .installedTwice(sites: 1))

    // Uninstalling the project copy is the fix, and it has to show up as fine — not as a
    // site that lost its hooks.
    try FileManager.default.removeItem(at: projectSettings)
    let after = HookWatcher.check(home: home.path, sessionsSeen: 4, runningSince: epoch)
    #expect(after.duplicatedSites == 0)
    #expect(after.advice(now: later(600)) == .fine)

    try? FileManager.default.removeItem(at: home)
}

/// One install, in one place, is not two installs.
@Test func aSingleGlobalInstallIsNotADuplicate() {
    let health = HookHealth(
        sitesChecked: 1, sitesWithHooks: 1, sessionsSeen: 2, runningSince: epoch,
        duplicatedSites: 0)
    #expect(health.advice(now: later(600)) == .fine)
}

/// An empty panel outranks a doubled one: nothing arriving is the problem to fix first.
@Test func nothingArrivingOutranksEverythingArrivingTwice() {
    let health = HookHealth(
        sitesChecked: 2, sitesWithHooks: 2, sessionsSeen: 0, runningSince: epoch,
        duplicatedSites: 1)
    #expect(health.advice(now: later(600)) == .restartSessions)
}

/// The case this was written for: another tool rewrote settings.json and dropped us.
@Test func aStrippedSettingsFileIsDetected() throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("perch-home-\(UUID().uuidString)")
    let claude = home.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    try #"{"hooks":{"Stop":[{"hooks":[{"command":"/some/other/tool"}]}]}}"#
        .write(
            to: claude.appendingPathComponent("settings.json"), atomically: true,
            encoding: .utf8)

    let health = HookWatcher.check(home: home.path, sessionsSeen: 0, runningSince: epoch)
    #expect(health.sitesChecked == 1)
    #expect(health.sitesWithHooks == 0)
    #expect(health.advice(now: later(600)) == .notInstalled)

    try? FileManager.default.removeItem(at: home)
}
