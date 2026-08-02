import Foundation

/// What a session is doing right now, as far as the hooks can tell.
///
/// Claude Code never says "I am idle" — it says `Stop`, and silence afterwards. Every
/// state here is therefore inferred from the last event, which is why the transitions
/// live in one reducer instead of being spread across the UI.
/// Only states a hook can actually prove are here. "Thinking" is not among them: nothing
/// distinguishes a model composing a reply from a model about to call a tool, and a label
/// that is right half the time is worse than one that is coarse and always true.
public enum SessionStatus: String, Sendable, Codable {
    /// The model has the turn, with no tool in flight.
    case working
    /// Between `PreToolUse` and its result. Almost all visible time is spent here, and it
    /// is the state where the command on the card is the thing to read.
    case runningTool
    /// A tool call is held, waiting for someone to allow or deny it.
    case needsApproval
    /// A question or a plan is on screen, waiting for an answer rather than a decision.
    case waitingForAnswer
    /// The turn is over. Nothing is blocked, nothing is owed — it is done.
    ///
    /// There used to be two of these. `Stop` produced `idle`, and the notification Claude
    /// Code raises when a turn stalls produced `waitingForInput` — the same situation, the
    /// same next move, two states, two sentences, and only one of them counted in the
    /// notch's amber. Which of the two you got depended on whether a notification happened
    /// to fire, so two sessions sitting in identical silence were reported differently.
    case idle
    /// The turn ended on a failure.
    case failed
    /// Context is being compacted, which can take a while and otherwise reads as a hang.
    case compacting

    /// Something is blocked on a person, and can be unblocked from here. These are the
    /// states worth crossing the room for, and the ones the panel colours ahead of
    /// everything else.
    ///
    /// A finished turn is deliberately not one of them. `idle` was briefly counted here, on
    /// the reasoning that a turn which has ended is waiting on you — which is true and
    /// useless: every turn ends, so every session would spend most of its life amber, and
    /// an alert that is always on is not an alert. What earns the colour is a request held
    /// against a blocked CLI. Done is done.
    public var needsYou: Bool {
        switch self {
        case .needsApproval, .waitingForAnswer: return true
        case .working, .runningTool, .idle, .failed, .compacting: return false
        }
    }
}

/// One subagent running under a session — a fan-out `Task` call, or a member of an Agent
/// Team.
///
/// A count answered "how many"; it never answered "how long has that one been going",
/// which is the question you actually have when a session has been busy for ten minutes.
public struct SubagentRun: Sendable, Equatable, Identifiable {
    public let id = UUID()
    public var label: String
    public var startedAt: Date

    public init(label: String, startedAt: Date) {
        self.label = label
        self.startedAt = startedAt
    }
}

public struct SessionSnapshot: Sendable, Equatable {
    /// Public so the off-screen panel preview can fabricate one per case the card has to
    /// handle. Nothing else outside the module builds these — they come from the tracker.
    public init(
        id: String, cwd: String?, lastEvent: Date, lastDetail: String, status: SessionStatus,
        subagents: Int, startedAt: Date
    ) {
        self.id = id
        self.cwd = cwd
        self.lastEvent = lastEvent
        self.lastDetail = lastDetail
        self.status = status
        // The preview builds snapshots by count rather than by name, which is all a
        // fabricated card needs.
        self.children = (0..<max(0, subagents)).map {
            SubagentRun(label: "subagent \($0 + 1)", startedAt: lastEvent)
        }
        self.startedAt = startedAt
    }

    public var id: String
    public var cwd: String?
    public var lastEvent: Date
    public var lastDetail: String
    public var status: SessionStatus
    /// Subagents currently running under this session — fan-out `Task` calls and Agent
    /// Team members both report through `SubagentStart` / `SubagentStop`.
    ///
    /// Oldest first, and closed in that order: the events carry no id to pair a stop with
    /// its own start, so the only honest reading is that one of them finished. The count
    /// stays right, which is what the notch and the card both show.
    public var children: [SubagentRun] = []

