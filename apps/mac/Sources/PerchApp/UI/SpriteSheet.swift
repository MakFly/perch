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
    func frame(at date: Date) -> CGImage {
        let tick = Int((date.timeIntervalSinceReferenceDate * Self.frameRate).rounded(.down))
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

    var body: some View {
        Group {
            if isPlaying {
                TimelineView(.periodic(from: .now, by: 1 / SpriteSheet.frameRate)) { context in
                    image(sheet.frame(at: context.date))
                }
            } else {
                image(sheet.frames[0]).opacity(0.55)
            }
        }
        .frame(width: side, height: side)
    }

    private func image(_ frame: CGImage) -> some View {
        Image(decorative: frame, scale: 1)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }
}
