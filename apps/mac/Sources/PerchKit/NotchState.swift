import CoreGraphics

/// How much of Perch is on screen right now.
public enum NotchState: String, Equatable, Sendable, CaseIterable {
    /// Blends into the cutout; only a thin activity line is drawn.
    case idle
    /// One line, level with the cutout, taken back on its own after a couple of seconds.
    ///
    /// A turn ending used to produce a sound and nothing else, or — with "open the panel
    /// when a task finishes" on — a full four-second peek, which is a panel's worth of
    /// interruption for a sentence's worth of news. This is the middle the notch was
    /// missing: it says which session finished, and it never asks for the screen.
    case flash
    /// Hover preview: sessions, tokens today.
    case peek
    /// Full panel with tabs.
    case expanded
    /// A tool call is waiting on the user. Takes priority over everything else.
    case alert

    /// True only when Perch draws a panel. Idle must leave the cutout looking exactly
    /// like the hardware.
    public var drawsPanel: Bool { self != .idle }

    /// Whether the state's content hangs below the bezel, or stays level with the cutout
    /// the way the resting strip does. A flash is a wider strip, not a shorter panel.
    public var hangsBelowTheBezel: Bool { self != .idle && self != .flash }

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
        case .flash:
            // Two shoulders wide enough for a sentence, and no taller than the painted
            // resting strip: the notice arrives in the band the cutout already owns, so
            // nothing has to grow downward over what you were reading.
            return CGSize(width: max(notch.width + 300, 480), height: notch.height + 10)
        case .peek:
            // Sized for the band beside the cutout plus three session rows. Wider than it
            // was because the totals now sit level with the hardware, where the room is
            // whatever the cutout does not take.
            return CGSize(
                width: max(notch.width + 240, 440), height: notch.height + Self.bodyInset + 84)
        case .expanded:
            return CGSize(width: 680, height: 440 + Self.bodyInset)
        case .alert:
            return CGSize(width: Self.alertWidth, height: notch.height + Self.bodyInset + 148)
        }
    }

    /// The width a request is answered at before anything asks for more — see
    /// `AppModel.extraWidth`. Named because the card that measures itself has to measure
    /// against the same number the panel is drawn at.
    public static let alertWidth: CGFloat = 520

    /// How far the inverse curve on each shoulder reaches *past* the panel's own edge.
    ///
    /// That curve is the whole reason the panel reads as wrapped around the cutout rather
    /// than hung under it, and it is drawn outside the rect it belongs to — so the window
    /// has to be wider than the widest panel or the curve is simply not on screen. It was
    /// not: the expanded panel is exactly as wide as the canvas was, so its two top corners
    /// met the menu bar on a hard 90°, while the resting strip — narrower than the canvas,
    /// with room to spill into — curved correctly. The same shape, clipped in one state
    /// and not the other, which is why it read as two different designs.
    public static let shoulder: CGFloat = 12

    /// Air between the bezel line and a panel's first row.
    ///
    /// The body starts where the collar flares, and the flare is a curve — so a header
    /// laid flush against that line is a header with a rounded corner biting into both its
    /// ends. It read as cropped rather than as the top of something.
    public static let bodyInset: CGFloat = 10

    /// The window's one and only frame.
    ///
    /// The panel used to be the window: every transition resized the `NSWindow` through
    /// AppKit while the content animated through SwiftUI, on two curves of two different
    /// durations. Nothing that arrives on two curves reads as one shape moving.
    ///
    /// So the window is now a fixed, transparent canvas big enough for the largest state,
    /// and the panel is drawn inside it. Only SwiftUI moves anything, so there is only one
    /// curve left. The headroom covers what an alert adds on top of its own size — a
    /// question with four options is already 216pt taller than a plain permission — and the
    /// sideroom covers the shoulders.
    public static func canvas(notch: CGSize, headroom: CGFloat = 220) -> CGSize {
        let sizes = allCases.map { $0.size(notch: notch) }
        return CGSize(
            width: (sizes.map(\.width).max() ?? notch.width) + shoulder * 2,
            height: (sizes.map(\.height).max() ?? notch.height) + headroom)
    }

    /// Alerts need keyboard focus for the approve/deny shortcuts.
    public var wantsKeyboard: Bool {
        self == .expanded || self == .alert
    }
}
