import AppKit
import Foundation
import Observation
import PerchKit

/// Wires the hook transport to the UI.
@MainActor
@Observable
final class AppModel {
    let activity = ActivityStore()
    let tasks = TaskStore()
    let permissions = PermissionBroker()
    let usage = UsageModel()
    let notch: NotchController
    let scenes = SceneMonitor()
    let updates = UpdateChecker()
    /// Re-reads each session's last turn while the panel is open — off this actor, and off
    /// the hook path, both for the same reason: neither can afford a megabyte read.
    private let transcripts = TranscriptWatcher()
    let leaderboard = LeaderboardModel()

    /// Whether Perch is allowed to take the screen right now, and make a noise doing it.
    private(set) var quiet = QuietSettings.load()
    /// Which sound plays for which event.
    private(set) var sounds = SoundSettings.load()

    func updateSounds(_ settings: SoundSettings) {
        sounds = settings.sanitised
        sounds.save()
    }

    /// The ⌘Tab-style session switcher.
    private(set) var switcher = SessionSwitcher()

    @ObservationIgnored private var server: EventServer?
    /// Recognises the same event arriving once per hook entry that matched it.
    @ObservationIgnored private var echoes = DuplicateFilter()
    @ObservationIgnored private let hotKey = GlobalHotKey()
    @ObservationIgnored private let settingsWindow = SettingsWindowController()

    @ObservationIgnored private let onboardingWindow = OnboardingWindowController()

    @discardableResult
    func showSettings() -> Bool {
        settingsWindow.show(model: self)
    }

    func showOnboarding() {
        onboardingWindow.show(model: self)
    }

    init(notch: NotchController) {
        self.notch = notch
        // A session is drawn as blocked for as long as Perch holds its request. Every way
        // out of that queue — answered, denied, timed out, quit — has to say so, or the
        // card keeps claiming a session is waiting on you after nothing is.
        permissions.onResolved = { [weak self] pending in
            guard let self, let session = pending.sessionId else { return }
            activity.answered(sessionId: session)
        }
    }

    func updateQuiet(_ settings: QuietSettings) {
        quiet = settings
        settings.save()
    }

    var preferences: Preferences { activity.preferences }

    /// Applies everything a preferences change can touch, in one place, so no setting can
    /// be saved and then quietly not take effect until the next launch.
    func updatePreferences(_ next: Preferences) {
        let sanitised = next.sanitised
        activity.preferences = sanitised
        sanitised.save()
        usage.apply(preferences: sanitised)
        notch.applyTuning(
            width: sanitised.notchWidthAdjustment, height: sanitised.notchHeightAdjustment)
        updates.wantsBeta = sanitised.betaUpdates
        LoginItem.apply(sanitised.launchAtLogin)
        registerSwitcherShortcut()
    }

    /// Asks macOS to open Perch at login the first time this setting is ever seen, and
    /// never again.
    ///
    /// The signal is the absence of the key, not of the file: a fresh install has no
    /// preferences at all, and an install that predates this setting has a file without
    /// it. Both mean nobody has ever chosen, and both should end up starting at login —
    /// which is the whole point, since the people already running Perch are exactly the
    /// ones who want it back after a reboot.
    ///
    /// Once the key is on disk the system is left alone. Someone who turns Perch off in
    /// System Settings › Login Items has said something, and an app that quietly puts
    /// itself back at the next launch is an app you have to uninstall to be rid of.
    private func seedLoginItem() {
        let file = try? Data(contentsOf: Preferences.defaultURL)
        let stored = file.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        if let object = stored as? [String: Any], object["launchAtLogin"] != nil { return }

        let preferences = activity.preferences
        LoginItem.apply(preferences.launchAtLogin)
        // Written now rather than at the next settings change, so this runs exactly once.
        preferences.save()
    }

    /// Squares the preference with what macOS actually does, once, at launch.
    ///
    /// The two can only disagree one way: someone turned Perch off — or back on — in
    /// System Settings › Login Items, where the same switch lives. macOS wins, and the
    /// preference is corrected rather than enforced, so the settings toggle tells the
    /// truth without Perch ever overruling a choice made outside it.
    private func reconcileLoginItem() {
        guard LoginItem.isAvailable else { return }
        let registered = LoginItem.isRegistered
        guard activity.preferences.launchAtLogin != registered else { return }
        var next = activity.preferences
        next.launchAtLogin = registered
        activity.preferences = next
        next.save()
    }