    /// How many are running. Kept as the name every caller already used.
    public var subagents: Int { children.count }
    /// What the user last asked. This is what makes a card identifiable at a glance:
    /// "fix auth bug" says more than a session id ever will.
    public var prompt: String?
    /// Where it is running, for the card's chip and for a future jump.
    public var client: ClientInfo?
    /// When the session was first seen, which is what the card's age counts from.
    public var startedAt: Date
    /// Which CLI this is. Two agents in the same project are otherwise indistinguishable.
    public var agent: Agent = .claude
    /// The name Claude Code gave this session, read from its own transcript.
    public var aiTitle: String?
    /// Where that transcript is, so the last turn can be re-read while the session runs
    /// rather than only when a hook happens to fire.
    public var transcriptPath: String?
    /// The last exchange: what was asked, and what came back. `nil` until a transcript has
    /// been read — a card without it is the card Perch shipped before, not a broken one.
    public var turn: TranscriptTurn?
    /// The session's permission mode, as Claude Code reports it on every hook.
    public var permissionMode: String?

    /// The short, shouted form for the card — and only when it is worth shouting.
    ///
    /// Anything that is not the plain default earns a chip, because every other mode
    /// changes what an agent may do while nobody is watching, which is the whole reason to
    /// look at a panel instead of a terminal.
    ///
    /// Deliberately not a whitelist. The vocabulary is Claude Code's and it is wider than
    /// the documented four — a session running under cmux reports `auto`, which a
    /// whitelist would have silently dropped. An unrecognised mode is shown as it is
    /// spelled rather than hidden: a mode Perch has never heard of is exactly the one
    /// worth seeing.
    public var permissionBadge: String? {
        guard let mode = permissionMode?.trimmingCharacters(in: .whitespaces), !mode.isEmpty,
            mode != "default"
        else { return nil }

        switch mode {
        case "bypassPermissions": return "BYPASS"
        case "acceptEdits": return "EDITS"
        default: return String(mode.prefix(8)).uppercased()
        }
    }

    /// True for the modes that let an agent act without being asked. The chip is tinted
    /// from this: "plan" is a restriction and reads as information, "bypass" is the
    /// opposite and has to read as a warning.
    public var permissionIsPermissive: Bool {
        switch permissionMode {
        case "bypassPermissions", "acceptEdits", "auto": return true
        default: return false
        }
    }

    public var projectName: String? {
        cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// Everything that proceeds without you. Compaction counts — it is unattended work —
    /// and so does a tool in flight, which is where a busy session spends most of its time.
    /// The states that are blocked on a person deliberately do not.
    public var isWorking: Bool {
        status == .working || status == .runningTool || status == .compacting
    }

    /// The card's heading: the prompt if we have one, the project otherwise.
    /// What the card calls this session. Claude Code's own name first — it is the one you
    /// will see again in `claude --resume`, so two places agreeing beats Perch inventing
    /// a second name for the same work.
    public var title: String {
        if let aiTitle, !aiTitle.isEmpty { return aiTitle }
        if let prompt, !prompt.isEmpty { return prompt }
        return projectName ?? "session"
    }
}

/// The session state machine, kept pure so it can be tested without a running app.
public struct SessionTracker: Sendable {
    /// A session with no hook traffic for this long is treated as gone. Terminals that
    /// are closed outright never send `SessionEnd`.
    public var timeout: TimeInterval

    public private(set) var sessions: [String: SessionSnapshot] = [:]

    public init(timeout: TimeInterval = 30 * 60) {
        self.timeout = timeout
    }

    /// Attaches a freshly read turn. Silent when the session is gone: the read that
    /// produced it started while it was still on screen.
    public mutating func setTurn(_ turn: TranscriptTurn, for id: String) {
        guard var session = sessions[id] else { return }
        session.turn = turn
        sessions[id] = session
    }

