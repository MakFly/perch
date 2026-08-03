import Foundation
import Observation
import PerchKit

/// Live view of what Claude Code is doing, fed by the hooks.
@MainActor
@Observable
final class ActivityStore {
    /// Most recent first. Bounded — the notch shows a handful and nothing reads further
    /// back, so there is no reason to grow without limit.
    private(set) var events: [ActivityEvent] = []
    /// Drives the idle activity line: brief pulse whenever anything happens.
    private(set) var lastEventAt: Date?
    /// Distinguishes "nothing is running" from "nothing is wired up". Counts sessions ever
    /// seen, not sessions alive, because a session that ended still proves the hooks work.
    private(set) var sessionsEverSeen = 0
    let startedAt = Date.now

    private let maximumEvents = 200
    // Observed, not ignored: the session cards redraw when this changes.
    private var tracker = SessionTracker()

    /// Forgetting used to happen only as a side effect of remembering.
    ///
    /// `prune` was called from one place — the end of `record` — so the clock that forgets
    /// a silent session only ticked when *another* session spoke. Which is exactly
    /// backwards: the moment stale rows pile up is the moment everything has gone quiet,
    /// and that is precisely when nothing was left to trigger the sweep. Three sessions
    /// nobody had touched for hours sat in the strip because the machine that was supposed
    /// to remove them had stopped being asked.
    ///
    /// So it is a clock now. Half the interval is nothing next to a 30-minute timeout, and
    /// the sweep publishes nothing at all unless it actually removed something.
    @ObservationIgnored private var forgetTimer: Timer?

