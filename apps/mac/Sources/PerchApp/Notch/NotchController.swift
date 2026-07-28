import AppKit
import Observation
import PerchKit
import SwiftUI

/// Owns the panel and applies the interaction rules from `NotchInteraction`.
///
/// The controller deliberately holds no rules of its own: it forwards events to the
/// machine and executes the effects it returns, so behaviour stays testable.
@MainActor
@Observable
final class NotchController {
    private(set) var state: NotchState = .idle
    private(set) var geometry: NotchGeometry
    /// Bumped on every hook event so the idle view can pulse without resizing the panel.
    private(set) var activityPulse: Int = 0

    @ObservationIgnored private var interaction = NotchInteraction()
    @ObservationIgnored private let window = NotchWindow()
    @ObservationIgnored private var screen: NSScreen
    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    /// Hover and clicks, watched from outside the view tree. See `startWatchingTheCursor`.
    @ObservationIgnored private var mouseMonitors: [Any] = []
    @ObservationIgnored private var cursorTimer: Timer?
    @ObservationIgnored private var isHovering = false

    /// Points added to what macOS reports for the cutout, from Settings.
    @ObservationIgnored private var tuning: (width: Double, height: Double) = (0, 0)

    init() {
        // `.main` follows the focused window; at launch we want the screen that owns the
        // menu bar, which is always screens[0].
        screen = NSScreen.screens.first ?? NSScreen.main!
        geometry = NotchGeometry.detect(on: screen)
    }

    /// Re-measures and redraws immediately, so dragging a slider in Settings shows its
    /// effect on the notch rather than at the next relaunch.
    func applyTuning(width: Double, height: Double) {
        tuning = (width, height)
        geometry = NotchGeometry.detect(on: screen).adjusted(width: width, height: height)
        pinCanvas()
    }

