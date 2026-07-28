import PerchKit
import SwiftUI

struct NotchRootView: View {
    @Bindable var controller: NotchController
    let model: AppModel

    var body: some View {
        // The window is a fixed canvas; the panel is the only thing in it that moves, and
        // it moves on one spring. Everything below this line animates because `panelSize`
        // changed — not because anyone told a window to resize.
        VStack(spacing: 0) {
            // Hover is not read here: the controller watches the cursor against this same
            // rect, because a canvas that ignores the mouse while idle never delivers the
            // `mouseEntered` that `onHover` needs to work at all.
            panel
                .frame(width: controller.panelSize.width, height: controller.panelSize.height)

            // Deliberately empty: the room the panel grows into. Spacer takes no hits, so
            // the canvas stays as transparent to the mouse as it looks.
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.morph, value: controller.panelSize)
        .animation(Motion.morph, value: controller.state)
        .onChange(of: idleFlank, initial: true) { controller.setIdleFlank(idleFlank) }
        .background {
            Button("") { controller.dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
        }
        // The only way out of the app.
        //
        // Perch has no Dock icon and no menu bar item, so until this existed the gear
        // inside the expanded panel was the single entry point to anything — and there was
        // no exit at all: quitting meant Activity Monitor. An app that cannot be quit by
        // the person running it is not a preference, it is a defect.
        .contextMenu {
            Button(t("Settings…")) { model.showSettings() }
            Button(t("Check for Updates…")) { Task { await model.updates.check() } }
            Button(model.sounds.enabled ? t("Mute sounds") : t("Unmute sounds")) {
                model.updateSounds(model.sounds.toggledEnabled)
            }
            Divider()
            Button(t("Quit Perch")) { NSApplication.shared.terminate(nil) }
        }
    }

    private var panel: some View {
        ZStack(alignment: .top) {
            // One shape for every state, faded rather than swapped.
            //
            // This used to be an `if drawsPanel { … } else if idleFlank > 0 { … }`, which
            // reads fine and animates badly: the two branches are different views, and
            // SwiftUI cannot morph one view into another — it removes one and inserts the
            // other. So the corner radii jumped from 12 to 18 in a single frame while the
            // *frame* was still springing, and the hairline border appeared and vanished
            // instantly at both ends. The panel grew smoothly and its outline popped, which
            // is the part that read as cheap.
            //
            // With one persistent shape, `animatableData` interpolates the radii on the
            // same curve as the size, and both fills are opacity — which is a thing that
            // can be animated.
            shape
                .fill(Theme.surface)
                // Nothing is painted at rest with nothing running: the cutout is already
                // black, and drawing our own black over it is what made it look wrong.
                .opacity(controller.state.drawsPanel || idleFlank > 0 ? 1 : 0)
                .overlay {
                    shape
                        .stroke(Theme.hairline, lineWidth: 1)
                        .opacity(controller.state.drawsPanel ? 1 : 0)
                }

            // The cutout strip is the only click target that opens and closes the panel.
            // It used to be the whole view, which meant clicking anywhere inside the
            // panel — including empty space between controls — collapsed it.
            Color.clear
                .frame(height: controller.geometry.size.height)
                .contentShape(Rectangle())
                .onTapGesture { controller.toggleExpanded() }

            content
                // One state's content is not a redraw of another's, so it is replaced
                // rather than diffed — and it comes in from the top edge, where the panel
                // is coming from. On its own, shorter curve: the incoming content should
                // be legible while the panel is still growing, not arrive with it.
                .id(controller.state)
                .transition(Motion.contentSwap)
                .animation(Motion.content, value: controller.state)
                // Resting content sits *level with* the cutout, either side of it;
                // everything else hangs below the bezel.
                .padding(.top, controller.state == .idle ? 0 : controller.geometry.size.height)
                .padding(.horizontal, controller.state == .idle ? 0 : 14)
                .padding(.bottom, controller.state == .idle ? 0 : 12)
                // Peek has no controls, so its whole body opens the panel. Expanded does,
                // so it gets no blanket tap — otherwise clicking near a button dismisses
                // the thing you were aiming at.
                .contentShape(Rectangle())
                .onTapGesture { controller.tapBody() }
        }
        // Clipped to the panel, so the content is *revealed* by the growing shape instead
        // of spilling past it. The content settles in 0.16s and the panel takes 0.38s, so
        // for a fifth of a second a full-width peek was drawing outside a panel that had
        // not reached that width yet — text over the wallpaper, either side of a black
        // box. That was the other half of what looked wrong.
        .clipShape(shape)
    }

    /// Recomputed from what is running, and pushed to the controller so the resting strip
    /// grows and shrinks with the content rather than reserving space for the worst case.
    /// The controller needs it too: it is what the cursor is tested against while idle.
    private var idleFlank: CGFloat {
        IdleView.flank(
            for: IdleReading(model.activity), quota: model.usage.limits,
            waiting: model.permissions.waitingCount)
    }

    private var shape: NotchShape {
        guard controller.state == .idle else {
            return NotchShape(bottomRadius: 18, shoulderRadius: 9)
        }
        // A painted resting strip carries more corner than an empty one: at 10pt of
        // overhang a 10pt radius is what makes it one shape wrapped around the cutout
        // rather than a rectangle stuck to it.
        return idleFlank > 0
            ? NotchShape(bottomRadius: 12, shoulderRadius: 8)
            : NotchShape(bottomRadius: 10, shoulderRadius: 6)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .idle:
            IdleView(
                reading: IdleReading(model.activity),
                notchWidth: controller.geometry.size.width,
                notchHeight: controller.geometry.size.height,
                quota: model.usage.limits,
                waiting: model.permissions.waitingCount,
                isMuted: !model.sounds.enabled,
                showsIcons: idleFlank > 0)
        case .peek:
            PeekView(activity: model.activity, usage: model.usage)
        case .expanded:
            ExpandedView(model: model, onClose: { controller.dismiss() })
        case .alert:
            alertContent
        }
    }

