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

            content
                // One state's content is not a redraw of another's, so it is replaced
                // rather than diffed — and it comes in from the top edge, where the panel
                // is coming from. On its own, shorter curve: the incoming content should
                // be legible while the panel is still growing, not arrive with it.
                .id(controller.state)
                .transition(Motion.contentSwap)
                .animation(Motion.content, value: controller.state)
                // A panel hangs below the bezel, under the collar; rest and the flash sit
                // level with the cutout.
                .padding(
                    .top,
                    controller.state.hangsBelowTheBezel
                        ? controller.geometry.size.height + NotchState.bodyInset : 0
                )
                .padding(.bottom, controller.state.hangsBelowTheBezel ? 12 : 0)
                // Peek has no controls, so its whole body opens the panel. Expanded does,
                // so it gets no blanket tap — otherwise clicking near a button dismisses
                // the thing you were aiming at.
                .contentShape(Rectangle())
                .onTapGesture { controller.tapBody() }

            // The cutout itself is the toggle: the one place a click always opens and
            // closes the panel.
            //
            // It used to be the full width of the strip, which is now where the tabs and
            // the quota live — a blanket target across them would eat the clicks they
            // exist for. Last in the stack, so it wins over the content underneath it;
            // nothing is ever drawn in this rectangle anyway, it is a hole in the screen.
            Color.clear
                .frame(
                    width: controller.geometry.size.width,
                    height: controller.geometry.size.height)
                .contentShape(Rectangle())
                .onTapGesture { controller.toggleExpanded() }
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
            for: IdleReading(model.activity), waiting: model.permissions.waitingCount,
            quota: restingQuota, showsRemaining: model.preferences.showsRemainingQuota)
    }

    /// The plan the resting bar carries, or nil when the setting says the cutout should
    /// stay bare with nothing running.
    private var restingQuota: UsageLimitsReader.Reading? {
        model.preferences.restingQuota ? model.usage.limits : nil
    }

    private var shape: NotchShape {
        guard controller.state == .idle else {
            // The shoulder is what makes the top corners meet the menu bar on a curve
            // instead of a right angle. It reaches past the panel's own edge, so the
            // canvas reserves room for it — see `NotchState.shoulder`, which is where the
            // number lives precisely because two files have to agree on it.
            //
            // The collar is what keeps the menu bar. A panel that starts full-width at the
            // top of the screen buries the menus either side of the cutout; this one is
            // the hardware's width until the bezel and flares out below it.
            return NotchShape(
                bottomRadius: 18, shoulderRadius: NotchState.shoulder,
                collarWidth: controller.geometry.size.width,
                collarHeight: controller.state.hangsBelowTheBezel
                    ? controller.geometry.size.height : 0)
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
                waiting: model.permissions.waitingCount,
                quota: restingQuota,
                showsRemaining: model.preferences.showsRemainingQuota)
        case .flash:
            if let notice = controller.notice {
                FlashView(notch: controller.geometry.size, notice: notice)
            }
        case .peek:
            PeekView(
                notch: controller.geometry.size,
                sessions: model.activity.visibleSessions,
                fallback: model.activity.events.first?.detail ?? t("waiting for Claude Code"),
                tokens: model.usage.today.totalTokens.compactTokens,
                cost: model.usage.today.cost.compactCost)
        case .expanded:
            ExpandedView(
                notch: controller.geometry.size, model: model,
                onClose: { controller.dismiss() })
        case .alert:
            alertContent
        }
    }

    /// The card, under a band that says where the request came from.
    ///
    /// Origin and queue depth are the same two facts whichever card it is, and they were
    /// repeated in each of the three headers — where they competed with the tool, the
    /// question or the plan for the one line that matters. They belong beside the cutout:
    /// the panel is 520pt wide and the hardware is 190 of it.
    @ViewBuilder
    private var alertContent: some View {
        if let pending = model.permissions.current {
            VStack(alignment: .leading, spacing: 8) {
                PanelHeader {
                    AgentGlyph(agent: pending.agent, pixel: 1.5, isBreathing: false)
                    Text(pending.projectName ?? pending.agent.displayName)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                } trailing: {
                    if model.permissions.waitingCount > 1 {
                        Chip(
                            text: t("%lld waiting", model.permissions.waitingCount - 1),
                            tint: Theme.warning)
                    }
                }

                card(for: pending)
                    .padding(.horizontal, 14)
            }
        }
    }

    @ViewBuilder
    private func card(for pending: PendingPermission) -> some View {
        // A question and a plan are not permissions, and answering them with Allow/Deny
        // throws away the whole point of the tool.
        switch pending.kind {
        case .question(let request):
            QuestionCardView(
                request: request,
                submit: { model.answer($0) },
                // Staying silent hands the question back to Claude Code's own prompt.
                cancel: { model.decide(.ask) }
            )
            // `id` resets the card's local selection when the next request arrives.
            .id(pending.id)
        case .plan(let request):
            PlanCardView(
                request: request,
                approve: { model.approvePlan($0) },
                reject: { model.rejectPlan(feedback: $0) }
            )
            .id(pending.id)
        case .permission:
            permissionContent(pending)
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

// MARK: - The first row of a panel

/// What a state is, and what it offers — on one row, under the collar.
///
/// This lived in the band beside the cutout for a while, which used the 32pt of black the
/// panel was reserving anyway and looked right in isolation. It was not: that band is the
/// menu bar, and a 680pt panel drawn across it buries every menu either side of the
/// hardware. The panel hangs below the bezel now, so its header is a header again — the
/// difference is that the band above it is no longer part of the panel at all.
struct PanelHeader<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            leading
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        // Tall enough that the tabs and the round buttons sit in a band rather than on a
        // line: a header the exact height of its own text is one the eye reads as the
        // first row of the list under it.
        .frame(height: 26)
    }
}

