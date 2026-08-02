import Foundation
import Testing

@testable import PerchKit

/// A tuning slider must never be able to put the panel somewhere unreachable.
@Test func tuningIsClamped() {
    var preferences = Preferences()
    preferences.notchWidthAdjustment = 500
    preferences.notchHeightAdjustment = -500

    #expect(preferences.sanitised.notchWidthAdjustment == 60)
    #expect(preferences.sanitised.notchHeightAdjustment == -12)
}

/// A ten-second timeout would hide every session almost immediately.
@Test func idleTimeoutIsClampedButNeverStillMeansNever() {
    var preferences = Preferences()
    preferences.idleTimeout = 5
    #expect(preferences.sanitised.idleTimeout == 60)

    preferences.idleTimeout = 0
    #expect(preferences.sanitised.idleTimeout == 0)
}

@Test func zeroTimeoutKeepsSessionsForever() {
    var tracker = SessionTracker(timeout: 0)
    tracker.record(id: "s1", kind: "PreToolUse", at: Date(timeIntervalSince1970: 0))
    tracker.prune(now: Date(timeIntervalSince1970: 10_000_000))

    #expect(tracker.sessions["s1"] != nil)
}

@Test func blockedLaunchersMatchRegardlessOfCase() {
    var preferences = Preferences()
    preferences.blockedLaunchers = ["com.Example.Helper"]

    #expect(preferences.blocks(launcher: "com.example.helper"))
    #expect(!preferences.blocks(launcher: "com.example.other"))
    #expect(!preferences.blocks(launcher: nil))
    #expect(!preferences.blocks(launcher: ""))
}

/// A global shortcut with no modifier would swallow that key in every app.
@Test func aShortcutNeedsARealModifier() {
    #expect(!ShortcutFormatter.isUsable(keyCode: 35, modifiers: 0))
    #expect(!ShortcutFormatter.isUsable(keyCode: 35, modifiers: 512))  // shift alone
    #expect(ShortcutFormatter.isUsable(keyCode: 35, modifiers: 4096))
    #expect(ShortcutFormatter.isUsable(keyCode: 35, modifiers: 256))
    // A key we cannot name is a key we cannot show.
    #expect(!ShortcutFormatter.isUsable(keyCode: 999, modifiers: 4096))
}

@Test func shortcutsAreDescribedLikeAMenuWould() {
    #expect(ShortcutFormatter.describe(keyCode: 35, modifiers: 4096 | 2048) == "⌃⌥P")
    #expect(ShortcutFormatter.describe(keyCode: 49, modifiers: 256) == "⌘Space")
}

/// AppKit and Carbon do not agree on which bit means what.
@Test func cocoaModifiersAreTranslatedToCarbon() {
    #expect(ShortcutFormatter.carbonModifiers(fromCocoa: 1 << 18) == 4096)  // control
    #expect(ShortcutFormatter.carbonModifiers(fromCocoa: 1 << 19) == 2048)  // option
    #expect(ShortcutFormatter.carbonModifiers(fromCocoa: 1 << 20) == 256)  // command
    #expect(ShortcutFormatter.carbonModifiers(fromCocoa: (1 << 18) | (1 << 19)) == 4096 | 2048)
}

/// A file written by an older build must not reset the settings it did know about.
@Test func preferencesWrittenByAnOlderVersionKeepTheirValues() throws {
    let raw = #"{"switcherKeyCode": 12, "notchWidthAdjustment": 8}"#.data(using: .utf8)!
    let preferences = try JSONDecoder().decode(Preferences.self, from: raw)

    #expect(preferences.switcherKeyCode == 12)
    #expect(preferences.notchWidthAdjustment == 8)
    #expect(preferences.switcherEnabled)
    #expect(preferences.idleTimeout == 30 * 60)
    #expect(preferences.blockedLaunchers.isEmpty)
}

/// English whatever the Mac says, and English for everyone who had Perch before this
/// setting existed — a file with no `language` key means "never chose", not "follow the
/// system". The alternative would switch the interface under people who had not asked.
@Test func englishIsTheDefaultAndAnOlderFileKeepsIt() throws {
    #expect(Preferences().language == .english)

    let raw = #"{"switcherKeyCode": 12}"#.data(using: .utf8)!
    #expect(try JSONDecoder().decode(Preferences.self, from: raw).language == .english)
}

/// `.system` is the absence of an override, so it names no locale to write. The other two
/// name exactly one — what goes into `AppleLanguages`.
@Test func onlyAChosenLanguageOverridesTheSystem() {
    #expect(AppLanguage.system.localeIdentifiers == nil)
    #expect(AppLanguage.english.localeIdentifiers == ["en"])
    #expect(AppLanguage.french.localeIdentifiers == ["fr"])
}

/// Saving clamps too, so a bad value cannot be written and then read back as gospel.
@Test func preferencesSurviveARoundTripThroughDisk() {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("perch-prefs-\(UUID().uuidString).json")

    var preferences = Preferences()
    preferences.switcherKeyCode = 12
    preferences.notchWidthAdjustment = 999
    preferences.blockedLaunchers = ["com.example.helper"]
    preferences.save(to: url)

    let loaded = Preferences.load(from: url)
    #expect(loaded.switcherKeyCode == 12)
    #expect(loaded.notchWidthAdjustment == 60)
    #expect(loaded.blockedLaunchers == ["com.example.helper"])

    try? FileManager.default.removeItem(at: url)
}

@Test func aMissingPreferencesFileGivesTheDefaults() {
    let preferences = Preferences.load(from: URL(fileURLWithPath: "/nonexistent/perch.json"))
    #expect(preferences.switcherEnabled)
    #expect(preferences.notchWidthAdjustment == 0)
}

@Test func clientInfoReadsTheLaunchingApp() {
    let info = ClientInfo.fromEnvironment([
        "TERM_PROGRAM": "ghostty", "__CFBundleIdentifier": "com.mitchellh.ghostty",
    ])
    #expect(info.launcher == "com.mitchellh.ghostty")
}

/// A settings file written before the density existed must not lose the settings it did
/// know about, and must land on the layout that matches what the panel used to draw.
@Test func aPreferencesFileWithoutALayoutKeepsTheOldPanel() throws {
    let old = Data(#"{"switcherEnabled":false,"idleTimeout":900,"betaUpdates":true}"#.utf8)
    let decoded = try JSONDecoder().decode(Preferences.self, from: old)

    #expect(decoded.layout == .detailed)
    #expect(!decoded.switcherEnabled)
    #expect(decoded.idleTimeout == 900)
    #expect(decoded.betaUpdates)
}

/// Perch is invisible when it is not running — no Dock icon, no menu bar item — so coming
/// back after a restart is the default, for a fresh install and for a settings file
/// written before the setting existed alike.
@Test func perchComesBackAfterARestartUnlessToldOtherwise() throws {
    #expect(Preferences().launchAtLogin)

    let old = Data(#"{"idleTimeout":900}"#.utf8)
    #expect(try JSONDecoder().decode(Preferences.self, from: old).launchAtLogin)

    let off = Data(#"{"launchAtLogin":false}"#.utf8)
    #expect(try !JSONDecoder().decode(Preferences.self, from: off).launchAtLogin)
}

@Test func cleanDropsWhatYouAlreadyKnowAndKeepsWhatChanged() {
    #expect(!PanelLayout.clean.showsPrompt)
    #expect(!PanelLayout.clean.showsTasks)
    #expect(PanelLayout.detailed.showsPrompt)
    #expect(PanelLayout.detailed.showsTasks)
    #expect(Preferences().layout == .detailed)
}