    @ViewBuilder
    private var alertContent: some View {
        if let pending = model.permissions.current {
            // A question and a plan are not permissions, and answering them with
            // Allow/Deny throws away the whole point of the tool.
            switch pending.kind {
            case .question(let request):
                QuestionCardView(
                    request: request,
                    projectName: pending.projectName,
                    submit: { model.answer($0) },
                    // Staying silent hands the question back to Claude Code's own prompt.
                    cancel: { model.decide(.ask) }
                )
                // `id` resets the card's local selection when the next request arrives.
                .id(pending.id)
            case .plan(let request):
                PlanCardView(
                    request: request,
                    projectName: pending.projectName,
                    approve: { model.approvePlan($0) },
                    reject: { model.rejectPlan(feedback: $0) }
                )
                .id(pending.id)
            case .permission:
                permissionContent(pending)
            }
        }
    }

    @ViewBuilder
    private func permissionContent(_ pending: PendingPermission) -> some View {
        PermissionAlertView(
            pending: pending,
            waitingCount: model.permissions.waitingCount,
            decide: { decision, remember in
                model.decide(decision, remember: remember)
            },
            decideAll: { model.decideAll($0) }
        )
        // Shortcuts are local to the panel, which only takes focus while an alert is
        // up — so Perch never needs Accessibility permission.
        .background {
            Group {
                Button("") { model.decide(.allow) }
                    .keyboardShortcut(.return, modifiers: .option)
                Button("") { model.decide(.deny) }
                    .keyboardShortcut(.delete, modifiers: .option)
            }
            .opacity(0)
        }
    }
}

/// The resting state: what is running, either side of the cutout.
///
/// With nothing running this draws nothing at all and the cutout looks exactly like the
/// hardware. The moment an agent is working there is something worth seeing without
/// hovering, and the menu bar beside the cutout is the only place to put it — so a glyph
/// per agent goes on the left and the count on the right, with the physical notch left
/// untouched between them.
struct IdleReading: Equatable {
    /// One entry per agent with a live session, most recent first, and whether any of that
    /// agent's sessions is actually doing something.
    var agents: [(agent: Agent, isWorking: Bool)] = []
    var count = 0
    /// Whether any of them is blocked on a person.
    var needsYou = false