    init() {
        tracker.timeout = preferences.idleTimeout
        forgetTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.tracker.prune() }
        }
    }

    /// What is allowed into the panel at all.
    private(set) var admission = AdmissionPolicy.load()
    /// Blocked launcher apps and the idle timeout both live here.
    var preferences = Preferences.load() {
        didSet { tracker.timeout = preferences.idleTimeout }
    }
    /// Once a session is silenced it stays silenced: the prompt that identified it as
    /// background noise only arrives once, and every later event lacks it.
    private var silenced: Set<String> = []

    var sessions: [String: SessionSnapshot] { tracker.sessions }

    /// Re-read on demand rather than watched: it is only ever needed when the panel is
    /// empty, and a file watcher on someone's settings would be a lot of machinery for a
    /// question asked once a session.
    var health: HookHealth {
        HookWatcher.check(sessionsSeen: sessionsEverSeen, runningSince: startedAt)
    }

    /// Applies what the watcher read. Sessions that have since ended are ignored rather
    /// than resurrected — the read started while they were alive.
    func applyTurns(_ turns: [String: TranscriptTurn]) {
        for (id, turn) in turns { tracker.setTurn(turn, for: id) }
    }

    /// Sessions a hook has spoken for. See `applyCodex`.
    private var hookFed: Set<String> = []

    /// Puts the Codex sessions read off disk onto the same cards as everything else.
    ///
    /// Codex reaches the panel without hooks, because the desktop app does not run them —
    /// it shares `~/.codex` with the CLI and is an Electron application, so the rollout it
    /// writes is the only thing there is to read. `CodexSessions` turns that into the same
    /// shape a hook would have produced, and it arrives here rather than through `record`
    /// because there is no request behind it and nothing waiting on an answer.
    ///
    /// A session that has sent a hook is left alone. Both paths key on the same
    /// `session_id`, so a machine whose Codex hooks do fire would otherwise have two
    /// writers on one card — the hook, which knows the moment a tool starts, and the
    /// rollout, which knows a second later. The hook wins on the sessions it covers.
    func applyCodex(_ sessions: [CodexSessions.Live], now: Date = .now) {
        for session in sessions where !hookFed.contains(session.id) {
            guard !isSilenced(directory: session.cwd) else { continue }
            // Silence is the only end-of-turn signal a rollout has, so a session that has
            // stopped writing is one that has stopped working.
            let status: SessionStatus =
                session.isWorking(now: now, within: Self.codexWorkingWindow)
                ? (session.isRunningTool ? .runningTool : .working)
                : .idle
            tracker.observe(
                id: session.id,
                status: status,
                cwd: session.cwd,
                detail: session.detail,
                agent: .codex,
                aiTitle: session.title,
                at: session.updatedAt)
        }
    }

    /// How long after its last written line a Codex session still counts as mid-turn.
    ///
    /// A rollout has no "the turn ended" line to read, so this is the gap that stands in
    /// for one. Long enough that a single slow tool call does not read as a finished turn,
    /// short enough that a session waiting on a person stops claiming to be busy.
    private static let codexWorkingWindow: TimeInterval = 45

    /// The admission rules, asked without a hook payload to ask them about.
    private func isSilenced(directory: String?) -> Bool {
        admission.isSilenced(directory: directory, prompt: nil)
    }

    /// Which transcripts are worth re-reading right now: the live ones that have a path.
    var transcriptPaths: [String: String] {
        tracker.sessions.compactMapValues(\.transcriptPath)
    }

    func updateAdmission(_ policy: AdmissionPolicy) {
        admission = policy
        policy.save()
        // Re-evaluate what is already on screen, so turning a rule on takes effect now
        // rather than at the next session.
        for (id, session) in tracker.sessions
        where admission.isSilenced(directory: session.cwd, prompt: session.prompt) {
            silenced.insert(id)
            tracker.drop(id: id)
        }
    }

    /// Events that move session state but do not deserve a row of their own.
    private static let silentKinds: Set<String> = [
        "SessionStart", "SessionEnd", "SubagentStart", "SubagentStop", "PreCompact",
        "StopFailure",
        // `Claude is waiting for your input` is Claude Code restating what `Stop` said a
        // minute earlier. It still moves the session's state — that happens below,
        // whatever this list says — but a feed line telling you a finished turn has
        // finished is a line that pushes a real one off the bottom.
        "Notification",
    ]

    /// The request a session was blocked on has been resolved — by a click, a timeout, or
    /// Perch quitting. See `SessionTracker.answered`.
    func answered(sessionId: String) {
        tracker.answered(id: sessionId)
    }

    func record(_ request: PerchRequest) {
        let event = ActivityEvent(request: request)

        if let id = event.sessionId, isSilenced(id: id, request: request, event: event) {
            return
        }

        switch event.kind {
        case let kind where Self.silentKinds.contains(kind):
            break
        case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
            complete(event, failed: event.kind != "PostToolUse")
        default:
            append(event)
        }

        if let id = event.sessionId {
            if tracker.sessions[id] == nil { sessionsEverSeen += 1 }
            // Claimed by the hook path, so the rollout reader stays off this card.
            hookFed.insert(id)
            tracker.record(
                id: id,
                kind: event.kind,
                cwd: event.cwd,
                detail: event.detail,
                prompt: request.payload.prompt,
                client: request.client,
                agent: request.agent,
                // Read from the transcript the payload points at — Claude Code names its
                // own sessions, so there is nothing here for Perch to invent.
                aiTitle: titleIfWorthReading(for: request, kind: event.kind),
                // Recorded, not read: the reading is what `TranscriptWatcher` does, off
                // this path, because this one has a blocked CLI waiting at the end of it.
                transcriptPath: request.payload.transcriptPath,
                permissionMode: request.payload.permissionMode,
                // What is waiting, and what it is waiting for: a command wants a decision,
                // a question wants an answer, a notification may mean neither.
                tool: request.payload.toolName,
                message: request.payload.message,
                subagentLabel: request.subagentLabel,
                // Which agent the event is about — and, on a `Stop`, everything the turn
                // leaves running behind it.
                agentId: request.payload.agentId,
                backgroundTasks: request.payload.backgroundTasks,
                at: event.date)
        }
    }

    /// The events after which a session's own name can have changed.
    ///
    /// Claude Code writes the title early in a turn and refines it as the turn goes, so
    /// these three see every version of it that a card ever shows.
    private static let titleKinds: Set<String> = ["SessionStart", "UserPromptSubmit", "Stop"]

    /// The session's name, read from its transcript — but only when there is a reason to
    /// look.
    ///
    /// This sits on the hook path, which means the main actor with a CLI blocked at the end
    /// of it, and the read is not small: a 256 KB window off the end of the file, every line
    /// in it parsed as JSON, backwards, and when the window holds no title — which is the
    /// common case on a long session — every line parsed before it can say so. Measured at
    /// 3.6ms against a 5 MB transcript, and it ran on all fourteen events, which is twice
    /// per tool call.
    ///
    /// Nil keeps whatever the session already has: `SessionTracker.record` only replaces a
    /// title when it is handed a non-empty one, so saying nothing here is not the same as
    /// clearing it.
    private func titleIfWorthReading(for request: PerchRequest, kind: String) -> String? {
        guard let path = request.payload.transcriptPath, !path.isEmpty else { return nil }
        // The first sighting reads too, whatever the event: a session that was already
        // running when Perch started would otherwise sit unnamed on a card until its next
        // prompt. Gating on the title being absent instead would re-read for ever on the
        // sessions Claude Code never names, which is the same bug in the opposite corner.
        let isNewToUs = request.payload.sessionId.map { tracker.sessions[$0] == nil } ?? false
        guard isNewToUs || Self.titleKinds.contains(kind) else { return nil }
        return SessionTitle.read(transcriptPath: path)
    }

    /// A session identified as background noise is dropped whole — including anything it
    /// already put on screen before the prompt that gave it away arrived.
    private func isSilenced(id: String, request: PerchRequest, event: ActivityEvent) -> Bool {
        if silenced.contains(id) { return true }

        let prompt = request.payload.prompt ?? tracker.sessions[id]?.prompt
        let blockedLauncher = preferences.blocks(launcher: request.client?.launcher)
        guard blockedLauncher
            || admission.isSilenced(
                directory: event.cwd ?? tracker.sessions[id]?.cwd, prompt: prompt)
        else { return false }

        silenced.insert(id)
        tracker.drop(id: id)
        events.removeAll { $0.sessionId == id }
        return true
    }

    private func append(_ event: ActivityEvent) {
        events.insert(event, at: 0)
        if events.count > maximumEvents { events.removeLast(events.count - maximumEvents) }
        lastEventAt = event.date
    }

    /// Marks the matching in-flight row as finished. Falls back to appending when the
    /// `PreToolUse` hook never arrived — a tool that was auto-approved before Perch
    /// started, for instance.
    private func complete(_ event: ActivityEvent, failed: Bool) {
        guard let index = events.firstIndex(where: { $0.status == .running && $0.matches(event) })
        else {
            var standalone = event
            standalone.status = failed ? .failed : .done
            append(standalone)
            return
        }
        events[index].status = failed ? .failed : .done
        lastEventAt = event.date
    }

    var activeSessions: [SessionSnapshot] { tracker.active }

    /// What the panel draws: everything tracked, less the turns that have ended. The
    /// diagnostics keep reading `activeSessions` — a report exists to show what is there,
    /// not what is worth looking at.
    var visibleSessions: [SessionSnapshot] { tracker.visible }

    /// Holds the roster still while someone is reading it, and lets go afterwards.
    ///
    /// Called from the panel's own visibility, so "while someone is reading it" is exactly
    /// what it means: the set of cards cannot change under the cursor, and everything that
    /// wanted to leave — a session that ended, one that aged out, one a new rule silenced —
    /// leaves the moment you look away.
    func holdSteady(_ isReading: Bool) {
        if isReading {
            tracker.hold()
        } else {
            tracker.release()
        }
    }

    var workingSessionCount: Int { tracker.workingCount }

    var subagentCount: Int { tracker.subagentCount }
}