/// A control small enough to sit in a shoulder.
struct ShoulderButton: View {
    let symbol: String
    var tint: Color = Theme.tertiary
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.hairline))
        }
        .buttonStyle(.plain)
        .help(help)
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
    /// and it was invisible: the moment a permission card went up, the session left the
    /// strip and the count went down. "How many agents do I have running" is the question
    /// this bar exists to answer, and a session waiting on you is running.
    ///
    /// A session whose turn has *ended* is the one case that is not: it counts nothing,
    /// which is why the strip counts the same list the panel draws.
    @MainActor
    init(_ activity: ActivityStore) {
        let sessions = activity.visibleSessions
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
    /// How many requests are held. Distinct from the amber pill, which says *that* someone
    /// is waiting: this says how many, and four queued approvals is a different afternoon
    /// from one.
    var waiting: Int = 0
    /// What to say when nothing is running. The plan is the one thing that keeps moving on
    /// a machine with no session open — another window, another host, the window's own
    /// clock — so it is what the bar carries while it has no agent to draw.
    var quota: UsageLimitsReader.Reading?
    var showsRemaining = false

    private var count: Int { reading.count }
    /// The pill changes colour rather than growing a second badge — at 32pt there is room
    /// for one signal, and "someone is waiting for you" outranks everything else.
    private var needsYou: Bool { reading.needsYou }

    /// The bar says one thing at a time. An agent outranks the plan: what is running now is
    /// worth more of a glance than what the week has cost, and two rows of numbers either
    /// side of the hardware would be a dashboard rather than a strip.
    private var showsQuota: Bool { count == 0 && !IdleView.windows(of: quota).isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if showsQuota {
                    // The one that is always there, where it is always there — the same
                    // creature the strip puts on the left when Claude Code is running, held
                    // still because nothing is. Then the tightest window, the one that ends
                    // an afternoon. The countdown is dropped: at eleven characters a window
                    // it was what pushed the chip onto a second line, and it is the half
                    // nobody reads from across a room.
                    HStack(spacing: IdleView.spriteGap) {
                        AgentGlyph(
                            agent: .claude, pixel: IdleView.glyphPixel,
                            isBreathing: false, isFighting: false)
                        UsageLimitsStrip(
                            reading: quota, showsRemaining: showsRemaining, maximum: 1,
                            showsReset: false)
                    }
                    .fixedSize()
                } else {
                    HStack(spacing: 3) {
                        // A sprite fights only for an agent that is doing something: a
                        // session that has stopped holds still, and dims, from the corner of
                        // a screen. The index staggers the beat, so a row of them takes
                        // turns rather than hopping in unison — and turns them to face each
                        // other.
                        ForEach(Array(reading.agents.enumerated()), id: \.element.agent.rawValue) {
                            index, entry in
                            AgentGlyph(
                                agent: entry.agent, pixel: IdleView.glyphPixel,
                                isBreathing: entry.isWorking, isFighting: entry.isWorking,
                                beat: index)
                        }
                    }
                }
            }
            .frame(
                width: IdleView.flank(
                    for: reading, waiting: waiting, quota: quota,
                    showsRemaining: showsRemaining) - IdleView.inset)
            .padding(.trailing, IdleView.inset)

            // The cutout itself: nothing is ever drawn here.
            Color.clear.frame(width: notchWidth)

            HStack(spacing: 4) {
                if showsQuota {
                    // The week, on the other shoulder. Second because it moves slowly: at
                    // 8% on a Tuesday it is background, where the five-hour window is news.
                    // And the resting creature at the far edge, mirroring the one on the
                    // left: both sprites sit outermost, both numbers against the hardware.
                    HStack(spacing: IdleView.spriteGap) {
                        UsageLimitsStrip(
                            reading: quota, showsRemaining: showsRemaining, dropFirst: 1,
                            maximum: 1, showsReset: false)
                        IdleSprite()
                    }
                    .fixedSize()
                }
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
            }
            .frame(
                width: IdleView.flank(
                    for: reading, waiting: waiting, quota: quota,
                    showsRemaining: showsRemaining) - IdleView.inset)
            .padding(.leading, IdleView.inset)
        }
        // The content stays level with the cutout; only the painted shape reaches below it.
        .frame(height: notchHeight, alignment: .center)
    }

    /// Gap between the content and the cutout, on each side.
    static let inset: CGFloat = 5

    /// How big a sprite the resting strip carries. Two thirds of the 32pt band: at 20pt a
    /// creature reads as a mark, and at 24 it reads as itself.
    static let glyphPixel: CGFloat = 2.4

    /// Between the resting creature and the window beside it.
    static let spriteGap: CGFloat = 4

    /// What the enclosing `HStack` puts behind each chip — 6pt on the left of the cutout,
    /// 4 on the right. Counted in the width, because it is drawn whether or not anyone
    /// remembered it: forgetting the 6 is what left the first chip a point short.
    static let quotaGap: CGFloat = 6

    /// Sized to the content: one agent must not reserve room for four, and an empty strip
    /// must be exactly zero wide or it paints black shoulders beside the notch.
    ///
    /// The inset is part of this number. It was not at first, and the window came out ten
    /// points narrower than what it had to draw — so the count was clipped by the edge it
    /// was supposed to sit inside.
    static func flank(
        for reading: IdleReading, waiting: Int = 0,
        quota: UsageLimitsReader.Reading? = nil, showsRemaining: Bool = false
    ) -> CGFloat {
        // Nothing running: the plan, if there is one to show.
        //
        // This used to return zero unconditionally — a Mac doing nothing looked like a Mac
        // doing nothing, and the quota was not allowed to open two black shoulders on a
        // machine with no session. It earns them: it is the one number that keeps moving
        // while nothing here is running, and reading it should not cost a hover.
        //
        // Zero still, when there is nothing to say. A bridge that was never installed
        // leaves the cutout exactly as the hardware made it.
        guard reading.count > 0 else {
            let windows = windows(of: quota)
            guard !windows.isEmpty else { return 0 }

            // Measured off the layout, not off a sentence. The window is sized before it
            // draws, so a width taken on faith is a chip wrapped onto a second line inside
            // the menu bar — which is exactly what a joined string bought: it counted two
            // spaces where the `HStack` puts two 3pt gaps, and none of the 6pt the strip
            // sits behind.
            func chip(_ index: Int) -> CGFloat {
                guard windows.indices.contains(index) else { return 0 }
                return UsageLimitsStrip.width(
                    for: windows[index], showsRemaining: showsRemaining, showsReset: false)
            }
            // The agent's glyph is always drawn — it falls back to pixel art of our own
            // when no sheet is installed. The resting creature is not: no sheet, no room
            // reserved, and the week's number closes up against the cutout rather than
            // sitting beside a hole.
            let resting = IdleSprite.sheet == nil ? 0 : IdleSprite.side + spriteGap
            let left = AgentGlyph.width(pixel: glyphPixel) + spriteGap + chip(0) + quotaGap
            let right = chip(1) + resting + quotaGap
            return max(left, right) + inset
        }

        // A sprite plus its 3pt gap, with a floor of 24 for the count pill — wide enough
        // for two digits, which is more concurrent sessions than anyone runs. Plus, once,
        // the room a flame needs in front of the creature that breathes one: the sprites
        // are flush against the cutout, so without it the fire is clipped by the shoulder's
        // own edge on the frame it leaves the mouth.
        var left = max(CGFloat(reading.agents.count) * AgentGlyph.width(pixel: glyphPixel), 24)
        if AgentGlyph.breathes(reading.agents.map(\.agent)) { left += AnimatedSprite.muzzleRoom }
        let right: CGFloat = 24 + (waiting > 0 ? 26 : 0)

        // Both shoulders are one number — the window is symmetric around the cutout — so
        // the wider side decides. An asymmetric window would centre the notch off the
        // hardware it is drawn around.
        return max(left, right) + inset
    }

    /// The two windows the resting bar has room for, in the order it draws them: the
    /// tightest on the left, the next on the right. Empty when the bridge has published
    /// nothing, which is what keeps the cutout bare.
    static func windows(of reading: UsageLimitsReader.Reading?) -> [NamedWindow] {
        Array(reading?.limits.windows.prefix(2) ?? [])
    }
}