    static func == (a: Self, b: Self) -> Bool {
        a.count == b.count && a.needsYou == b.needsYou
            && a.agents.map(\.agent) == b.agents.map(\.agent)
            && a.agents.map(\.isWorking) == b.agents.map(\.isWorking)
    }

    /// Live, not *working*. This counted working sessions until it was pointed out that a
    /// CLI waiting for an answer is exactly the one you want to see from across the room —
    /// and it was invisible: the moment a turn ended, or a permission card went up, the
    /// session left the strip and the count went down. "How many agents do I have running"
    /// is the question this bar exists to answer, and a session waiting on you is running.
    @MainActor
    init(_ activity: ActivityStore) {
        let sessions = activity.activeSessions
        for session in sessions where !agents.contains(where: { $0.agent == session.agent }) {
            agents.append(
                (session.agent, sessions.contains { $0.agent == session.agent && $0.isWorking }))
        }
        count = sessions.count
        needsYou = sessions.contains { $0.status.needsYou }
    }

    /// For the off-screen preview, which has no store to read.
    init(agents: [(agent: Agent, isWorking: Bool)], count: Int, needsYou: Bool) {
        self.agents = agents
        self.count = count
        self.needsYou = needsYou
    }
}

struct IdleView: View {
    let reading: IdleReading
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    /// Read at rest, not only in the panel. A quota you have to open something to see is a
    /// quota you discover when the next turn is refused — which is the moment it is too
    /// late to have known.
    var quota: UsageLimitsReader.Reading?
    /// How many requests are held. Distinct from the amber pill, which says *that* someone
    /// is waiting: this says how many, and four queued approvals is a different afternoon
    /// from one.
    var waiting: Int = 0
    /// Sounds off, so the speaker can say so rather than lying about it.
    var isMuted = false
    /// Only where there is a strip to put them on. With nothing running and no quota the
    /// strip is exactly zero wide, and two icons floating beside the cutout would undo the
    /// one property that state has.
    var showsIcons = false

