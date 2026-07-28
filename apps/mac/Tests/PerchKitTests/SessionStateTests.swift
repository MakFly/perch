import Foundation
import Testing

@testable import PerchKit

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

@Test func stopMakesASessionIdleWithoutRemovingIt() {
    var tracker = SessionTracker()
    tracker.record(id: "s1", kind: "PreToolUse", cwd: "/lab/perch", at: epoch)
    #expect(tracker.workingCount == 1)

    tracker.record(id: "s1", kind: "Stop", at: epoch)
    #expect(tracker.sessions["s1"]?.status == .idle)
    #expect(tracker.workingCount == 0)
    #expect(tracker.sessions.count == 1)
}

/// A turn that ends in failure is still an ended turn. Before `StopFailure` was wired up
/// the notch kept spinning on a session that had already given up.
@Test func stopFailureEndsTheTurnToo() {
    var tracker = SessionTracker()
    tracker.record(id: "s1", kind: "PreToolUse", at: epoch)
    tracker.record(id: "s1", kind: "StopFailure", at: epoch)

    #expect(tracker.sessions["s1"]?.status == .failed)
    #expect(tracker.workingCount == 0)
}

@Test func sessionEndRemovesTheSession() {
    var tracker = SessionTracker()
    tracker.record(id: "s1", kind: "SessionStart", at: epoch)
    tracker.record(id: "s1", kind: "SessionEnd", at: epoch)

    #expect(tracker.sessions.isEmpty)
}

@Test func subagentsAreCountedAndNeverGoNegative() {
    var tracker = SessionTracker()
    tracker.record(id: "s1", kind: "SubagentStart", at: epoch)
    tracker.record(id: "s1", kind: "SubagentStart", at: epoch)
    #expect(tracker.subagentCount == 2)

    tracker.record(id: "s1", kind: "SubagentStop", at: epoch)
    #expect(tracker.subagentCount == 1)

    // Started before Perch was running, stops after: must not underflow.
    tracker.record(id: "s1", kind: "SubagentStop", at: epoch)
    tracker.record(id: "s1", kind: "SubagentStop", at: epoch)
    #expect(tracker.subagentCount == 0)
}

/// Nothing announces the end of compaction, so the next event has to clear it.
@Test func compactionIsClearedByTheNextEvent() {
    var tracker = SessionTracker()
    tracker.record(id: "s1", kind: "PreCompact", at: epoch)
    #expect(tracker.sessions["s1"]?.status == .compacting)
    #expect(tracker.workingCount == 1)

    tracker.record(id: "s1", kind: "PreToolUse", at: epoch)
    #expect(tracker.sessions["s1"]?.status == .runningTool)
    #expect(tracker.sessions["s1"]?.isWorking == true)
}

/// The states a hook can actually prove, in the order a turn goes through them.
@Test func aTurnMovesThroughTheStatesItsHooksReport() {
    var tracker = SessionTracker()

    tracker.record(id: "s1", kind: "UserPromptSubmit", prompt: "fix auth", at: epoch)
    #expect(tracker.sessions["s1"]?.status == .working)

    tracker.record(id: "s1", kind: "PermissionRequest", tool: "Bash", at: epoch)
    #expect(tracker.sessions["s1"]?.status == .needsApproval)
    #expect(tracker.sessions["s1"]?.status.needsYou == true)
    // Blocked on a person is not "working", whatever the notch badge counts.
    #expect(tracker.workingCount == 0)

    tracker.record(id: "s1", kind: "PreToolUse", detail: "npm run build", at: epoch)
    #expect(tracker.sessions["s1"]?.status == .runningTool)

    tracker.record(id: "s1", kind: "PostToolUse", at: epoch)
    // The tool is done and the model has the turn again — not idle, nothing was handed back.
    #expect(tracker.sessions["s1"]?.status == .working)

    tracker.record(id: "s1", kind: "Stop", at: epoch)
    #expect(tracker.sessions["s1"]?.status == .idle)
}

/// Approving the *asking* of a question was never the point, and the card says so: one
/// wants a decision, the other wants an answer.
@Test func aQuestionWaitsForAnAnswerRatherThanAnApproval() {
    var tracker = SessionTracker()

    tracker.record(id: "s1", kind: "PermissionRequest", tool: "AskUserQuestion", at: epoch)
    #expect(tracker.sessions["s1"]?.status == .waitingForAnswer)

    tracker.record(id: "s2", kind: "PermissionRequest", tool: "ExitPlanMode", at: epoch)
    #expect(tracker.sessions["s2"]?.status == .waitingForAnswer)
}

