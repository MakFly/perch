import Foundation
import Testing

@testable import PerchKit

private func home(_ build: (URL) throws -> Void) rethrows -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("perch-env-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try build(root)
    return root
}

private func write(_ text: String, to url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}

/// Onboarding that asks you to tick boxes about your own machine has not looked.
@Test func installedAgentsAreFoundByTheirConfigDirectory() throws {
    let root = home { dir in
        write("{}", to: dir.appendingPathComponent(".claude/settings.json"))
        write("{}", to: dir.appendingPathComponent(".codex/hooks.json"))
    }

    let agents = EnvironmentScan.run(home: root.path).filter { $0.kind == .agent }
    #expect(agents.map(\.name).sorted() == ["Claude Code", "Codex"])
    #expect(agents.allSatisfy { $0.isConfigured == false })

    try? FileManager.default.removeItem(at: root)
}

@Test func anAgentWithPerchHooksReadsAsConfigured() throws {
    let root = home { dir in
        write(
            #"{"hooks":{"Stop":[{"hooks":[{"command":"/x/perch-hook Stop"}]}]}}"#,
            to: dir.appendingPathComponent(".claude/settings.json"))
    }

    let claude = try #require(
        EnvironmentScan.run(home: root.path).first { $0.name == "Claude Code" })
    #expect(claude.isConfigured == true)

    try? FileManager.default.removeItem(at: root)
}

/// A directory that is not there is a tool that is not installed — not a tool that needs
/// configuring.
@Test func absentToolsAreNotReported() throws {
    let root = home { _ in }
    #expect(EnvironmentScan.run(home: root.path).filter { $0.kind == .agent }.isEmpty)
    try? FileManager.default.removeItem(at: root)
}

/// An app that greets you every launch is an app you learn to dismiss without reading.
@Test func onboardingOnlyAppearsOnAMachineThatWasNeverSetUp() throws {
    let fresh = home { dir in
        write("{}", to: dir.appendingPathComponent(".claude/settings.json"))
    }
    #expect(EnvironmentScan.needsOnboarding(home: fresh.path))

    let configured = home { dir in
        write(
            #"{"hooks":{"Stop":[{"hooks":[{"command":"/x/perch-hook Stop"}]}]}}"#,
            to: dir.appendingPathComponent(".claude/settings.json"))
    }
    #expect(!EnvironmentScan.needsOnboarding(home: configured.path))

    // No agent at all: there is nothing to onboard onto, so it stays quiet.
    let empty = home { _ in }
    #expect(!EnvironmentScan.needsOnboarding(home: empty.path))

    for dir in [fresh, configured, empty] {
        try? FileManager.default.removeItem(at: dir)
    }
}

/// One agent already wired up means this is not a first run, even if another is not.
@Test func oneConfiguredAgentIsEnoughToSkipOnboarding() throws {
    let root = home { dir in
        write(
            #"{"hooks":{"Stop":[{"hooks":[{"command":"/x/perch-hook Stop"}]}]}}"#,
            to: dir.appendingPathComponent(".claude/settings.json"))
        write("{}", to: dir.appendingPathComponent(".codex/hooks.json"))
    }
    #expect(!EnvironmentScan.needsOnboarding(home: root.path))
    try? FileManager.default.removeItem(at: root)
}

/// The recommended install is per project, so looking only at the agent's own config file
/// finds nothing and greets someone who set Perch up weeks ago.
@Test func aProjectOnlyInstallCountsAsSetUp() throws {
    let root = home { dir in
        write("{}", to: dir.appendingPathComponent(".claude/settings.json"))
    }
    let project = root.appendingPathComponent("work/.claude/settings.json")
    write(
        #"{"hooks":{"Stop":[{"hooks":[{"command":"/x/perch-hook Stop"}]}]}}"#, to: project)
    write(
        "[\"\(project.path)\"]",
        to: root.appendingPathComponent(".perch/hook-sites.json"))

    #expect(!EnvironmentScan.needsOnboarding(home: root.path))
    try? FileManager.default.removeItem(at: root)
}

/// A site recorded but since deleted is not evidence that Perch is set up.
@Test func aRecordedSiteThatIsGoneDoesNotCount() throws {
    let root = home { dir in
        write("{}", to: dir.appendingPathComponent(".claude/settings.json"))
        write(
            #"["/gone/project/.claude/settings.json"]"#,
            to: dir.appendingPathComponent(".perch/hook-sites.json"))
    }
    #expect(EnvironmentScan.needsOnboarding(home: root.path))
    try? FileManager.default.removeItem(at: root)
}