    private var count: Int { reading.count }
    /// The pill changes colour rather than growing a second badge — at 32pt there is room
    /// for one signal, and "someone is waiting for you" outranks everything else.
    private var needsYou: Bool { reading.needsYou }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                UsageLimitsStrip(reading: quota)
                HStack(spacing: 3) {
                    // A glyph breathes only for an agent that is doing something: a card
                    // that has stopped should not keep pulsing from the corner of a screen.
                    ForEach(reading.agents, id: \.agent.rawValue) { entry in
                        AgentGlyph(agent: entry.agent, pixel: 2, isBreathing: entry.isWorking)
                    }
                }
            }
            .frame(
                width: IdleView.flank(for: reading, quota: quota, waiting: waiting)
                    - IdleView.inset
            )
            .padding(.trailing, IdleView.inset)

            // The cutout itself: nothing is ever drawn here.
            Color.clear.frame(width: notchWidth)

            HStack(spacing: 4) {
                // Loudest thing on the bar, and first: a held request is the only item here
                // that is costing something while it is not read.
                if waiting > 0 {
                    Text("\(waiting)")
                        .font(Theme.mono(10, .semibold))
                        .foregroundStyle(Theme.surface)
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Theme.claude))
                }
                // Anything the server adds beyond the two everyone has — a per-model
                // weekly window — goes on this side, where there is room the left has run
                // out of.
                UsageLimitsStrip(reading: quota, dropFirst: 2, maximum: 1)
                if count > 0 {
                    // A pill, not a bare digit: against the menu bar a lone numeral reads
                    // as a glitch, and the fill is what makes it look deliberate.
                    Text("\(count)")
                        .font(Theme.mono(10, .semibold))
                        .foregroundStyle(needsYou ? Theme.surface : Theme.primary)
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule()
                                .fill(needsYou ? Theme.warning : Color.white.opacity(0.16)))
                }
                Spacer(minLength: 0)

                // Mute and settings, at rest.
                //
                // Drawn, not clickable in the SwiftUI sense: the canvas ignores the mouse
                // while idle, which is what lets the menu bar underneath keep working. The
                // controller samples the click position it already has and routes it —
                // `IdleView.hotspots` is the one place the two agree on where these are.
                if showsIcons {
                    Image(systemName: isMuted ? "speaker.slash" : "speaker.wave.2")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isMuted ? Theme.warning : Theme.tertiary)
                        .frame(width: IdleView.iconSize, height: IdleView.iconSize)
                        .background(Circle().fill(Theme.hairline))
                    Image(systemName: "gearshape")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                        .frame(width: IdleView.iconSize, height: IdleView.iconSize)
                        .background(Circle().fill(Theme.hairline))
                }
            }
            .frame(
                width: IdleView.flank(for: reading, quota: quota, waiting: waiting)
                    - IdleView.inset
            )
            .padding(.leading, IdleView.inset)
        }
        // The content stays level with the cutout; only the painted shape reaches below it.
        .frame(height: notchHeight, alignment: .center)
    }

    /// Gap between the content and the cutout, on each side. The icon geometry lives in
    /// `IdleStrip`, where the controller reads the same numbers to route a click.
    static let inset = IdleStrip.inset
    static let iconSize = IdleStrip.iconSize
    static let iconSpacing = IdleStrip.iconSpacing
    static var iconsWidth: CGFloat { IdleStrip.iconsWidth }

    /// Sized to the content: one agent must not reserve room for four, and an empty strip
    /// must be exactly zero wide or it paints black shoulders beside the notch.
    ///
    /// The inset is part of this number. It was not at first, and the window came out ten
    /// points narrower than what it had to draw — so the count was clipped by the edge it
    /// was supposed to sit inside.
    static func flank(
        for reading: IdleReading, quota: UsageLimitsReader.Reading? = nil, waiting: Int = 0
    ) -> CGFloat {
        // The two windows every account has go left of the cutout; anything per-model goes
        // right of it. Each side is measured from what it actually draws.
        let leftQuota = quotaWidth(quota, dropFirst: 0, maximum: 2)
        let rightQuota = quotaWidth(quota, dropFirst: 2, maximum: 1)
        guard reading.count > 0 || leftQuota + rightQuota > 0 else { return 0 }

        // 16pt of sprite plus a 3pt gap, and a floor of 24 for the count pill — wide
        // enough for two digits, which is more concurrent sessions than anyone runs.
        let glyphs = reading.count == 0 ? 0 : max(CGFloat(reading.agents.count) * 19, 24)
        let left = leftQuota + (leftQuota > 0 && glyphs > 0 ? 6 : 0) + glyphs
        var right = rightQuota + (reading.count > 0 ? 24 : 0) + (waiting > 0 ? 26 : 0)
        // The icons are only drawn when there is a strip to draw them on, which is exactly
        // when this function returns something other than zero.
        right += iconsWidth + iconSpacing

        // Both shoulders are one number — the window is symmetric around the cutout — so
        // the wider side decides. An asymmetric window would centre the notch off the
        // hardware it is drawn around.
        return max(left, right) + inset
    }

    /// Measured rather than estimated: this sizes a window, and text that is one character
    /// wider than its window is text with a character missing.
    private static func quotaWidth(
        _ reading: UsageLimitsReader.Reading?, dropFirst: Int, maximum: Int
    ) -> CGFloat {
        guard let reading, !reading.limits.isEmpty else { return 0 }
        let windows = reading.limits.windows.dropFirst(dropFirst).prefix(maximum)
        return windows.reduce(0) { total, window in
            // The chip as it is actually spelled, not as wide as it could ever be. Sizing
            // for `100%` would reserve menu bar that says `13%`, and the strip already
            // animates between widths — a percentage moves every few minutes, not every
            // frame.
            total + Theme.monoWidth(UsageLimitsStrip.label(for: window), size: 9) + 8
        }
    }
}

