import SwiftUI

/// The notch silhouette: square at the top where it meets the bezel, rounded below, with a
/// small inverse curve on each shoulder so it reads as part of the cutout rather than a
/// rectangle stuck under it.
///
/// With a collar it becomes the other shape a notch app needs: the hardware's own width for
/// the height of the menu bar, then a flare out to the full panel below the bezel. A panel
/// wide enough to be worth opening is wide enough to bury the menus either side of the
/// cutout — `Fenêtre` and `Aide` went under a 680pt rectangle — and the menu bar is not
/// ours to take. The collar is what keeps the panel attached to the hardware while the
/// body hangs under it.
struct NotchShape: Shape {
    var bottomRadius: CGFloat = 14
    var shoulderRadius: CGFloat = 7
    /// The hardware's width. Only read when there is a collar.
    var collarWidth: CGFloat = 0
    /// How far down the panel stays collar-width. Zero means the old shape: one strip, full
    /// width from the top — which is what rest and the flash are.
    var collarHeight: CGFloat = 0

    /// The inverse curve where the collar flares into the body, and the body's own top
    /// corners. Not animated: they are constants of the drawing, not of the state.
    private let flare: CGFloat = 9
    private let topRadius: CGFloat = 14

    var animatableData:
        AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>
    {
        get {
            AnimatablePair(
                AnimatablePair(bottomRadius, shoulderRadius),
                AnimatablePair(collarWidth, collarHeight))
        }
        set {
            bottomRadius = newValue.first.first
            shoulderRadius = newValue.first.second
            collarWidth = newValue.second.first
            collarHeight = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let bottom = min(bottomRadius, rect.height / 2, rect.width / 2)
        let shoulder = min(shoulderRadius, rect.height / 2)

        // The body has to be wide enough for a flare and a corner on each side, or the two
        // curves meet in the middle and the outline folds over itself. Below that the
        // collar is the panel, which is exactly what rest and the flash are.
        let room = (rect.width - collarWidth) / 2
        guard collarHeight > 0, room > flare + topRadius else {
            return strip(in: rect, bottom: bottom, shoulder: shoulder)
        }

        let collar = min(collarHeight, rect.height - bottom - topRadius)
        let left = rect.midX - collarWidth / 2
        let right = rect.midX + collarWidth / 2
        var path = Path()

        // Down the collar's left side, out along the bezel, down the body, and back up.
        path.move(to: CGPoint(x: left - shoulder, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: left, y: rect.minY + shoulder),
            control: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: rect.minY + collar - flare))
        path.addQuadCurve(
            to: CGPoint(x: left - flare, y: rect.minY + collar),
            control: CGPoint(x: left, y: rect.minY + collar))
        path.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.minY + collar))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + collar + topRadius),
            control: CGPoint(x: rect.minX, y: rect.minY + collar))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + collar + topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + collar),
            control: CGPoint(x: rect.maxX, y: rect.minY + collar))
        path.addLine(to: CGPoint(x: right + flare, y: rect.minY + collar))
        path.addQuadCurve(
            to: CGPoint(x: right, y: rect.minY + collar - flare),
            control: CGPoint(x: right, y: rect.minY + collar))
        path.addLine(to: CGPoint(x: right, y: rect.minY + shoulder))
        path.addQuadCurve(
            to: CGPoint(x: right + shoulder, y: rect.minY),
            control: CGPoint(x: right, y: rect.minY))
        path.closeSubpath()
        return path
    }

    /// One strip, full width from the top — the resting state and the flash.
    private func strip(in rect: CGRect, bottom: CGFloat, shoulder: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX - shoulder, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + shoulder),
            control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + shoulder))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX + shoulder, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