/// Claude Code raises notifications for several reasons; only one of them means the turn
/// has stopped on a person. The others must not knock the card off what it was showing.
@Test func onlyTheWaitingNotificationChangesTheStatus() {
    var tracker = SessionTracker()
    tracker.record(id: "s1", kind: "PreToolUse", at: epoch)

    tracker.record(
        id: "s1", kind: "Notification", message: "Claude needs your permission to use Bash",
        at: epoch)
    #expect(tracker.sessions["s1"]?.status == .runningTool)

    // The same state `Stop` produces. The notification is Claude Code noticing the fact,
    // not a second fact.
    tracker.record(
        id: "s1", kind: "Notification", message: "Claude is waiting for your input", at: epoch)
    #expect(tracker.sessions["s1"]?.status == .idle)
    #expect(tracker.sessions["s1"]?.status.needsYou == true)
}

/// Subagents are children now, not a tally: each carries what it was asked for and when it
/// started, which is the question you have ten minutes into a quiet card.
@Test func subagentsCarryTheirLabelAndTheirAge() {
    var tracker = SessionTracker()

    tracker.record(id: "s1", kind: "SubagentStart", subagentLabel: "code-reviewer", at: epoch)
    tracker.record(
        id: "s1", kind: "SubagentStart", subagentLabel: "  ",
        at: epoch.addingTimeInterval(30))

    let children = tracker.sessions["s1"]?.children ?? []
    #expect(children.count == 2)
    #expect(children.first?.label == "code-reviewer")
    // No label in the payload is not a reason to invent one.
    #expect(children.last?.label == "subagent")
    #expect(children.last?.startedAt == epoch.addingTimeInterval(30))

    // Oldest first: the events carry no id to pair a stop with its own start, so the only
    // honest reading is that one of them finished.
    tracker.record(id: "s1", kind: "SubagentStop", at: epoch.addingTimeInterval(60))
    #expect(tracker.sessions["s1"]?.children.map(\.label) == ["subagent"])
    #expect(tracker.subagentCount == 1)
}

@Test func cwdAndDetailSurviveEventsThatDoNotCarryThem() {
    var tracker = SessionTracker()
    tracker.record(id: "s1", kind: "PreToolUse", cwd: "/lab/perch", detail: "npm run build", at: epoch)
    tracker.record(id: "s1", kind: "Stop", at: epoch)

    #expect(tracker.sessions["s1"]?.cwd == "/lab/perch")
    #expect(tracker.sessions["s1"]?.lastDetail == "npm run build")
    #expect(tracker.sessions["s1"]?.projectName == "perch")
}

/// The card's activity line should say what the agent is doing, not name the hook that
/// fired. "SubagentStart" is not something anyone wants to read there.
@Test func lifecycleEventsDoNotOverwriteTheActivityLine() {
    var tracker = SessionTracker()
    tracker.record(id: "s1", kind: "PreToolUse", detail: "src/middleware.ts", at: epoch)
    tracker.record(id: "s1", kind: "SubagentStart", detail: "SubagentStart", at: epoch)

    #expect(tracker.sessions["s1"]?.lastDetail == "src/middleware.ts")
    #expect(tracker.sessions["s1"]?.subagents == 1)
}

@Test func theCardTitleFollowsTheLatestPrompt() {
    var tracker = SessionTracker()
    tracker.record(id: "s1", kind: "UserPromptSubmit", cwd: "/lab/perch", prompt: "fix auth bug", at: epoch)
    #expect(tracker.sessions["s1"]?.prompt == "fix auth bug")

    tracker.record(id: "s1", kind: "UserPromptSubmit", prompt: "now ship it", at: epoch)
    #expect(tracker.sessions["s1"]?.prompt == "now ship it")

    // Events without a prompt must not wipe the one we have.
    tracker.record(id: "s1", kind: "PreToolUse", detail: "npm test", at: epoch)
    #expect(tracker.sessions["s1"]?.prompt == "now ship it")
}

/// Prompts are whole messages; the card has one line.
@Test func promptsAreCondensedToTheirFirstMeaningfulLine() {
    #expect(SessionTracker.condense("\n\n  fix the auth bug  \n\nand then deploy") == "fix the auth bug")
    #expect(SessionTracker.condense(String(repeating: "a", count: 100)).count == 73)
    #expect(SessionTracker.condense(String(repeating: "a", count: 100)).hasSuffix("…"))
}