private struct PulsingDot: View {
    let tint: Color
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 5, height: 5)
            .opacity(isPulsing ? 1 : 0.3)
            .animation(
                .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

/// Hover preview: what is running, and what today has cost.
private struct PeekView: View {
    let activity: ActivityStore
    let usage: UsageModel

    var body: some View {
        HStack(spacing: 10) {
            StatusBadge(count: activity.workingSessionCount)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.label(12, .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                Text(usage.today.totalTokens.compactTokens)
                    .font(Theme.mono(12, .semibold))
                    .foregroundStyle(Theme.primary)
                Text(usage.today.cost.compactCost)
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.active)
            }

            // Without this the peek reads as a dead end: nothing suggests the panel goes
            // any further.
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.tertiary)
        }
    }

    private var title: String {
        switch activity.sessions.count {
        case 0: return t("Perch")
        case 1: return activity.activeSessions.first?.projectName ?? t("1 session")
        default: return t("%lld sessions", activity.sessions.count)
        }
    }

    private var subtitle: String {
        activity.events.first?.detail ?? t("waiting for Claude Code")
    }
}

private struct StatusBadge: View {
    let count: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(count > 0 ? Theme.active.opacity(0.18) : Theme.hairline)
                .frame(width: 22, height: 22)
            if count > 0 {
                Text("\(count)")
                    .font(Theme.mono(11, .bold))
                    .foregroundStyle(Theme.active)
            } else {
                Circle()
                    .fill(Theme.tertiary)
                    .frame(width: 5, height: 5)
            }
        }
    }
}

// MARK: - Expanded

private enum Tab: String, CaseIterable {
    case activity, stats, rank
}

private struct ExpandedView: View {
    let model: AppModel
    let onClose: () -> Void
    @State private var tab: Tab = .activity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TabBar(selection: tab) { tab = $0 }
                // Quota lives in the header on every tab: it is the one number you want
                // without having to go looking for it.
                UsageLimitsStrip(
                    reading: model.usage.limits,
                    showsRemaining: model.preferences.showsRemainingQuota)

                // Muting is a thing you want *while* a machine is being noisy, which is
                // never the moment to go and find a settings window.
                Button { model.updateSounds(model.sounds.toggledEnabled) } label: {
                    Image(systemName: model.sounds.enabled ? "speaker.wave.2" : "speaker.slash")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(model.sounds.enabled ? Theme.tertiary : Theme.warning)
                        .padding(5)
                        .background(Circle().fill(Theme.hairline))
                }
                .buttonStyle(.plain)
                .help(model.sounds.enabled ? t("Mute sounds") : t("Unmute sounds"))

                // With no Dock icon and no menu bar item, this is the only way in.
                Button { model.showSettings() } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                        .padding(5)
                        .background(Circle().fill(Theme.hairline))
                }
                .buttonStyle(.plain)
                .help(t("Settings"))

                // An explicit close, so getting out never depends on finding the 32pt
                // strip or knowing about Escape.
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                        .padding(5)
                        .background(Circle().fill(Theme.hairline))
                }
                .buttonStyle(.plain)
                .help(t("Close (esc)"))
            }

            switch tab {
            case .activity: ActivityList(model: model)
            case .stats:
                StatsView(
                    usage: model.usage,
                    showsRemaining: model.preferences.showsRemainingQuota,
                    onToggleQuota: {
                        var next = model.preferences
                        next.showsRemainingQuota.toggle()
                        model.updatePreferences(next)
                    })
            case .rank: RankView(model: model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Opening the panel is the moment to catch up on plans that moved while Perch was
        // not running, or while a session sat quiet — but *after* it has finished opening.
        // Reading transcripts on the frame the morph starts is work competing with the
        // spring for the same 0.38s.
        .task {
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            model.tasks.refreshAll(model.activity.activeSessions.map(\.id))
        }
    }
}

