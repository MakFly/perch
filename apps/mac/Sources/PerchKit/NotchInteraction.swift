import Foundation

/// The notch's interaction rules, as a pure state machine.
///
/// Extracted from the view layer so the behaviour can be tested without a display or
/// synthetic mouse events — the two bugs this replaced (a panel that never closed on
/// hover-out, and a click anywhere inside it collapsing it) were both invisible to unit
/// tests while the rules lived inside SwiftUI modifiers.
public struct NotchInteraction: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        case hoverEntered
        case hoverExited
        /// A click on the cutout strip: toggles the full panel from any state.
        case tappedNotch
        /// A click on the panel body. Only meaningful while peeking — the peek has no
        /// controls of its own, so its whole surface opens the panel. Once expanded the
        /// body belongs to its controls and a stray click must do nothing.
        case tappedBody
        case escapePressed
        case permissionArrived
        case permissionsCleared
        /// Perch has something worth a glance but not an answer — a quota window crossing
        /// the line you set. Shows the peek and takes it away again on its own.
        case revealRequested
        /// The grace period after hover-out elapsed.
        case collapseTimerFired
    }

    /// What the controller must do after a transition, beyond changing state.
    public enum Effect: Sendable, Equatable {
        case scheduleCollapse(milliseconds: Int)
        case cancelCollapse
    }

    public private(set) var state: NotchState = .idle

    public init(state: NotchState = .idle) {
        self.state = state
    }

    /// Grace periods: crossing the edge of a panel should not make it flicker, and a
    /// bigger panel needs longer because there is more empty space to cross.
    public static let peekGrace = 220
    public static let expandedGrace = 700
    /// A peek nobody asked for has to last long enough to read and short enough to forgive.
    public static let revealGrace = 4_000

    @discardableResult
    public mutating func handle(_ event: Event) -> [Effect] {
        // A pending permission owns the notch: nothing but a decision dismisses it, or a
        // blocked Claude Code session could be hidden by an idle mouse movement.
        if state == .alert {
            switch event {
            case .permissionsCleared:
                state = .idle
                return [.cancelCollapse]
            case .permissionArrived:
                return []
            default:
                return []
            }
        }

        switch event {
        case .permissionArrived:
            state = .alert
            return [.cancelCollapse]

        case .hoverEntered:
            switch state {
            case .idle:
                state = .peek
                return [.cancelCollapse]
            case .peek, .expanded:
                // Keep it open while the cursor is inside.
                return [.cancelCollapse]
            case .alert:
                return []
            }

        case .hoverExited:
            switch state {
            case .peek:
                return [.scheduleCollapse(milliseconds: Self.peekGrace)]
            case .expanded:
                return [.scheduleCollapse(milliseconds: Self.expandedGrace)]
            case .idle, .alert:
                return []
            }

        case .tappedNotch:
            state = state == .expanded ? .idle : .expanded
            return [.cancelCollapse]

        case .tappedBody:
            // Peek is a preview with nothing to click, so treating its whole surface as
            // "open me" is the only way out that does not require hitting a 32pt strip.
            guard state == .peek else { return [] }
            state = .expanded
            return [.cancelCollapse]

        case .revealRequested:
            // Only from rest. Interrupting a panel someone opened, or one they are
            // hovering, to show them something they did not ask for is the behaviour that
            // makes people quit an app that lives in the menu bar.
            guard state == .idle else { return [] }
            state = .peek
            return [.scheduleCollapse(milliseconds: Self.revealGrace)]

        case .escapePressed:
            guard state != .idle else { return [] }
            state = .idle
            return [.cancelCollapse]

        case .collapseTimerFired:
            guard state == .peek || state == .expanded else { return [] }
            state = .idle
            return []

        case .permissionsCleared:
            return []
        }
    }
}