/// The creature that keeps the cutout company when no agent does.
///
/// Its own sheet — `idle.png`, beside the agents' in `~/.perch/sprites` — because this one
/// is not an agent: nothing is running, and drawing Claude's would say something untrue.
/// Held on its first frame rather than played: a creature flapping its wings in the menu
/// bar for hours is noise, and the bar is meant to be glanceable, not animated.
///
/// Nothing installed is nothing drawn, and the width follows: the two percentages simply
/// close up. Perch ships no sheet — what would be in one is not ours to redistribute.
struct IdleSprite: View {
    /// The same 24pt box an agent's glyph occupies, so a strip that swaps one for the
    /// other does not change height or jump.
    static let side: CGFloat = AgentGlyph.width(pixel: IdleView.glyphPixel) - 3

    static var sheet: SpriteSheet? {
        if let cached { return cached }
        let loaded = SpriteLocation.sheetURL(
            named: "idle",
            bundled: Bundle.main.url(
                forResource: "idle", withExtension: "png", subdirectory: "Sprites")
        ).flatMap(SpriteSheet.load)
        cached = .some(loaded)
        return loaded
    }

    /// Read once. A miss costs a directory lookup, and this is on the path of a view that
    /// redraws with the clock.
    nonisolated(unsafe) private static var cached: SpriteSheet??