private struct TabBar: View {
    let selection: Tab
    let onSelect: (Tab) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button { onSelect(tab) } label: {
                    Text(t(tab.rawValue))
                        .font(Theme.label(11, .medium))
                        .foregroundStyle(tab == selection ? Theme.primary : Theme.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(tab == selection ? Theme.hairlineStrong : .clear))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

/// Sessions first, then the tool feed underneath.
///
/// The feed alone answered "what just happened"; the cards answer "what are my agents
/// doing", which is the reason to open the notch at all.
private struct ActivityList: View {
    let model: AppModel

    private var activity: ActivityStore { model.activity }

    var body: some View {
        if activity.sessions.isEmpty && activity.events.isEmpty {
            // An empty panel has several causes with opposite fixes, so it says which.
            EmptyStateView(health: activity.health)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                // Cycling past the fold used to move a selection nobody could see. The
                // reader is only ever driven by the switcher — scrolling the panel while
                // someone is reading it would be the opposite of helpful.
                ScrollViewReader { scroller in
                LazyVStack(alignment: .leading, spacing: Theme.rowSpacing) {
                    ForEach(
                        Array(activity.activeSessions.enumerated()), id: \.element.id
                    ) { position, session in
                        SessionCardView(
                            session: session,
                            tasks: model.tasks.board(for: session.id),
                            layout: model.preferences.layout,
                            isSelected: model.switcher.isOpen && model.switcher.index == position,
                            onJump: { TerminalJumper.jump(to: session.client) },
                            onSilence: { rule in
                                var policy = activity.admission
                                policy.add(rule)
                                activity.updateAdmission(policy)
                            }
                        )
                    }

                    if !activity.events.isEmpty {
                        Text(t("recent"))
                            .font(Theme.mono(9, .medium))
                            .foregroundStyle(Theme.tertiary)
                            .padding(.top, 4)

                        ForEach(activity.events.prefix(20)) { event in
                            EventRow(event: event)
                        }
                    }
                }
                .onChange(of: model.switcher.index) { _, index in
                    guard model.switcher.isOpen,
                        activity.activeSessions.indices.contains(index)
                    else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        scroller.scrollTo(activity.activeSessions[index].id, anchor: .center)
                    }
                }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

/// What an empty panel means, and what to do about it.
///
/// "No activity yet" is not an answer: hooks stripped by another tool and sessions that
/// started before the hooks existed look identical from here, and the fixes are opposite.
private struct EmptyStateView: View {
    let health: HookHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.label(11))
                .foregroundStyle(tint)
            Text(detail)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var title: String {
        switch health.advice() {
        case .fine: return t("No activity yet")
        case .restartSessions: return t("Restart your sessions")
        case .reinstallHooks: return t("Hooks were removed")
        case .notInstalled: return t("Hooks are not installed")
        case .installedTwice: return t("Hooks are installed twice")
        }
    }

    private var detail: String {
        switch health.advice() {
        case .fine:
            return t("Waiting for Claude Code.")
        case .restartSessions:
            return t(
                "Hooks are installed, but a session already open ignores them — Claude Code "
                    + "reads them once, at session start.")
        case .reinstallHooks(let missing):
            return t(
                "%lld settings files no longer mention Perch. Another tool may manage them "
                    + "too. Run ./scripts/install-hooks.sh again.", missing)
        case .notInstalled:
            return t("Run ./scripts/install-hooks.sh <project>, then restart your sessions.")
        case .installedTwice(let sites):
            return t(
                "%lld projects install Perch on top of the global hooks, so every event "
                    + "fires twice. The copies are dropped, but the second hook still runs: "
                    + "./scripts/install-hooks.sh --uninstall <project>.", sites)
        }
    }

    private var tint: Color {
        switch health.advice() {
        case .fine: return Theme.secondary
        case .restartSessions: return Theme.info
        case .reinstallHooks, .notInstalled: return Theme.warning
        case .installedTwice: return Theme.info
        }
    }
}

private struct EventRow: View {
    let event: ActivityEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 4, height: 4)

            Text(event.tool ?? event.kind)
                .font(Theme.mono(10, .medium))
                .foregroundStyle(Theme.primary.opacity(0.9))
                .frame(width: 68, alignment: .leading)

            Text(event.detail)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            Text(event.date, format: .dateTime.hour().minute().second())
                .font(Theme.mono(9))
                .foregroundStyle(Theme.tertiary)
        }
    }

    private var statusColor: Color {
        switch event.status {
        case .running: return Theme.warning
        case .done: return Theme.active.opacity(0.7)
        case .failed: return Theme.danger
        }
    }
}