    private func registerSwitcherShortcut() {
        let preferences = activity.preferences
        guard preferences.switcherEnabled else {
            hotKey.unregister()
            return
        }
        hotKey.register(
            keyCode: preferences.switcherKeyCode,
            modifiers: preferences.switcherModifiers,
            onPress: { [weak self] reverse in
                self?.switcherEvent(.shortcutPressed(reverse: reverse))
            },
            onRelease: { [weak self] in
                self?.switcherEvent(.modifierReleased)
            })
    }

    /// Keys that only mean something while the switcher is open, watched only then.
    ///
    /// The tap half of the switcher — press once, pick with ↑↓, Enter — was implemented in
    /// `SessionSwitcher` and unit-tested, and nothing ever sent it an `.arrow`: the Carbon
    /// hot key only reports press and release. So the mode the settings pane advertises
    /// did not exist at runtime, which is worse than not having it.
    ///
    /// A *local* monitor, not a global one: it only sees keys while Perch itself is key,
    /// which is exactly while the panel is up, and it needs no Accessibility permission —
    /// the one thing this app never asks for.
    @ObservationIgnored private var switcherKeys: Any?

    private func watchSwitcherKeys() {
        guard switcherKeys == nil else { return }
        switcherKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, switcher.isOpen else { return event }
            switch Int(event.keyCode) {
            case 126: switcherEvent(.arrow(down: false))  // ↑
            case 125: switcherEvent(.arrow(down: true))  // ↓
            case 36, 76: switcherEvent(.confirmed)  // Return, Enter
            case 53: switcherEvent(.cancelled)  // Escape
            default: return event
            }
            // Swallowed: an arrow that also scrolls the panel underneath would move the
            // selection twice.
            return nil
        }
    }

    private func stopWatchingSwitcherKeys() {
        if let switcherKeys { NSEvent.removeMonitor(switcherKeys) }
        switcherKeys = nil
    }

    /// Answers the switcher's events. Kept here rather than in the view so the shortcut
    /// works whether or not the panel happens to be on screen.
    private func switcherEvent(_ event: SessionSwitcher.Event) {
        // The list the panel draws, because the switcher indexes into it: cycling through a
        // longer list than the one on screen selects a card nobody can see.
        switcher.count = activity.visibleSessions.count
        let outcome = switcher.handle(event)
        // Watch keys exactly while there is something to steer, and stop the moment there
        // is not — a monitor left installed swallows Escape for the whole app.
        if switcher.isOpen { watchSwitcherKeys() } else { stopWatchingSwitcherKeys() }
        switch outcome {
        case .open, .moved:
            notch.expand()
        case .jump(let index):
            let sessions = activity.visibleSessions
            if sessions.indices.contains(index) {
                TerminalJumper.jump(to: sessions[index].client)
            }
            notch.dismiss()
        case .close:
            notch.dismiss()
        case .nothing:
            break
        }
    }

    /// Reads a session's last turn for `--status`, synchronously — this is a one-shot CLI
    /// answer, not the panel's polling path.
    private func readTurn(for session: SessionSnapshot) -> TranscriptTurn? {
        session.turn ?? session.transcriptPath.flatMap { Transcript.lastTurn(path: $0) }
    }

    /// One line, however many the original had.
    private func one(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        return flat.count > 96 ? String(flat.prefix(96)) + "…" : flat
    }

    /// One pass: read every live session's transcript off the main actor, then publish.
    ///
    /// Codex rides along here rather than on a watcher of its own. It is the same question
    /// asked on the same tick — what is happening right now — and the same answer: a
    /// directory listing and a bounded read, off the main actor, only while the panel is
    /// open. A second timer would be a second thing to stop when it closes.
    private func refreshTranscripts() async {
        await refreshCodexSessions()

        let paths = activity.transcriptPaths
        guard !paths.isEmpty else { return }
        let turns = await transcripts.read(paths: paths)
        guard !turns.isEmpty else { return }
        activity.applyTurns(turns)
    }

    /// The Codex sessions that are writing right now, read off disk because no hook will
    /// tell us about them — the desktop app shares `~/.codex` and does not run them.
    private func refreshCodexSessions() async {
        let timeout = activity.preferences.idleTimeout
        let sessions = await Task.detached(priority: .userInitiated) {
            CodexSessions.live(activeWithin: timeout)
        }.value
        guard !sessions.isEmpty else { return }
        activity.applyCodex(sessions)
    }

    func start() {
        usage.apply(preferences: activity.preferences)
        // A quota crossing is worth a glance, never an interruption: it goes through the
        // same policy as everything else, so it stays silent during a screen share and
        // never takes a panel someone is already using.
        usage.onQuotaEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .crossed(let window):
                // The number, not a warning: "5h 92%" is the whole message, and a peek
                // that has to be read past to find it is a peek that gets dismissed.
                if announce(.usageWarning) == .full {
                    notch.flash(
                        .quota(
                            window: UsageLimitsStrip.short(window.id) + " "
                                + UsageLimitsStrip.percentage(window.window, showsRemaining: false),
                            resets: window.window.timeLeft()))
                }
            // Coming back under the line is good news, and good news does not get to take
            // the screen. A sound if you asked for one, and the number speaks for itself.
            case .reset:
                _ = announce(.usageReset)
            }
        }
        usage.start()
        scenes.start()
        // Put the uninstaller somewhere the Trash cannot reach. Nobody thinks about this
        // until the moment the app is already gone, which is the moment it is too late.
        RepoScripts.stashUninstaller()

        // The conversation on the cards is only worth keeping current while someone can
        // see it. Closed, this costs nothing at all.
        notch.onPanelVisibilityChanged = { [weak self] isVisible in
            guard let self else { return }
            activity.holdSteady(isVisible)
            if isVisible {
                transcripts.start { [weak self] in await self?.refreshTranscripts() }
                // The quota was only ever re-read when a hook fired, so a panel opened on a
                // quiet machine showed whatever the last tool call left behind — minutes
                // old, and looking live. It moves while nothing here is running, so it is
                // watched all the time — quickly while it is being read, and back to a
                // slow tick for the resting bar when the panel closes.
                usage.startWatchingLimits(every: UsageModel.watchedInterval)
            } else {
                transcripts.stop()
                usage.startWatchingLimits(every: UsageModel.restingInterval)
            }
        }

        // An agent is installed and nothing is wired up: this is a first run, and the
        // notch would otherwise sit empty with no explanation.
        if EnvironmentScan.needsOnboarding() { showOnboarding() }

        seedLoginItem()
        reconcileLoginItem()

        // Re-checked at launch, without blocking it.
        updates.wantsBeta = activity.preferences.betaUpdates
        Task { await updates.check() }

        registerSwitcherShortcut()
        let preferences = activity.preferences
        notch.applyTuning(
            width: preferences.notchWidthAdjustment,
            height: preferences.notchHeightAdjustment)

        let server = EventServer { [weak self] request in
            await self?.handle(request) ?? PerchResponse()
        }
        do {
            try server.start()
            self.server = server
        } catch {
            PerchLog.error("could not start event server: \(error)")
        }
    }

    func stop() {
        // Unblock any session still waiting before the socket goes away.
        permissions.resolveAllPending()
        hotKey.unregister()
        stopWatchingSwitcherKeys()
        scenes.stop()
        server?.stop()
        server = nil
    }

    /// The one place that decides whether something takes the screen.
    ///
    /// Quiet is not "drop it": the request still queues, the session is still held, and
    /// the notch still shows a dot. It just does not open itself while you are presenting.
    private func announce(_ kind: InterruptionKind, client: ClientInfo? = nil) -> Interruption {
        // Screen capture, Focus and the frontmost app have no notification, so they are
        // read at the moment it matters rather than cached.
        scenes.refresh()
        let host = TerminalJump.bundleId(for: client)
        let decision = InterruptionPolicy.decide(
            kind, scene: scenes.scene, settings: quiet, host: host)
        if decision == .full,
            InterruptionPolicy.playsSound(kind, scene: scenes.scene, settings: quiet, host: host)
        {
            SoundPlayer.play(kind, settings: sounds)
        }
        return decision
    }

    /// The signal for when the notch cannot be one. Deliberately not gated on the same
    /// decision as the panel: `announce` answers "should this take the screen", and the
    /// answer is usually no for a completion — while "tell me it finished, I am in another
    /// app" is exactly what people ask this app for.
    private func notify(_ kind: SessionNotifier.Kind, for request: PerchRequest) {
        let host = TerminalJump.bundleId(for: request.client)
        guard
            InterruptionPolicy.notifies(
                kind == .failed ? .taskError : .taskComplete,
                scene: scenes.scene, settings: quiet, host: host)
        else { return }

        // The session's own name, so a notification says which of six agents finished.
        let session = request.payload.sessionId.flatMap { activity.sessions[$0] }
        let title = session?.title ?? session?.projectName ?? t("Claude Code")
        SessionNotifier.post(kind, title: title, client: request.client)
    }

    private func handle(_ request: PerchRequest) async -> PerchResponse {
        guard request.event != Wire.statusEvent else {
            return PerchResponse(status: statusReport())
        }

        if request.event == Wire.decideEvent {
            return await decideFromCommandLine(request)
        }

        if request.event == Wire.usageEvent {
            return recordRemoteUsage(request)
        }

        // One Claude Code event reaches Perch once per hook entry that matched it, so a
        // machine with hooks in two scopes — a project install on top of a global one —
        // would put every tool call on screen twice. The copy is still a blocked hook and
        // still gets an answer; it just does not repeat what its twin already did.
        let isEcho = request.duplicateKey.map { !echoes.admit($0) } ?? false

        if !isEcho {
            activity.record(request)
            // The plan can only have moved during a turn, and a turn is bracketed by the
            // hooks that just fired — so this is the whole refresh policy.
            tasks.refresh(request.payload.sessionId)
            tasks.forget(keeping: Set(activity.sessions.keys))
            notch.flashActivity()

            // A turn ending is the other thing worth a sound — and the one people most
            // often want silent, which is why it is off by default.
            //
            // The decision was computed and thrown away here for months: `announce`
            // returns `.full` exactly when "open the panel when a task finishes" is on,
            // and nobody read it, so that setting only ever changed whether a sound
            // played. Reading it is the whole feature.
            switch request.event {
            // A `Stop` that leaves an agent running is not a finish. It fires the moment
            // work is handed to the background, so announcing it there played the
            // completion sound, flashed "finished" and posted a notification while the
            // thing being announced had not started coming back yet — and did it again
            // for real, twenty minutes later, when it had. The turn that carries an empty
            // list is the one worth a sound.
            case "Stop" where request.payload.backgroundTasks?.contains(where: \.isRunning) == true:
                break
            case "Stop":
                // A flash rather than a peek: which session finished is one line, and it
                // is gone in two seconds whether or not anyone looked up.
                if announce(.taskComplete, client: request.client) == .full {
                    notch.flash(
                        .finished(project: projectName(of: request), detail: title(of: request)))
                }
                notify(.finished, for: request)
            case "StopFailure":
                if announce(.taskError, client: request.client) == .full {
                    notch.flash(.failed(project: projectName(of: request), detail: ""))
                }
                notify(.failed, for: request)
            default: break
            }
            // Claude Code has just written to a transcript, so this is exactly when there
            // is new usage to index — no polling needed.
            usage.scheduleRefresh()
        }

        guard request.wantsDecision else { return PerchResponse() }

        // For a decision, "already seen" is asked of the queue rather than of the clock:
        // the card this copy will join is either still waiting or it is not, and a request
        // that opens no card while its session stays blocked is the one failure here that
        // would be invisible. Nothing suspends between this and the call below, so the
        // answer cannot go stale.
        if !permissions.hasPending(matching: request) {
            // Sized from the incoming request: it is not queued yet, so
            // `permissions.current` is still the previous one.
            let requestKind = RequestKind.of(request)
            let kind: InterruptionKind =
                requestKind == .permission ? .approvalNeeded : .questionAsked
            // Queue it either way — the session is blocked and the answer is still needed.
            // Quiet only decides whether the panel opens by itself.
            if announce(kind, client: request.client) == .full {
                notch.showAlert(
                    true, extraHeight: extraHeight(for: requestKind),
                    extraWidth: extraWidth(for: requestKind))
            } else {
                notch.flashActivity()
            }
        }
        var response = await permissions.request(request)
        notch.showAlert(
            permissions.current != nil, extraHeight: alertExtraHeight,
            extraWidth: alertExtraWidth)

        // Clients that cannot parse JSON get the finished stdout instead of the fields to
        // assemble it. The remote hook is a shell script; this is what lets it stay one.
        if request.rawOutput == true {
            response.outputB64 = response.renderedOutputBase64(event: request.event)
        }
        return response
    }

    /// Which project a hook came from, as the flash names it.
    private func projectName(of request: PerchRequest) -> String? {
        request.payload.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// What that session was doing, so a finished turn says which one rather than that
    /// one finished.
    private func title(of request: PerchRequest) -> String {
        request.payload.sessionId.flatMap { activity.sessions[$0]?.title } ?? ""
    }

    /// How much taller than a plain permission the current card needs to be.
    private var alertExtraHeight: CGFloat {
        permissions.current.map { extraHeight(for: $0.kind) } ?? 0
    }

    /// How much wider. A permission is one command and stays at the panel's own width;
    /// a plan and a question are both prose, and at 520pt every option description wrapped
    /// three times — which is how four options become four paragraphs and nobody reads the
    /// one they are picking.
    private func extraWidth(for kind: RequestKind) -> CGFloat {
        if case .permission = kind { return 0 }
        return 140
    }

    private var alertExtraWidth: CGFloat {
        permissions.current.map { extraWidth(for: $0.kind) } ?? 0
    }

    private func extraHeight(for kind: RequestKind) -> CGFloat {
        switch kind {
        case .question(let request):
            // Measured from the text rather than counted in options — see `QuestionCard`.
            // A flat height per option was only ever true because the card clipped every
            // description to two lines, which meant the question you were answering was
            // the one thing the card would not show you.
            return QuestionCard.extraHeight(
                for: request, width: NotchState.alertWidth + extraWidth(for: kind))
        case .plan(let request):
            // A plan gets the screen. It is the longest thing Perch shows, the one with
            // the most consequence behind the button, and it was being read through a
            // 150pt slot — which is how a plan gets approved unread.
            //
            // Measured rather than flat, for the same reason a question is: 430 was the
            // right number for a long plan and half a screen of black under a five-line
            // one.
            return PlanCard.extraHeight(
                for: request, width: NotchState.alertWidth + extraWidth(for: kind))
        case .permission:
            return 0
        }
    }

    /// Approves the current request and, when asked, remembers the rule for this project.
    func decide(_ decision: PermissionDecision, remember: Bool = false) {
        guard let pending = permissions.current else { return }

        // A plan cannot be allowed the plain way — see `approvePlan`. `Perch --decide
        // allow` lands here too, and it approving into a still-blocked session is the
        // exact bug this routing exists to prevent.
        if case .plan = pending.kind, decision == .allow {
            approvePlan(.default)
            return
        }

        // Claude Code persists the rule itself, through the decision it is already waiting
        // on. Perch writing `settings.local.json` in parallel would race the very process
        // about to rewrite it.
        let rule = remember && decision == .allow
            ? PermissionRule.remembered(for: pending.request)
            : nil

        permissions.resolve(pending, with: decision, rule: rule)
        notch.showAlert(
            permissions.current != nil, extraHeight: alertExtraHeight,
            extraWidth: alertExtraWidth)
    }

    /// Answers the whole queue at once. Only worth offering when it is more than one.
    func decideAll(_ decision: PermissionDecision) {
        permissions.resolveAll(with: decision)
        notch.showAlert(false)
    }

    /// Answers an `AskUserQuestion`: the answers ride back inside the tool's own input.
    func answer(_ answers: [String: [String]]) {
        guard let pending = permissions.current,
            case .question(let request) = pending.kind
        else { return }

        let updated = request.updatedInput(
            original: pending.request.payload.toolInput, answers: answers)
        permissions.resolve(pending, with: .allow, updatedInput: updated)
        notch.showAlert(
            permissions.current != nil, extraHeight: alertExtraHeight,
            extraWidth: alertExtraWidth)
    }

    /// Approves a plan, and says which mode the session carries on in.
    ///
    /// Two things a plain `allow` was missing, both silent. `ExitPlanMode` requires user
    /// interaction, so an allow with no `updatedInput` is dropped and Claude Code prompts
    /// in the terminal instead — the button did nothing. And an approval that names no
    /// mode leaves the session in `plan`, where the first edit is refused.
    func approvePlan(_ mode: PlanMode) {
        guard let pending = permissions.current,
            case .plan(let request) = pending.kind
        else { return }

        permissions.resolve(
            pending, with: .allow,
            updatedInput: request.updatedInput(original: pending.request.payload.toolInput),
            planMode: mode)
        notch.showAlert(
            permissions.current != nil, extraHeight: alertExtraHeight,
            extraWidth: alertExtraWidth)
    }

    /// Rejects a plan with what to change. Denying with a message is how feedback reaches
    /// Claude Code — it reads the message and keeps going rather than stopping.
    func rejectPlan(feedback: String) {
        guard let pending = permissions.current else { return }
        permissions.resolve(
            pending, with: .deny,
            reason: feedback.isEmpty ? "The plan was rejected in Perch." : feedback)
        notch.showAlert(
            permissions.current != nil, extraHeight: alertExtraHeight,
            extraWidth: alertExtraWidth)
    }

    /// Backs `Perch --decide <allow|deny|ask> [--remember]`, which answers the oldest
    /// pending request without touching the UI.
    private func decideFromCommandLine(_ request: PerchRequest) async -> PerchResponse {
        guard let raw = request.payload.message else {
            return PerchResponse(status: "unknown decision")
        }

        if raw == "answer" {
            return answerFromCommandLine(labels: request.payload.prompt ?? "")
        }

        // `Perch --settings` reaches the running instance rather than launching a second
        // one, which would fight over the port and the notch.
        // `Perch --update` — also how the update path gets exercised without clicking.
        if raw == "update" {
            guard updates.isConfigured else {
                return PerchResponse(status: "no update feed configured")
            }
            let install = request.payload.prompt == "install"
            Task {
                await updates.check()
                if install, let item = updates.available { await updates.install(item) }
            }
            return PerchResponse(
                status: install ? "checking, then installing if newer" : "checking")
        }

        if raw == "diagnose" {
            return PerchResponse(status: diagnosticReport())
        }

        // Opening the panel is otherwise a hover, which needs a synthetic mouse and so
        // Accessibility. This is the only way to exercise what the panel starts when it
        // appears — the transcript polling — from a terminal.
        if raw == "reveal" {
            notch.reveal()
            return PerchResponse(status: "panel revealed")
        }

        if raw == "settings" {
            let visible = showSettings()
            return PerchResponse(
                status: visible ? "settings window is on screen" : "settings window did not open")
        }

        guard let decision = PermissionDecision(rawValue: raw) else {
            return PerchResponse(status: "unknown decision")
        }
        guard let pending = permissions.current else {
            return PerchResponse(status: "nothing pending")
        }

        let remember = request.payload.prompt == "remember"
        let summary = "\(pending.tool): \(pending.detail)"
        decide(decision, remember: remember)
        return PerchResponse(status: "\(decision.rawValue) → \(summary)")
    }

    /// `Perch --answer "Postgres"` — or `"Postgres | Auth, Billing"` for several
    /// questions, in the order they were asked.
    private func answerFromCommandLine(labels: String) -> PerchResponse {
        guard let pending = permissions.current,
            case .question(let request) = pending.kind
        else {
            return PerchResponse(status: "no question pending")
        }

        let perQuestion = labels.components(separatedBy: "|")
        var answers: [String: [String]] = [:]
        for (index, question) in request.questions.enumerated() {
            let raw = index < perQuestion.count ? perQuestion[index] : ""
            let chosen =
                raw
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { label in question.options.contains { $0.label == label } }
            if !chosen.isEmpty { answers[question.question] = chosen }
        }

        guard request.isComplete(answers) else {
            return PerchResponse(status: "every question needs an answer that matches an option")
        }

        answer(answers)
        return PerchResponse(status: "answered \(answers.count) question(s)")
    }

    /// A remote host reporting its own plan quota, relayed by its statusline bridge
    /// through the tunnel the hooks already use.
    private func recordRemoteUsage(_ request: PerchRequest) -> PerchResponse {
        // The host names itself: only it knows which alias you gave it, and the socket
        // cannot tell one tunnel from another.
        let host = request.payload.cwd ?? "remote"
        guard let raw = request.payload.message?.data(using: .utf8),
            let limits = RateLimits.parse(raw)
        else {
            return PerchResponse(status: "could not read the quota payload")
        }

        usage.recordRemoteLimits(host: host, limits: limits)
        return PerchResponse(status: "recorded quota for \(host)")
    }

    /// Everything a bug report needs and nothing it does not.
    ///
    /// Assembled from scrubbed facts rather than scrubbed afterwards: no command, no
    /// prompt and no real project name ever enters it, so there is nothing to redact by
    /// hand before pasting it somewhere public.
    func diagnosticReport() -> String {
        var report = DiagnosticReport()
        let bundle = Bundle.main

        report.lines.append("# Perch diagnostic report")
        report.section("Perch")
        report.field(
            "version",
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
        report.field("running since", activity.startedAt.formatted(.iso8601))

        report.section("System")
        report.field("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
        report.field(
            "memory", "\(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB")
        report.field("displays", "\(NSScreen.screens.count)")
        report.field("notch", notch.geometry.hasNotch ? "yes" : "no (floating panel)")
        report.field(
            "size", "\(Int(notch.geometry.size.width))×\(Int(notch.geometry.size.height))")

        report.section("Hooks")
        let health = activity.health
        report.field("sites checked", "\(health.sitesChecked)")
        report.field("sites with hooks", "\(health.sitesWithHooks)")
        // A project install layered on the global one: every event arrives twice, and the
        // copies are dropped rather than shown. Worth stating in a bug report, because it
        // explains a hook count that does not match what the panel displays.
        report.field("sites installed twice", "\(health.duplicatedSites)")
        report.field("sessions seen", "\(health.sessionsSeen)")
        report.field("advice", "\(health.advice())")
        for site in HookWatcher.sites() {
            report.lines.append("  \(DiagnosticReport.scrub(site))")
        }

        report.section("Quota")
        report.field("bridge", usage.bridgeLimits == nil ? "not connected" : "connected")
        // Both agents, whichever tab happens to be selected: a report is about the machine,
        // not about what is on screen.
        report.field("codex", usage.codexLimits == nil ? "no rollout" : "read")
        // Stated rather than left out: "opencode is missing from the quota section" is a bug
        // report someone would file, and the answer is that there is nothing to read.
        report.field("opencode", "no plan window published locally")
        for window in usage.codexLimits?.limits.windows ?? [] {
            let used = String(format: "%.0f%% used", window.window.utilization ?? 0)
            report.field(
                "codex \(window.title)", window.window.isStale() ? used + " (stale)" : used)
        }
        report.field(
            "prices",
            Pricing.refreshedAt.map { "refreshed \($0.formatted(.iso8601))" } ?? "as shipped")
        for window in usage.limits?.limits.windows ?? [] {
            // The stale number is kept here rather than hidden: a report exists to say what
            // the cache actually holds, and "95% used, but that window reset" is the shape
            // of the bug someone would be filing.
            let used = String(format: "%.0f%% used", window.window.utilization ?? 0)
            report.field(window.title, window.window.isStale() ? used + " (stale)" : used)
        }
        report.field("remote hosts", "\(usage.remoteLimits.count)")

        report.section("Sessions")
        report.field("live", "\(activity.sessions.count)")
        for session in activity.activeSessions {
            // The project is hashed and the prompt is absent: a session line says what
            // shape the problem is, not what you were working on.
            let project = session.projectName.map(DiagnosticReport.anonymise) ?? "unknown"
            report.lines.append(
                "  \(project)  \(session.agent.displayName)  \(session.status.rawValue)"
                    + "  \(session.client?.displayName ?? "?")"
                    + "  subagents=\(session.subagents)")
        }

        report.section("Settings")
        report.field("quiet scenes", "\(quiet)")
        report.field("admission rules", "\(activity.admission.rules.filter(\.enabled).count) on")
        report.field("sound", sounds.enabled ? "on" : "off")
        report.field("switcher", preferences.switcherEnabled ? "on" : "off")

        if let error = usage.indexError {
            report.section("Errors")
            report.lines.append(DiagnosticReport.scrub(error))
        }

        return report.text
    }

    /// Human-readable dump for `Perch --status`.
    private func statusReport() -> String {
        var lines: [String] = []
        // The card's own size, not the state's: a plan is 430pt taller and 140pt wider
        // than a permission, and `--diagnose` prints only the base sizes.
        let grown =
            notch.alertExtraHeight > 0 || notch.alertExtraWidth > 0
            ? "  (+\(Int(notch.alertExtraWidth))w +\(Int(notch.alertExtraHeight))h)" : ""
        lines.append("state          \(notch.state)\(grown)")
        lines.append("pending        \(permissions.waitingCount)")
        for pending in permissions.queue {
            let rule = PermissionRule.rule(for: pending.request) ?? "-"
            lines.append("  \(pending.tool)  \(pending.detail.prefix(50))  [rule: \(rule)]")
        }
        lines.append("sessions       \(activity.sessions.count) (\(activity.workingSessionCount) working)")
        for session in activity.activeSessions {
            let project = session.projectName ?? "?"
            // Named rather than counted: "+2 subagents" and "+2 (code-reviewer, explorer)"
            // answer different questions, and only one of them is worth printing.
            let subagents =
                session.children.isEmpty
                ? ""
                : "  +\(session.children.count) ("
                    + session.children.map(\.label).joined(separator: ", ") + ")"
            let jump = TerminalJump.plan(for: session.client).summary
            let mode = session.permissionMode.map { " {\($0)}" } ?? " {no permission_mode}"
            let board = tasks.board(for: session.id)
            let plan =
                board.isEmpty
                ? ""
                : "  · tasks \(board.completed)/\(board.tasks.count) done, \(board.inProgress) running"
            lines.append(
                "  \(session.id.prefix(8))  \(session.agent.displayName)\(mode)  \(project)  [\(session.status.rawValue)]  “\(session.title)”  \(session.lastDetail)\(subagents)\(plan)  · \(jump)"
            )
            // The exchange the card draws, from the transcript on disk. The panel cannot be
            // photographed from a terminal, so this is where "the reader works on real
            // data" is checked — the rendered image only ever proves the layout.
            if let turn = readTurn(for: session) {
                // Which of the two paths produced it: `live` means the watcher published it
                // while the panel was open, `read` means this command went to the file.
                let source = session.turn == nil ? "read" : "live"
                if let prompt = turn.prompt {
                    lines.append("      you   [\(source)] \(one(prompt))")
                }
                if !turn.reply.isEmpty {
                    lines.append("      says  \(one(turn.reply))")
                }
            }
        }
        usage.reloadLimits()
        if let codex = usage.codexLimits, !codex.limits.isEmpty {
            lines.append("quota codex")
            for window in codex.limits.windows {
                let used = window.window.utilization.map { String(format: "%.0f%%", $0) } ?? "?"
                let left = window.window.timeLeft().map { " · resets in \($0)" } ?? ""
                let state = window.window.isStale() ? "stale" : "\(used) used\(left)"
                lines.append(
                    "  \(window.title.padding(toLength: 16, withPad: " ", startingAt: 0)) \(state)")
            }
        }
        if let reading = usage.bridgeLimits, !reading.limits.isEmpty {
            lines.append("quota")
            for window in reading.limits.windows {
                let used = window.window.utilization.map { String(format: "%.0f%%", $0) } ?? "?"
                let resets = window.window.resetsAt.map {
                    " · resets \($0.formatted(.relative(presentation: .named)))"
                } ?? ""
                let state =
                    window.window.isStale()
                    ? "stale — waiting for a fresh render" : "\(used) used\(resets)"
                lines.append("  \(window.title.padding(toLength: 16, withPad: " ", startingAt: 0)) \(state)")
            }
        } else if usage.bridgeLimits?.limits.available == false {
            lines.append("quota          not applicable on this account")
        } else {
            lines.append("quota          no data — run ./scripts/usage-bridge.sh")
        }
        for (host, reading) in usage.remoteLimits.sorted(by: { $0.key < $1.key }) {
            lines.append("quota @\(host)")
            for window in reading.limits.windows {
                let used = window.window.utilization.map { String(format: "%.0f%%", $0) } ?? "?"
                let state = window.window.isStale() ? "stale" : "\(used) used"
                lines.append(
                    "  \(window.title.padding(toLength: 16, withPad: " ", startingAt: 0)) \(state)"
                )
            }
        }
        lines.append(
            "tokens today   \(usage.today.totalTokens.compactTokens) (\(usage.today.cost.compactCost))"
        )
        lines.append(
            "tokens total   \(usage.allTime.totalTokens.compactTokens) (\(usage.allTime.cost.compactCost)), \(usage.allTime.events) responses"
        )
        if let error = usage.indexError { lines.append("index error    \(error)") }
        lines.append("events         \(activity.events.count)")
        let formatter = Date.FormatStyle(date: .omitted, time: .standard)
        for event in activity.events.prefix(15) {
            let time = event.date.formatted(formatter)
            let tool = (event.tool ?? event.kind).padding(toLength: 16, withPad: " ", startingAt: 0)
            let mark =
                switch event.status {
                case .running: "…"
                case .done: "✓"
                case .failed: "✗"
                }
            lines.append("  \(time)  \(mark) \(tool)  \(event.detail.prefix(60))")
        }
        return lines.joined(separator: "\n")
    }
}