    var body: some View {
        if let sheet = Self.sheet {
            AnimatedSprite(sheet: sheet, side: Self.side, isPlaying: false)
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

/// Hover preview: which sessions are running, and what today has cost.
///
/// It used to answer *how many* — a count, the last tool call from whichever session
/// emitted it, and the day's total. Which is the one question the resting strip already
/// answers, so hovering bought a bigger version of what you could see without hovering.
/// The band beside the cutout takes the totals, and the body says who: one row per
/// session, the same order the panel lists them in.
struct PeekView: View {
    let notch: CGSize
    /// Plain data rather than the stores, so the off-screen preview draws the same view
    /// the app does instead of an imitation of it that can drift.
    let sessions: [SessionSnapshot]
    /// What to say when nothing is running: the last thing that happened.
    let fallback: String
    let tokens: String
    let cost: String

    /// Three rows is the most that fits before the peek becomes the panel.
    private var shown: [SessionSnapshot] { Array(sessions.prefix(3)) }
    private var hidden: Int { max(0, sessions.count - shown.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            PanelHeader {
                Text(headline)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            } trailing: {
                Text(tokens)
                    .font(Theme.mono(10, .semibold))
                    .foregroundStyle(Theme.primary)
                Text(cost)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.active)
                // Without this the peek reads as a dead end: nothing suggests the panel
                // goes any further.
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
            }

            VStack(alignment: .leading, spacing: 3) {
                if shown.isEmpty {
                    Text(fallback)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    ForEach(shown, id: \.id) { session in
                        PeekRow(session: session)
                    }
                    if hidden > 0 {
                        Text(t("+%lld more", hidden))
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.tertiary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
        }
    }

    /// Live, not working — the same count the resting strip shows, so the number does not
    /// change under the cursor on the way in.
    private var headline: String {
        let live = sessions.count
        let blocked = sessions.filter { $0.status.needsYou }.count
        guard live > 0 else { return t("Perch") }
        guard blocked > 0 else { return t("%lld live", live) }
        return t("%lld live · %lld on you", live, blocked)
    }
}

/// One session, on one line: who, what, how long, and whether it needs you.
struct PeekRow: View {
    let session: SessionSnapshot

    var body: some View {
        HStack(spacing: 6) {
            AgentGlyph(agent: session.agent, pixel: 1.5, isBreathing: session.isWorking)

            Text(session.projectName ?? t("session"))
                .font(Theme.mono(10))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)

            Text(session.activitySummary.text)
                .font(Theme.mono(10))
                .foregroundStyle(session.activitySummary.tint)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            Text(SessionCardView.elapsed(since: session.startedAt))
                .font(Theme.mono(9))
                .foregroundStyle(Theme.tertiary)
                .monospacedDigit()

            StatusDot(status: session.status)
        }
    }
}

// MARK: - Expanded

private enum Tab: String, CaseIterable {
    case activity, stats, rank
}

private struct ExpandedView: View {
    let notch: CGSize
    let model: AppModel
    let onClose: () -> Void
    @State private var tab: Tab = .activity

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelHeader {
                TabBar(selection: tab) { tab = $0 }
            } trailing: {
                // Quota lives in the header on every tab: it is the one number you want
                // without having to go looking for it.
                UsageLimitsStrip(
                    reading: model.usage.limits,
                    showsRemaining: model.preferences.showsRemainingQuota)

                // Muting is a thing you want *while* a machine is being noisy, which is
                // never the moment to go and find a settings window.
                ShoulderButton(
                    symbol: model.sounds.enabled ? "speaker.wave.2" : "speaker.slash",
                    tint: model.sounds.enabled ? Theme.tertiary : Theme.warning,
                    help: model.sounds.enabled ? t("Mute sounds") : t("Unmute sounds")
                ) { model.updateSounds(model.sounds.toggledEnabled) }

                // With no Dock icon and no menu bar item, this is the only way in.
                ShoulderButton(symbol: "gearshape", help: t("Settings")) {
                    model.showSettings()
                }

                // An explicit close, so getting out never depends on finding the collar
                // or knowing about escape.
                ShoulderButton(symbol: "xmark", help: t("Close (esc)")) { onClose() }
            }

            Group {
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
            .padding(.horizontal, 14)
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

    /// The one row that is open, if any.
    ///
    /// One at a time, and closed to begin with. Six sessions of full cards is four screens
    /// of scrolling, and a panel you have to scroll is a panel you do not glance at.
    @State private var opened: String?

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
                        Array(activity.visibleSessions.enumerated()), id: \.element.id
                    ) { position, session in
                        SessionCardView(
                            session: session,
                            tasks: model.tasks.board(for: session.id),
                            layout: model.preferences.layout,
                            isSelected: model.switcher.isOpen && model.switcher.index == position,
                            isOpen: opened == session.id,
                            onToggle: {
                                opened = opened == session.id ? nil : session.id
                            },
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
                        activity.visibleSessions.indices.contains(index)
                    else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        scroller.scrollTo(activity.visibleSessions[index].id, anchor: .center)
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

