import SwiftUI

/// Motion tokens, for the same reason `Theme` holds the colours: so the panel's movement
/// is one decision made in one place rather than a spring per view.
///
/// There is exactly one curve for geometry. The notch reads as a single shape stretching
/// only if its width, its height, its corner radii and the strip beside the cutout all
/// arrive together — the moment two of them run on different timings, it reads as a window
/// being resized with things sliding about inside it.
enum Motion {
    /// Every dimension of the panel. Nothing else may animate size or shape.
    ///
    /// Just short of critical damping: it settles hard, without the wobble that makes a
    /// notch look like a toy, but not so hard that it looks like a jump cut.
    static let morph: Animation = .spring(duration: 0.38, bounce: 0.14)

    /// Swapping one state's content for another's. Deliberately quicker than the morph,
    /// so the incoming content is already legible while the panel is still growing.
    static let content: Animation = .easeOut(duration: 0.16)

    /// Content enters from where the panel is coming from — the top edge, under the
    /// cutout — rather than fading in place.
    ///
    /// Asymmetric, because the two directions are not the same event. Arriving, the
    /// content has a panel to grow into and the small scale reads as it settling in.
    /// Leaving, the panel is collapsing *around* it: scaling on the way out as well made
    /// the content look sucked backwards through a hole, two motions fighting over a fifth
    /// of a second. On the way out it simply stops being there.
    @MainActor
    static let contentSwap: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
        removal: .opacity)
}
