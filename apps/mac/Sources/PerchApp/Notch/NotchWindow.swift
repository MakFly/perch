import AppKit

/// Borderless, non-activating canvas pinned under the notch.
///
/// It must float above the menu bar, follow the user across Spaces and full-screen apps,
/// and never steal focus from the app they are actually working in.
///
/// The window is a fixed canvas, far larger than anything Perch draws at rest, and it
/// never resizes — the panel moves inside it. That is what buys a single animation curve
/// (see `NotchState.canvas`), and it is what the other apps in this category do: probing
/// Vibe Island 1.0.42 with `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` puts
/// its window at a constant 680×580 while mouse events 300pt below the cutout still land
/// in the app underneath.
///
/// Which is the catch a permanent canvas brings: a window that large would swallow every
/// click in the top third of the screen. So it is transparent to the mouse whenever
/// nothing is painted, and `NotchController` drives the notch's own hover and clicks from
/// a global event monitor instead.
final class NotchWindow: NSPanel {
    /// Only true while expanded, so keyboard shortcuts work without ever grabbing
    /// focus during idle or hover.
    var wantsKeyboard = false

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // Above the menu bar *and* above its extras: at +1 a status item drawn beside the
        // cutout can end up on top of the panel that is supposed to cover it.
        level = .statusBar + 2
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        acceptsMouseMovedEvents = true
        // Nothing is painted at launch, so the canvas starts out invisible to the mouse.
        ignoresMouseEvents = true
    }

    /// Whether the canvas takes mouse events at all.
    ///
    /// True only while something is drawn. The rest of the time the canvas covers a large
    /// stretch of the top of the screen with nothing in it, and a window that answers for
    /// pixels it does not paint is a window that eats other people's clicks.
    var isInteractive: Bool {
        get { !ignoresMouseEvents }
        set { ignoresMouseEvents = !newValue }
    }

    override var canBecomeKey: Bool { wantsKeyboard }
    override var canBecomeMain: Bool { false }
}