    /// Records a session Perch is *watching* rather than being told about.
    ///
    /// Everything below arrives as a hook: an event name, which the switch at the end turns
    /// into a state. Codex desktop sessions arrive as a file being written — the reader has
    /// already worked out the state, and there is no event to name. Passing one anyway meant
    /// choosing a hook whose side effects happened to be right, and the two that mapped to
    /// the states needed here, `UserPromptSubmit` and `Stop`, are both in `lifecycleKinds`:
    /// their detail is deliberately dropped, because "SubagentStart" is not what a card
    /// should say. A watched session would have lost its activity line to that rule.
    ///
    /// So the state comes in as a state. Everything else — the merge, the hold, the pruning
    /// — is what `record` does, because a card should not be able to tell where it came from.
    public mutating func observe(
        id: String,
        status: SessionStatus,
        cwd: String? = nil,
        detail: String = "",
        agent: Agent? = nil,
        aiTitle: String? = nil,
        at date: Date = .now
    ) {
        var session =
            sessions[id]
            ?? SessionSnapshot(
                id: id, cwd: cwd, lastEvent: date, lastDetail: detail,
                status: status, subagents: 0, startedAt: date)

        session.cwd = cwd ?? session.cwd
        session.lastEvent = date
        if !detail.isEmpty { session.lastDetail = detail }
        if let agent { session.agent = agent }
        if let aiTitle, !aiTitle.isEmpty { session.aiTitle = aiTitle }
        session.status = status

        sessions[id] = session
        if holdsSteady, status != .idle { heldVisible.insert(id) }
        prune(now: date)
    }

    /// The request this session was blocked on has been resolved.
    ///
    /// A session enters `needsApproval` or `waitingForAnswer` on a `PermissionRequest` and
    /// used to leave it only on the *next* hook — which normally arrives, because answering
    /// runs the tool. Normally. A question answered in the terminal, a request that expired,
    /// a session interrupted at the prompt, Perch quitting: in all of those the decision is
    /// resolved and no further event ever comes, so the card sat on "waiting for you"
    /// permanently. The panel said a session was blocked when nothing was.
    ///
    /// So the resolution itself says so. `working` rather than `idle`, for the same reason
    /// `PostToolUse` does: the answer went back to the model, and the model has the turn —
    /// nothing has been handed to a person yet.
    ///
    /// Only lifts a wait. Anything else is a later event that already knows better than
    /// this one — a decision resolving while the session has moved on must not drag it
    /// backwards.
    public mutating func answered(id: String, at date: Date = .now) {
        guard var session = sessions[id], session.status.needsYou else { return }
        session.status = .working
        session.lastEvent = date
        sessions[id] = session
    }

