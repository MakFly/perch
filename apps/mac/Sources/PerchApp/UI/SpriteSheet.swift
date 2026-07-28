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

    /// Half again as fast in a fight. Twice was tested and reads as a fast-forward rather
    /// than as effort.
    private var tempo: Double { isFighting ? 1.5 : 1 }

    var body: some View {
        Group {
            if isPlaying {
                TimelineView(
                    .periodic(from: .now, by: 1 / (SpriteSheet.frameRate * tempo))
                ) { context in
                    image(sheet.frame(at: context.date, tempo: tempo))
                        // Driven off the same date as the frame rather than by an
                        // implicit animation: one clock, so the hop cannot drift out of
                        // step with the wings it belongs to.
                        .offset(y: -hop(at: context.date))
                }
            } else {
                image(sheet.frames[0]).opacity(0.55)
            }
        }
        .frame(width: side, height: side)
        // Odd ones face back down the row. Only in a fight — a lone sprite, or a resting
        // one, faces the way it was drawn.
        .scaleEffect(x: isFighting && beat % 2 == 1 ? -1 : 1)
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
