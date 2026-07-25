import Foundation

/// The ⌘Tab-style session switcher, as a state machine.
///
/// Two gestures share one shortcut, which is what makes it feel native:
///
/// - **Tap** — the panel opens on the first session and stays. Pick with ↑↓, Enter jumps.
/// - **Hold** — each press while the modifier is down advances the selection; releasing
///   the modifier jumps to whatever is selected. This is ⌘Tab, and it is why the release
///   has to be a distinct event rather than a timeout.
///
/// Keeping it pure means the wrap-around, the empty list and the release-without-move
/// cases are testable without a global hotkey or a window.
public struct SessionSwitcher: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        case shortcutPressed(reverse: Bool)
        case modifierReleased
        case arrow(down: Bool)
        case confirmed
        case cancelled
    }

    public enum Outcome: Sendable, Equatable {
        case open
        case moved
        case jump(index: Int)
        case close
        case nothing
    }

    public private(set) var isOpen = false
    public private(set) var index = 0
    /// True once the shortcut has been pressed a second time without releasing: that is
    /// what separates a cycle from a tap, and only a cycle jumps on release.
    public private(set) var isCycling = false

    public var count: Int

    public init(count: Int = 0) {
        self.count = count
    }

    public mutating func handle(_ event: Event) -> Outcome {
        guard count > 0 else {
            // Nothing to switch to. Opening an empty switcher just to close it is worse
            // than not reacting.
            if case .shortcutPressed = event { return .nothing }
            isOpen = false
            isCycling = false
            return .nothing
        }

        switch event {
        case .shortcutPressed(let reverse):
            if isOpen {
                move(by: reverse ? -1 : 1)
                isCycling = true
                return .moved
            }
            isOpen = true
            isCycling = false
            // Opening lands on the most recent session, not on the one after it: a tap
            // should show you where you are before it moves you.
            index = 0
            return .open

        case .modifierReleased:
            // A tap — pressed and released without ever advancing — leaves the panel up
            // to pick from with ↑↓. Only a cycle jumps on release.
            guard isOpen, isCycling else { return .nothing }
            let target = index
            isOpen = false
            isCycling = false
            return .jump(index: target)

        case .arrow(let down):
            guard isOpen else { return .nothing }
            move(by: down ? 1 : -1)
            return .moved

        case .confirmed:
            guard isOpen else { return .nothing }
            let target = index
            isOpen = false
            isCycling = false
            return .jump(index: target)

        case .cancelled:
            guard isOpen else { return .nothing }
            isOpen = false
            isCycling = false
            return .close
        }
    }

    /// Wraps in both directions, so holding the shortcut walks the whole list forever.
    private mutating func move(by delta: Int) {
        guard count > 0 else { return }
        index = ((index + delta) % count + count) % count
    }

    /// The list shrank underneath the switcher — a session ended while it was open.
    public mutating func clamp() {
        guard count > 0 else {
            isOpen = false
            isCycling = false
            index = 0
            return
        }
        index = min(index, count - 1)
    }
}
