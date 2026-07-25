import SwiftUI

/// The notch silhouette: square at the top where it meets the bezel, rounded below,
/// with a small inverse curve on each shoulder so it reads as part of the cutout
/// rather than a rectangle stuck under it.
struct NotchShape: Shape {
    var bottomRadius: CGFloat = 14
    var shoulderRadius: CGFloat = 7

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, shoulderRadius) }
        set {
            bottomRadius = newValue.first
            shoulderRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let bottom = min(bottomRadius, rect.height / 2, rect.width / 2)
        let shoulder = min(shoulderRadius, rect.height / 2)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX - shoulder, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + shoulder),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + shoulder))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX + shoulder, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