@Test func terminalIdentityIsRememberedAndPrettyPrinted() {
    var tracker = SessionTracker()
    tracker.record(
        id: "s1", kind: "SessionStart",
        client: ClientInfo(terminal: "iTerm.app", session: "w0t1p0"), at: epoch)

    #expect(tracker.sessions["s1"]?.client?.displayName == "iTerm")

    // An event from a hook with no terminal in its environment must not erase it.
    tracker.record(id: "s1", kind: "PreToolUse", client: ClientInfo(), at: epoch)
    #expect(tracker.sessions["s1"]?.client?.displayName == "iTerm")
}

@Test func terminalNamesAreReadable() {
    #expect(ClientInfo(terminal: "Apple_Terminal").displayName == "Terminal")
    #expect(ClientInfo(terminal: "ghostty").displayName == "Ghostty")
    #expect(ClientInfo(terminal: "WarpTerminal").displayName == "Warp")
    #expect(ClientInfo(terminal: "vscode").displayName == "VS Code")
    #expect(ClientInfo(terminal: nil).displayName == nil)
}

@Test func clientInfoIsReadFromTheHooksEnvironment() {
    let info = ClientInfo.fromEnvironment([
        "TERM_PROGRAM": "ghostty", "ITERM_SESSION_ID": "abc", "TMUX_PANE": "%3",
    ])
    #expect(info.terminal == "ghostty")
    #expect(info.session == "abc")
    #expect(info.tmuxPane == "%3")
}

/// Closed terminals never send `SessionEnd`.
@Test func staleSessionsAgeOut() {
    var tracker = SessionTracker(timeout: 60)
    tracker.record(id: "old", kind: "PreToolUse", at: epoch)
    tracker.record(id: "fresh", kind: "PreToolUse", at: epoch.addingTimeInterval(120))

    #expect(tracker.sessions["old"] == nil)
    #expect(tracker.sessions["fresh"] != nil)
}

// MARK: - Permission mode

/// The chip exists to say what an agent may do while nobody is watching, so the plain
/// default earns nothing and everything else earns something.
@Test func onlyANonDefaultPermissionModeEarnsAChip() {
    func badge(_ mode: String?) -> String? {
        var session = SessionSnapshot(
            id: "s", cwd: nil, lastEvent: .now, lastDetail: "", status: .working,
            subagents: 0, startedAt: .now)
        session.permissionMode = mode
        return session.permissionBadge
    }

    #expect(badge(nil) == nil)
    #expect(badge("") == nil)
    #expect(badge("default") == nil)
    #expect(badge("bypassPermissions") == "BYPASS")
    #expect(badge("acceptEdits") == "EDITS")
    #expect(badge("plan") == "PLAN")
}

/// The documented four are not the whole vocabulary — a session running under cmux
/// reports `auto`. A whitelist would have dropped it, and a mode Perch has never heard of
/// is exactly the one worth showing.
@Test func anUnknownPermissionModeIsShownRatherThanHidden() {
    var session = SessionSnapshot(
        id: "s", cwd: nil, lastEvent: .now, lastDetail: "", status: .working,
        subagents: 0, startedAt: .now)

    session.permissionMode = "auto"
    #expect(session.permissionBadge == "AUTO")
    #expect(session.permissionIsPermissive)

    session.permissionMode = "somethingEntirelyNew"
    #expect(session.permissionBadge == "SOMETHIN")

    // "plan" narrows what an agent may do, so it must not read as a warning.
    session.permissionMode = "plan"
    #expect(!session.permissionIsPermissive)
}

/// The panel is a list you read while it updates, so its order has to be one that does not
/// move. Sorting by the last event meant every tool call in any session promoted that card
/// to the top — six agents reshuffled the list several times a second.
@Test func theOrderDoesNotMoveWhenSomethingHappens() {
    var tracker = SessionTracker()
    tracker.record(id: "first", kind: "SessionStart", at: epoch)
    tracker.record(id: "second", kind: "SessionStart", at: epoch.addingTimeInterval(60))
    tracker.record(id: "third", kind: "SessionStart", at: epoch.addingTimeInterval(120))

    let order = tracker.active.map(\.id)
    #expect(order == ["first", "second", "third"])

    // The oldest session does something. It stays exactly where it was.
    tracker.record(id: "first", kind: "PreToolUse", at: epoch.addingTimeInterval(300))
    #expect(tracker.active.map(\.id) == order)

    // So does a turn ending, which is the other event that used to move a card.
    tracker.record(id: "third", kind: "Stop", at: epoch.addingTimeInterval(360))
    #expect(tracker.active.map(\.id) == order)
}