    public mutating func record(
        id: String,
        kind: String,
        cwd: String? = nil,
        detail: String = "",
        prompt: String? = nil,
        client: ClientInfo? = nil,
        agent: Agent? = nil,
        aiTitle: String? = nil,
        transcriptPath: String? = nil,
        turn: TranscriptTurn? = nil,
        permissionMode: String? = nil,
        /// The tool the event is about. `PermissionRequest` carries `AskUserQuestion` or
        /// `ExitPlanMode` when what is waiting is an answer rather than a decision, and
        /// those read differently on a card.
        tool: String? = nil,
        /// A `Notification`'s text, which is the only place Claude Code says out loud that
        /// it is stalled on the user rather than working.
        message: String? = nil,
        /// What a subagent is, when the payload says. Fan-out `Task` calls carry the type
        /// they were asked for.
        subagentLabel: String? = nil,
        at date: Date = .now
    ) {
        if kind == "SessionEnd" {
            remove(id: id)
            return
        }

        var session =
            sessions[id]
            ?? SessionSnapshot(
                id: id, cwd: cwd, lastEvent: date, lastDetail: detail,
                status: .working, subagents: 0, startedAt: date)

        session.cwd = cwd ?? session.cwd
        session.lastEvent = date
        // Lifecycle events carry no detail worth showing — letting them through put
        // "SubagentStart" on the card where the file being edited belongs.
        if !detail.isEmpty, !Self.lifecycleKinds.contains(kind) { session.lastDetail = detail }
        // A new prompt replaces the old one: the card should describe the current task,
        // not the one it opened with.
        if let prompt, !prompt.isEmpty { session.prompt = Self.condense(prompt) }
        if let client, client != ClientInfo() { session.client = client }
        if let agent { session.agent = agent }
        // The title is refined as the session goes, so a later one replaces an earlier.
        if let aiTitle, !aiTitle.isEmpty { session.aiTitle = aiTitle }
        if let transcriptPath, !transcriptPath.isEmpty { session.transcriptPath = transcriptPath }
        // A turn is only ever replaced by a newer reading of the same file, never blanked:
        // a hook that fires between two reads would otherwise clear the panel for a frame.
        if let turn { session.turn = turn }
        // Toggled mid-session with shift+tab, so the latest event is the truth.
        if let permissionMode, !permissionMode.isEmpty { session.permissionMode = permissionMode }

        switch kind {
        case "SubagentStart":
            session.children.append(
                SubagentRun(label: Self.subagentName(subagentLabel), startedAt: date))
            session.status = .working
        case "SubagentStop":
            // Oldest first, and never below empty: a subagent that started before Perch
            // did still stops, and there is nothing of its own to close.
            if !session.children.isEmpty { session.children.removeFirst() }
        case "PreCompact":
            session.status = .compacting
        case "Stop":
            session.status = .idle
        case "StopFailure":
            session.status = .failed
        case "PermissionRequest":
            // The tool being asked about decides which kind of waiting this is: a command
            // wants a decision, a question wants an answer, and they are not the same
            // interruption.
            session.status = Self.answerTools.contains(tool ?? "") ? .waitingForAnswer : .needsApproval
        case "Notification":
            // Claude Code raises these for several reasons; only one of them means the
            // turn has stopped and is waiting on a person — and it says nothing `Stop` did
            // not already say, so it lands on the same state.
            session.status =
                Self.saysWaitingForInput(message ?? detail) ? .idle : session.status
        case "PreToolUse":
            session.status = .runningTool
        case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
            // The tool is done; the model has the turn again. Not `idle` — nothing has
            // been handed back yet.
            session.status = .working
        default:
            // Anything else is the session doing something, which also ends compaction —
            // there is no event announcing that compaction finished.
            session.status = .working
        }

        sessions[id] = session
        // A session that turns up while the list is held earns its row for the rest of the
        // hold: one that starts and finishes under the cursor should not blink out of it.
        if holdsSteady, session.status != .idle { heldVisible.insert(id) }
        prune(now: date)
    }

    static let lifecycleKinds: Set<String> = [
        "SessionStart", "Stop", "StopFailure", "SubagentStart", "SubagentStop", "PreCompact",
        "UserPromptSubmit",
    ]

    /// The two tools whose permission prompt is really a question. Approving the *asking*
    /// of a question was never the point — the answer is.
    static let answerTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// Matched on substance rather than on the exact sentence: the wording of this
    /// notification has changed between Claude Code releases, and a card that silently
    /// stops reporting "waiting for you" is worse than one that occasionally does not.
    static func saysWaitingForInput(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("waiting for your input") || text.contains("is waiting for")
    }

    /// A fan-out `Task` says what it asked for; an Agent Team member says who it is. When
    /// the payload says neither, the count is still the useful part.
    static func subagentName(_ label: String?) -> String {
        guard let label = label?.trimmingCharacters(in: .whitespaces), !label.isEmpty else {
            return "subagent"
        }
        return condense(label, limit: 32)
    }

