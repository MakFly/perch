import AppKit
import SwiftUI

/// A row of square frames, cut apart once and played.
///
/// The sheet carries its own metadata: N frames of side S laid out horizontally means the
/// image is `N·S × S`, so the count is `width / height` and there is no sidecar JSON to
/// fall out of sync with the PNG. Dropping a new sheet in `Resources/Sprites` is the whole
/// install — which is the property the optional-sprites design already had, and worth
/// keeping now that the sheets animate.
struct SpriteSheet {
    let frames: [CGImage]

    /// Generation-V sprites are authored at 100ms a frame, and every sheet here comes from
    /// that source. A rate per sheet would be one more thing to keep in step with the file.
    static let frameRate: Double = 10

    static func load(_ url: URL) -> SpriteSheet? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let side = sheet.height
        // A sheet whose width is not a whole number of frames is a sheet that would be
        // played with a sliver of the next frame in every one of them. Better to draw the
        // pixel art than to play that.
        guard side > 0, sheet.width >= side, sheet.width % side == 0 else { return nil }

        let frames = (0..<(sheet.width / side)).compactMap {
            sheet.cropping(to: CGRect(x: $0 * side, y: 0, width: side, height: side))
        }
        guard !frames.isEmpty else { return nil }
        return SpriteSheet(frames: frames)
    }

    /// Which frame belongs to a moment. Driven by the clock rather than by a counter, so
    /// two sprites on screen stay in step with each other and a dropped frame is a frame
    /// skipped rather than an animation running slow.
    func frame(at date: Date, tempo: Double = 1) -> CGImage {
        let rate = Self.frameRate * tempo
        let tick = Int((date.timeIntervalSinceReferenceDate * rate).rounded(.down))
        return frames[((tick % frames.count) + frames.count) % frames.count]
    }
}

/// A sheet, played — or held on its first frame when there is nothing to say.
///
/// `TimelineView` rather than a `Timer`: the redraw belongs to the view that is on screen,
/// so a sprite nobody is drawing costs nothing, and there is no timer to invalidate when
/// the panel closes.
struct AnimatedSprite: View {
    let sheet: SpriteSheet
    let side: CGFloat
    /// Playing only while that agent is actually doing something. A session that has
    /// stopped holds still and dims — a creature flapping its wings from the corner of the
    /// screen for a turn that ended an hour ago says the opposite of the truth.
    let isPlaying: Bool

    /// Working is a fight, and it should look like one.
    ///
    /// The sheet on its own is a battle *stance*: the creature breathes and its wings
    /// idle, which is right for "here" and understated for "this thing has been chewing
    /// on your repository for twenty minutes". So a working agent plays it half again as
    /// fast and hops — a short lunge off the floor, then the recovery.
    var isFighting = false

    /// Which agent this is in the row, which decides two things: when it hops, and which
    /// way it faces. Staggered, they take turns instead of jumping in unison; mirrored,
    /// the second one turns to face the first and the strip reads as a brawl rather than
    /// as a row of stickers.
    var beat: Int = 0

    /// A flame out of the mouth, for the one that has one.
    ///
    /// Drawn rather than animated from the sheet: the generation-V sprites are a battle
    /// *stance*, and no frame in any of them opens its jaw. This is ours — three tongues
    /// of colour on the same clock as everything else, leaving the muzzle where the sprite
    /// actually has one.
    var breath: Breath?

    struct Breath: Equatable {
        /// Where the flame leaves the creature, in unit coordinates of its own box. The
        /// sprite faces its own left, so this sits near x = 0 and the flame goes further
        /// left still — see `AgentGlyph.muzzleRoom`, which is what buys it that room.
        var muzzle: CGPoint
    }

    /// How far past the sprite's own box a flame reaches. The resting strip adds it to its
    /// width, once, when there is something on it that breathes.
    static let muzzleRoom: CGFloat = 9

    /// Half again as fast in a fight. Twice was tested and reads as a fast-forward rather
    /// than as effort.
    private var tempo: Double { isFighting ? 1.5 : 1 }

