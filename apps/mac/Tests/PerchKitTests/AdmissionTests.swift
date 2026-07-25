import Foundation
import Testing

@testable import PerchKit

@Test func directoryRulesMatchAnywhereInThePath() {
    let rule = AdmissionRule(field: .directory, match: .contains, pattern: "/scratch/")
    #expect(rule.matches(directory: "/Users/kevin/scratch/thing", prompt: nil))
    #expect(!rule.matches(directory: "/Users/kevin/lab/perch", prompt: nil))
}

@Test func promptRulesCanAnchorAtTheStart() {
    let rule = AdmissionRule(field: .prompt, match: .prefix, pattern: "## Memory Writing")
    #expect(rule.matches(directory: nil, prompt: "## Memory Writing Agent\nrun"))
    #expect(!rule.matches(directory: nil, prompt: "please read ## Memory Writing Agent"))
}

/// Paths and prompts are typed by humans; case is not a signal.
@Test func matchingIgnoresCase() {
    let rule = AdmissionRule(field: .directory, match: .contains, pattern: "/Scratch/")
    #expect(rule.matches(directory: "/users/kevin/SCRATCH/x", prompt: nil))
}

@Test func disabledOrEmptyRulesNeverMatch() {
    let disabled = AdmissionRule(
        field: .directory, match: .contains, pattern: "/x/", enabled: false)
    #expect(!disabled.matches(directory: "/x/", prompt: nil))

    let empty = AdmissionRule(field: .directory, match: .contains, pattern: "")
    #expect(!empty.matches(directory: "/anything", prompt: nil))
}

/// A rule on a field the session has nothing for must not hide it. Silently dropping a
/// session someone wanted is the expensive mistake here.
@Test func aRuleOnAMissingFieldDoesNotMatch() {
    let rule = AdmissionRule(field: .prompt, match: .contains, pattern: "memory")
    #expect(!rule.matches(directory: "/lab/memory-service", prompt: nil))
}

@Test func presetsShipDisabled() {
    let policy = AdmissionPolicy()
    #expect(!policy.presetRules.isEmpty)
    #expect(policy.presetRules.allSatisfy { !$0.enabled })
    #expect(!policy.isSilenced(directory: "/lab/x", prompt: "## Memory Writing Agent"))
}

@Test func enablingAPresetSilencesIt() {
    var policy = AdmissionPolicy()
    policy.setEnabled(true, id: "preset.claude-mem")
    #expect(policy.isSilenced(directory: "/lab/x", prompt: "## Memory Writing Agent\ngo"))
    #expect(!policy.isSilenced(directory: "/lab/x", prompt: "fix the auth bug"))
}

@Test func duplicatePatternsAreNotAddedTwice() {
    var policy = AdmissionPolicy(rules: [])
    policy.add(AdmissionRule(field: .directory, match: .contains, pattern: "/scratch/"))
    policy.add(AdmissionRule(field: .directory, match: .contains, pattern: "/SCRATCH/"))
    #expect(policy.custom.count == 1)
}

@Test func presetsCannotBeRemoved() {
    var policy = AdmissionPolicy()
    let count = policy.rules.count
    policy.remove(id: "preset.claude-mem")
    #expect(policy.rules.count == count)
}

/// Shown live while typing, so nobody commits to a rule that hides everything.
@Test func matchCountPreviewsWhatARuleWouldHide() {
    let policy = AdmissionPolicy()
    let sessions: [(directory: String?, prompt: String?)] = [
        ("/lab/perch", "fix auth"),
        ("/lab/scratch/a", "anything"),
        ("/lab/scratch/b", nil),
    ]
    let rule = AdmissionRule(field: .directory, match: .contains, pattern: "/scratch/")
    #expect(policy.matchCount(of: rule, in: sessions) == 2)
}

/// A file written by an older version must still gain presets added since.
@Test func loadingMergesInNewPresets() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("perch-admission-\(UUID().uuidString).json")
    let old = AdmissionPolicy(rules: [
        AdmissionRule(field: .directory, match: .contains, pattern: "/mine/")
    ])
    old.save(to: url)

    let loaded = AdmissionPolicy.load(from: url)
    #expect(loaded.custom.count == 1)
    #expect(loaded.presetRules.count == AdmissionPolicy.presets.count)
    try? FileManager.default.removeItem(at: url)
}

/// A filter that silently stops filtering is worse than one that never started.
@Test func aMissingFileFallsBackToPresets() {
    let url = URL(fileURLWithPath: "/nonexistent/perch/admission.json")
    #expect(AdmissionPolicy.load(from: url).rules.count == AdmissionPolicy.presets.count)
}