    /// Prompts arrive as whole messages — paragraphs, pasted logs, command output. The
    /// card has one line, so take the first meaningful one and stop.
    static func condense(_ prompt: String, limit: Int = 72) -> String {
        let firstLine =
            prompt
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? prompt

        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    public mutating func drop(id: String) {
        remove(id: id)
    }

    public mutating func prune(now: Date = .now) {
        // Zero means never. Claude Code always sends `SessionEnd`, so a user who only runs
        // it can turn ageing off entirely and never lose a long-running session.
        guard !holdsSteady, timeout > 0 else { return }
        let cutoff = now.addingTimeInterval(-timeout)
        let survivors = sessions.filter { $0.value.lastEvent > cutoff }
        // Assigning unconditionally would publish a change every time this is called, and
        // it is now called on a timer — two pointless redraws a minute, forever.
        guard survivors.count != sessions.count else { return }
        sessions = survivors
    }

    // MARK: - Holding still

    /// True while someone is looking at the panel.
    ///
    /// A list that removes a row while it is being read is worse than one that is a few
    /// seconds out of date: everything below the gap jumps up, and the card you were
    /// reading is now a different card. So while the panel is open nothing leaves the
    /// list — a session that ends keeps its row, marked as ended, until you look away.
    ///
    /// Only the roster is held. What each row *says* stays live, which is the entire
    /// reason to have the panel open.
    public private(set) var holdsSteady = false

    /// Removals that arrived while the list was held.
    private var withheld: Set<String> = []

    /// Rows that must stay on screen for as long as the list is held, because they were on
    /// it when someone started reading. A turn finishing is a removal like any other: it
    /// waits until you look away.
    private var heldVisible: Set<String> = []

    public mutating func hold() {
        holdsSteady = true
        heldVisible = Set(visible.map(\.id))
    }

    /// Lets go, and applies everything that was withheld.
    public mutating func release(now: Date = .now) {
        holdsSteady = false
        heldVisible = []
        for id in withheld { sessions.removeValue(forKey: id) }
        withheld = []
        prune(now: now)
    }

    private mutating func remove(id: String) {
        guard holdsSteady else {
            sessions.removeValue(forKey: id)
            return
        }
        withheld.insert(id)
    }

    /// Every live session, in an order that does not move.
    ///
    /// This was `lastEvent` descending — most recently active first — which sounds right
    /// and is unusable the moment more than one agent is running. Every tool call in any
    /// session promotes that card to the top and pushes the others down, so with six
    /// agents the list reshuffles several times a second: the card you are reading slides
    /// away, the one you were about to click moves out from under the cursor, and ⌃⌥P
    /// cycles in a different order on every press because the switcher indexes into this
    /// array.
    ///
    /// A session's start time never changes, so this order never changes — and it is the
    /// order they arrived in, oldest first, so a session starting *appends* rather than
    /// inserting. Newest-first was the first attempt and it moves the whole list down by a
    /// card every time you open a terminal.
    ///
    /// Which one is busy, and which one wants you, is the dot's job — it was never the
    /// row's.
    ///
    /// The id breaks ties: two sessions started in the same instant would otherwise be
    /// ordered by whatever the dictionary felt like, which is the same bug in miniature.
    public var active: [SessionSnapshot] {
        sessions.values.sorted {
            ($0.startedAt, $0.id) < ($1.startedAt, $1.id)
        }
    }

    /// What the panel shows, which is less than what is tracked.
    ///
    /// A turn that ended is not something to look at. "Done" was the honest label for it,
    /// but a row that says the work is over still takes the same space as one where it is
    /// going on, and a screen of them is a list of things you have already dealt with.
    ///
    /// Hidden rather than removed: the snapshot stays, so the next prompt brings the row
    /// back where it was, with its title and its place in the order. Dropping the session
    /// would restart it at the bottom of the list, nameless, once per turn.
    ///
    /// A failure keeps its row. So does everything blocked on a person — that is the
    /// opposite of finished.
    public var visible: [SessionSnapshot] {
        active.filter { $0.status != .idle || heldVisible.contains($0.id) }
    }

    public var workingCount: Int {
        sessions.values.filter(\.isWorking).count
    }

    /// Subagents running across every session, which is what the notch summarises.
    public var subagentCount: Int {
        sessions.values.reduce(0) { $0 + $1.subagents }
    }
}
