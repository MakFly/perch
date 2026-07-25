import CoreGraphics

/// How much of Perch is on screen right now.
public enum NotchState: String, Equatable, Sendable, CaseIterable {
    /// Blends into the cutout; only a thin activity line is drawn.
    case idle
    /// Hover preview: sessions, tokens today.
    case peek
    /// Full panel with tabs.
    case expanded
    /// A tool call is waiting on the user. Takes priority over everything else.
    case alert

    /// True only when Perch draws a panel. Idle must leave the cutout looking exactly
    /// like the hardware.
    public var drawsPanel: Bool { self != .idle }

    /// How far the resting state reaches past the cutout on each side.
    ///
    /// Zero means the notch is invisible when nothing is running — the cutout looks exactly
    /// like the hardware. As soon as an agent *is* running there is something worth seeing
    /// without hovering, and the menu bar either side of the cutout is the only place to
    /// put it. Sized to the content rather than fixed, so one agent does not reserve room
    /// for four.
    public func size(notch: CGSize, flank: CGFloat = 0) -> CGSize {
        switch self {
        case .idle:
            // Any wider than the content and the black shoulders read as a bar stuck to
            // the notch rather than as part of it.
            //
            // The extra height matters more than it looks: with nothing running it is
            // transparent and only makes the hover target easier to hit, but as soon as
            // the strip is painted it is what lets its rounded bottom show *below* the
            // bezel. Stopping flush with the cutout makes the strip read as a rectangle
            // glued to the notch instead of as one shape wrapped around it.
            return CGSize(width: notch.width + flank * 2, height: notch.height + (flank > 0 ? 10 : 6))
        case .peek:
            return CGSize(width: max(notch.width + 180, 380), height: notch.height + 96)
        case .expanded:
            return CGSize(width: 680, height: 440)
        case .alert:
            return CGSize(width: 520, height: notch.height + 148)
        }
    }

    /// The window's one and only frame.
    ///
    /// The panel used to be the window: every transition resized the `NSWindow` through
    /// AppKit while the content animated through SwiftUI, on two curves of two different
    /// durations. Nothing that arrives on two curves reads as one shape moving.
    ///
    /// So the window is now a fixed, transparent canvas big enough for the largest state,
    /// and the panel is drawn inside it. Only SwiftUI moves anything, so there is only one
    /// curve left. The headroom covers what an alert adds on top of its own size — a
    /// question with four options is already 216pt taller than a plain permission.
    public static func canvas(notch: CGSize, headroom: CGFloat = 220) -> CGSize {
        let sizes = allCases.map { $0.size(notch: notch) }
        return CGSize(
            width: sizes.map(\.width).max() ?? notch.width,
            height: (sizes.map(\.height).max() ?? notch.height) + headroom)
    }

    /// Alerts need keyboard focus for the approve/deny shortcuts.
    public var wantsKeyboard: Bool {
        self == .expanded || self == .alert
    }
}