    func start(content: some View) {
        window.contentView = NSHostingView(rootView: AnyView(content))
        pinCanvas()
        window.orderFrontRegardless()
        startWatchingTheCursor()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersChanged() }
        }
    }

    /// The window's frame, set once and then left alone. Everything that moves, moves
    /// inside it.
    private func pinCanvas() {
        let canvas = NotchState.canvas(notch: geometry.size)
        window.setFrame(geometry.panelFrame(for: canvas, on: screen), display: true)
    }

    /// Hover is measured against the panel's rect, not reported by the view tree.
    ///
    /// `onHover` cannot work here any more. While idle the window ignores the mouse — it
    /// has to, or a 680×660 canvas would answer for every click in the top half of the
    /// screen — so no tracking area is ever entered. By the time the canvas does take
    /// events the cursor is already inside it, and AppKit does not synthesise the
    /// `mouseEntered` that was missed. SwiftUI therefore believes the panel was never
    /// hovered, and never reports leaving it either: the panel opened and stayed open.
    ///
    /// So the cursor is watched directly, from two angles.
    ///
    /// The monitors are what make it feel instant, and both are installed because either
    /// can be the one that sees a given move — the global one while the events belong to
    /// another app, the local one once they belong to us.
    ///
    /// The timer is what makes it correct. A cursor can arrive somewhere without a single
    /// event being emitted: `CGWarpMouseCursorPosition` does exactly that, and so does
    /// coming back from a Space switch or from under a window that was just closed. The
    /// old panel got away with it because it resized on every transition, and resizing a
    /// window forces AppKit to re-evaluate its tracking areas; a window that never resizes
    /// has no such accident to rely on. A quarter second is far below noticing, and the
    /// monitors mean it is almost never the one that reports the crossing.
    ///
    /// Mouse events need no permission to observe; only keyboard ones do. Perch still
    /// never asks for Accessibility.
    private func startWatchingTheCursor() {
        mouseMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) {
                [weak self] event in
                MainActor.assumeIsolated { self?.sampleCursor(clicked: event.type == .leftMouseDown) }
            },
            NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                MainActor.assumeIsolated { self?.sampleCursor(clicked: false) }
                return event
            },
        ].compactMap { $0 }

        cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.sampleCursor(clicked: false) }
        }
    }

    /// How close the cursor has to come before the resting strip offers its controls.
    ///
    /// Generously wide on purpose. The strip changes width when the controls appear, and
    /// `panelRect` — what clicks are tested against — takes the new width on the frame
    /// the flag flips while the drawing takes 0.38s to catch up. A margin the cursor
    /// needs 140pt of travel to cross means that gap is always spent approaching, never
    /// clicking.
    private static let proximity = (x: CGFloat(140), y: CGFloat(60))

    /// Whether the cursor is close enough for the resting strip to offer its controls.
    private(set) var isCursorNear = false

    /// Exactly when the strip draws mute and settings — read by the view to draw them and
    /// by the click routing to know they are there.
    ///
    /// One answer to this, because two would be a gear that can be clicked where none is
    /// drawn. That was already true with nothing running: the strip is zero wide, drew no
    /// icons, and a click on the right-hand end of the *cutout* still opened Settings.
    var showsIdleControls: Bool { state == .idle && idleFlank > 0 && isCursorNear }

    private func sampleCursor(clicked: Bool) {
        // Sampled before anything else, and from the same rect the strip is drawn in: the
        // controls are what widen it, so the flag has to be current before its own effect
        // is measured.
        let near = panelRect.insetBy(dx: -Self.proximity.x, dy: -Self.proximity.y)
            .contains(NSEvent.mouseLocation)
        if near != isCursorNear { isCursorNear = near }

        // Hysteresis: it takes 6pt more to leave than it took to enter.
        //
        // Without it the boundary is a single line, and a hand resting on it crosses that
        // line several times a second — each crossing starting a 220ms collapse and then
        // cancelling it. The panel never settled, and the flicker was blamed on the
        // animation rather than on the hit test underneath it.
        let rect = isHovering ? panelRect.insetBy(dx: -6, dy: -6) : panelRect
        let inside = rect.contains(NSEvent.mouseLocation)

        // A click on the resting strip opens the panel. Only from idle: once the canvas
        // takes events, the strip is a real tap target and SwiftUI owns it — handling the
        // click here too would toggle it twice.
        if clicked {
            guard inside, state == .idle else { return }
            // Mute and settings sit at the trailing edge of the resting strip. They cannot
            // be buttons — the canvas ignores the mouse while idle, which is what lets the
            // menu bar underneath keep working — so the click is routed here, against the
            // same rectangles the strip drew them in.
            let hotspots = IdleStrip.hotspots(
                in: panelRect, contentHeight: geometry.size.height)
            let point = NSEvent.mouseLocation
            if !showsIdleControls {
                send(.tappedNotch)
            } else if hotspots.mute.contains(point) {
                onIdleIcon?(.mute)
            } else if hotspots.settings.contains(point) {
                onIdleIcon?(.settings)
            } else {
                send(.tappedNotch)
            }
            return
        }

        guard inside != isHovering else { return }
        isHovering = inside
        send(inside ? .hoverEntered : .hoverExited)
    }

    /// Where the panel actually is on screen: centred in the canvas, hanging from its top
    /// edge — which is what the view does with it.
    private var panelRect: CGRect {
        let canvas = window.frame
        let size = panelSize
        return CGRect(
            x: canvas.midX - size.width / 2,
            y: canvas.maxY - size.height,
            width: size.width,
            height: size.height)
    }

    // MARK: - Events

    func toggleExpanded() {
        send(.tappedNotch)
    }

    /// A click on the panel body — opens the panel from a peek, ignored once expanded.
    func tapBody() {
        send(.tappedBody)
    }

    func dismiss() {
        send(.escapePressed)
    }

    /// Opens the panel outright, whatever it was doing. The switcher's shortcut has to
    /// work from idle and from a peek alike, and `toggleExpanded` would close it on the
    /// second press — which is exactly what cycling does.
    func expand() {
        guard state != .expanded else { return }
        send(.tappedNotch)
        if state != .expanded { send(.tappedNotch) }
    }

    /// Extra height the current request needs. A question with four options, or a plan,
    /// does not fit the height a `Bash(...)` prompt does — and a card that has to scroll
    /// to reach its own buttons is unanswerable.
    private(set) var alertExtraHeight: CGFloat = 0
    /// And how much wider. A plan is prose: at 520pt every sentence wraps three times, and
    /// a wrapped plan reads as a wall rather than as a list of steps.
    private(set) var alertExtraWidth: CGFloat = 0

    /// Called when a permission arrives or the queue empties.
    func showAlert(_ isWaiting: Bool, extraHeight: CGFloat = 0, extraWidth: CGFloat = 0) {
        // One request replacing another leaves the state alone but changes the height;
        // publishing it is enough, because the panel's size is now something SwiftUI
        // animates rather than something AppKit is told about.
        alertExtraHeight = isWaiting ? extraHeight : 0
        alertExtraWidth = isWaiting ? extraWidth : 0
        send(isWaiting ? .permissionArrived : .permissionsCleared)
    }

    /// Shows the peek for something worth a glance, and takes it back without being asked.
    /// Ignored unless the notch is at rest — see `NotchInteraction`.
    func reveal() {
        send(.revealRequested)
    }

    /// What the flash is currently saying. Held rather than passed, because the state
    /// machine owns *whether* it shows and this owns *what* — and the notice has to
    /// survive the transition out, or the last frame of the animation is an empty strip.
    private(set) var notice: NotchFlash?

    /// A line of news at the cutout, taken back on its own. Ignored unless the notch is
    /// at rest: a panel someone opened outranks anything Perch has to say.
    func flash(_ notice: NotchFlash) {
        guard state == .idle else { return }
        self.notice = notice
        send(.flashRequested)
    }

    func flashActivity() {
        activityPulse &+= 1
    }

    private func send(_ event: NotchInteraction.Event) {
        let effects = interaction.handle(event)
        for effect in effects {
            switch effect {
            case .cancelCollapse:
                collapseTask?.cancel()
                collapseTask = nil
            case .scheduleCollapse(let milliseconds):
                scheduleCollapse(after: .milliseconds(milliseconds))
            }
        }
        apply(interaction.state)
    }

    private func scheduleCollapse(after delay: Duration) {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.send(.collapseTimerFired)
        }
    }

    // MARK: - Presentation

    /// The two things the resting strip offers besides opening: silence, and settings.
    enum IdleIcon { case mute, settings }
    var onIdleIcon: ((IdleIcon) -> Void)?

    /// Called when the panel starts or stops being drawn, so work that only matters while
    /// someone is looking — re-reading transcripts — runs then and not the rest of the day.
    var onPanelVisibilityChanged: ((Bool) -> Void)?

    private func apply(_ next: NotchState) {
        guard next != state else { return }
        let wasDrawing = state.drawsPanel
        state = next
        if next.drawsPanel != wasDrawing { onPanelVisibilityChanged?(next.drawsPanel) }
        window.wantsKeyboard = next.wantsKeyboard
        // The canvas answers for the mouse only while it has something under the cursor to
        // answer for. At rest the strip is watched from the outside instead.
        window.isInteractive = next.drawsPanel

        if next.wantsKeyboard { window.makeKey() }
    }

    /// How far the resting state reaches past the cutout, set from what is running.
    private(set) var idleFlank: CGFloat = 0

    /// Records how far the resting content reaches past the cutout — an agent starting or
    /// stopping should widen or narrow the strip. Publishing it is the whole job now:
    /// `panelSize` changes, and the same spring that runs every other transition carries
    /// it.
    func setIdleFlank(_ flank: CGFloat) {
        guard flank != idleFlank else { return }
        idleFlank = flank
    }

    /// What the panel measures right now. The only thing the view animates.
    var panelSize: CGSize {
        var size = state.size(notch: geometry.size, flank: idleFlank)
        if state == .alert {
            size.height += alertExtraHeight
            size.width += alertExtraWidth
        }
        return size
    }

    private func screenParametersChanged() {
        screen = NSScreen.screens.first ?? screen
        geometry = NotchGeometry.detect(on: screen)
            .adjusted(width: tuning.width, height: tuning.height)
        // A display change is a cut, not a transition: re-pin and redraw where we are.
        pinCanvas()
    }
}