/// Two sessions started in the same instant would otherwise be ordered by whatever the
/// dictionary felt like that frame — the same bug, in miniature.
@Test func sessionsStartedTogetherStillHaveAFixedOrder() {
    var tracker = SessionTracker()
    tracker.record(id: "a", kind: "SessionStart", at: epoch)
    tracker.record(id: "b", kind: "SessionStart", at: epoch)

    let order = tracker.active.map(\.id)
    for _ in 0..<20 {
        #expect(tracker.active.map(\.id) == order)
    }
}

/// A list that loses a row while it is being read is worse than one a few seconds out of
/// date: everything below the gap jumps up, and the card you were reading is now a
/// different card.
@Test func nothingLeavesTheListWhileSomeoneIsReadingIt() {
    var tracker = SessionTracker()
    tracker.timeout = 60
    tracker.record(id: "a", kind: "SessionStart", at: epoch)
    tracker.record(id: "b", kind: "SessionStart", at: epoch)
    tracker.record(id: "c", kind: "SessionStart", at: epoch)

    tracker.hold()
    tracker.record(id: "b", kind: "SessionEnd", at: epoch.addingTimeInterval(10))
    // And one that simply went quiet for longer than the timeout.
    tracker.record(id: "c", kind: "PreToolUse", at: epoch.addingTimeInterval(600))

    #expect(tracker.active.map(\.id) == ["a", "b", "c"])

    // Look away and everything that was withheld happens at once: `b` ended, and `a` has
    // now been silent for ten minutes.
    tracker.release(now: epoch.addingTimeInterval(600))
    #expect(tracker.active.map(\.id) == ["c"])
}

/// A session starting appends. It must not push the list someone is reading downward.
@Test func aNewSessionArrivesAtTheEnd() {
    var tracker = SessionTracker()
    tracker.record(id: "first", kind: "SessionStart", at: epoch)
    tracker.record(id: "second", kind: "SessionStart", at: epoch.addingTimeInterval(60))
    #expect(tracker.active.map(\.id) == ["first", "second"])

    tracker.record(id: "third", kind: "SessionStart", at: epoch.addingTimeInterval(120))
    #expect(tracker.active.map(\.id) == ["first", "second", "third"])
}

/// Forgetting used to be a side effect of remembering: `prune` ran at the end of `record`,
/// so the clock only ticked when another session spoke. The moment stale rows pile up is
/// the moment everything has gone quiet — exactly when nothing was left to trigger it.
@Test func aSilentSessionIsForgottenWithoutAnotherOneSpeaking() {
    var tracker = SessionTracker()
    tracker.timeout = 30 * 60
    tracker.record(id: "abandoned", kind: "Stop", at: epoch)

    // Nothing else happens. Ever. The sweep is what has to remove it.
    tracker.prune(now: epoch.addingTimeInterval(31 * 60))
    #expect(tracker.active.isEmpty)
}

/// The sweep runs twice a minute for the life of the process, so it must be silent when it
/// has nothing to do — otherwise it republishes the whole roster forever.
@Test func aSweepThatRemovesNothingChangesNothing() {
    var tracker = SessionTracker()
    tracker.timeout = 30 * 60
    tracker.record(id: "busy", kind: "PreToolUse", at: epoch)

    let before = tracker.sessions
    tracker.prune(now: epoch.addingTimeInterval(60))
    #expect(tracker.sessions == before)
}

/// Two sessions in identical silence must be reported identically. They were not: `Stop`
/// gave `idle`, the stall notification gave `waitingForInput`, and only the second counted
/// in the notch's amber — so which one you got depended on whether Claude Code happened to
/// notice.
@Test func aFinishedTurnIsWaitingOnYouWhetherOrNotClaudeSaidSo() {
    var tracker = SessionTracker()
    tracker.record(id: "quiet", kind: "PreToolUse", at: epoch)
    tracker.record(id: "quiet", kind: "Stop", at: epoch)

    tracker.record(id: "nagged", kind: "PreToolUse", at: epoch)
    tracker.record(id: "nagged", kind: "Stop", at: epoch)
    tracker.record(
        id: "nagged", kind: "Notification", message: "Claude is waiting for your input",
        at: epoch)

    #expect(tracker.sessions["quiet"]?.status == tracker.sessions["nagged"]?.status)
    #expect(tracker.sessions["quiet"]?.status.needsYou == true)
    #expect(tracker.workingCount == 0)
}