    var body: some View {
        Group {
            if isPlaying {
                TimelineView(
                    .periodic(from: .now, by: 1 / (SpriteSheet.frameRate * tempo))
                ) { context in
                    // Everything on this view comes off `context.date` rather than off an
                    // implicit animation: one clock, so the hop and the flame cannot drift
                    // out of step with the wings they belong to.
                    // The flame is attached before the hop, not after: `offset` moves what
                    // is drawn and not the frame an overlay is measured against, so the
                    // other order left the fire hanging in the air while the creature
                    // jumped out from under it.
                    image(sheet.frame(at: context.date, tempo: tempo))
                        .overlay(alignment: .trailing) {
                            flame(heat: heat(at: context.date))
                        }
                        .offset(y: -hop(at: context.date))
                }
            } else {
                image(sheet.frames[0]).opacity(0.55)
            }
        }
        .frame(width: side, height: side)
        // Odd ones face back down the row. Only in a fight — a lone sprite, or a resting
        // one, faces the way it was drawn.
        .scaleEffect(x: isFighting && facesForward ? 1 : -1)
    }

    /// Odd positions turn around. The one that breathes never does: it stands at the left
    /// of the row with the shoulder's own edge in front of it, and turning it round would
    /// point the flame at the cutout — the one rectangle on this screen that is not ours
    /// to draw in.
    private var facesForward: Bool { breath != nil || beat % 2 == 0 }

    /// Three tongues, brightest and shortest last, growing and retracting inside one
    /// breath. Drawn past the sprite's own box on the side it faces.
    @ViewBuilder
    private func flame(heat: CGFloat) -> some View {
        if let breath, heat > 0.01 {
            Canvas { context, size in
                let origin = CGPoint(
                    x: AnimatedSprite.muzzleRoom + breath.muzzle.x * side,
                    y: breath.muzzle.y * side)
                let reach = heat * (origin.x + side * 0.1)
                let spread = side * 0.16

                // Red at the edge, amber under it, a near-white core — the order a flame
                // actually has, and the order the sprite's own tail is drawn in.
                let tongues: [(CGFloat, CGFloat, Color)] = [
                    (1, 1, Theme.danger.opacity(0.92)),
                    (0.66, 0.6, Theme.warning),
                    (0.3, 0.26, Color(red: 1, green: 0.96, blue: 0.78)),
                ]
                for (length, width, colour) in tongues {
                    var path = Path()
                    let tip = CGPoint(x: origin.x - reach * length, y: origin.y)
                    let waist = origin.x - reach * length * 0.45
                    path.move(to: CGPoint(x: origin.x, y: origin.y - spread * width / 2))
                    path.addQuadCurve(
                        to: tip, control: CGPoint(x: waist, y: origin.y - spread * width))
                    path.addQuadCurve(
                        to: CGPoint(x: origin.x, y: origin.y + spread * width / 2),
                        control: CGPoint(x: waist, y: origin.y + spread * width))
                    path.closeSubpath()
                    context.fill(path, with: .color(colour))
                }
            }
            .frame(width: side + AnimatedSprite.muzzleRoom, height: side)
            .allowsHitTesting(false)
        }
    }

    /// How much flame there is at a moment: nothing for most of the cycle, then one breath
    /// that grows and dies. It starts after the hop has landed, so the two read as a
    /// sequence — leap, land, burn — rather than as one busy thing.
    private func heat(at date: Date) -> CGFloat {
        guard isFighting, breath != nil else { return 0 }
        let turn = date.timeIntervalSinceReferenceDate / 1.3 + Double(beat) * 0.37
        let phase = turn - turn.rounded(.down)
        guard phase > 0.34, phase < 0.72 else { return 0 }
        let within = (phase - 0.34) / 0.38
        // Out fast, back slowly. A flame that fades symmetrically reads as a light being
        // dimmed rather than as something being exhaled.
        return CGFloat(within < 0.3 ? within / 0.3 : 1 - (within - 0.3) / 0.7)
    }

    /// A short lunge off the floor, on this sprite's own beat.
    private func hop(at date: Date) -> CGFloat {
        guard isFighting else { return 0 }
        let cycle = 1.3
        let turn = date.timeIntervalSinceReferenceDate / cycle + Double(beat) * 0.37
        let phase = turn - turn.rounded(.down)
        // Airborne for a fifth of the cycle. Any longer and it floats; any shorter and at
        // fifteen frames a second there are not enough samples left to see it leave.
        guard phase < 0.2 else { return 0 }
        return CGFloat(sin(phase / 0.2 * .pi)) * side * 0.12
    }

    private func image(_ frame: CGImage) -> some View {
        Image(decorative: frame, scale: 1)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }
}
