import CoreGraphics

/// Where the resting strip's two icons are, on screen.
///
/// They cannot be buttons. The canvas ignores the mouse while idle — it has to, or Perch's
/// window would answer for every click in the top of the screen and the menu bar underneath
/// would stop working — so nothing in the strip ever receives a click. The controller
/// already samples the cursor position for hover, and routes the click against these
/// rectangles instead.
///
/// Which makes this the one thing that has to be right: the picture and the target are
/// computed twice, in two files, and a strip whose gear is drawn 5pt from where it can be
/// clicked is worse than one with no gear at all. So the arithmetic lives here, once, and
/// is tested.
public enum IdleStrip {
    public static let inset: CGFloat = 5
    public static let iconSize: CGFloat = 18
    public static let iconSpacing: CGFloat = 4
    public static var iconsWidth: CGFloat { iconSize * 2 + iconSpacing }

    /// `strip` is the whole resting window on screen; `contentHeight` is the cutout's own
    /// height, which is the band the content is centred in. The window is taller than that
    /// — the extra is what lets the painted shape's rounded bottom show below the bezel —
    /// and centring in the window rather than in the band puts both icons half off it.
    public static func hotspots(in strip: CGRect, contentHeight: CGFloat)
        -> (mute: CGRect, settings: CGRect)
    {
        // Screen coordinates grow upward, so the content band hangs from the top edge.
        let y = strip.maxY - contentHeight / 2 - iconSize / 2
        // Flush with the trailing edge: the strip's right-hand group is laid out to the
        // window's edge, with no padding after the last icon.
        let settings = CGRect(
            x: strip.maxX - iconSize, y: y, width: iconSize, height: iconSize)
        let mute = CGRect(
            x: settings.minX - iconSpacing - iconSize, y: y, width: iconSize, height: iconSize)
        return (mute, settings)
    }
}
