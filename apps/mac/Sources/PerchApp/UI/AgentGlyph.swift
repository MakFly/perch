import PerchKit
import SwiftUI

/// A creature per agent, in that agent's colours, breathing while it works.
///
/// Drawn as an 8×8 grid rather than as vendor artwork: the notch is 32pt tall, a real logo
/// at that size is mush, and a mark made of literal pixels stays crisp at any backing scale
/// because every edge lands on a device pixel.
///
/// The three are starters — a fire lizard, a shelled swimmer, a seed-carrier — because a
/// row of creatures reads as "my agents" in a way three abstract marks never did, and
/// because at 16pt the silhouette is what identifies them. They are drawn here, from
/// nothing: the shapes evoke the archetypes, the pixels are ours, and nothing in this file
/// came from anyone's asset. That matters for something that will be distributed.
///
/// Two tones each, and a different silhouette per agent, so two of them side by side are
/// told apart by shape and not only by colour — which matters for anyone who cannot rely
/// on the colour.
struct AgentGlyph: View {
    let agent: Agent
    /// Side of one square. 2pt in the notch strip (16pt of sprite in a 32pt bar), 1.5 on a
    /// card where it sits beside 10pt text rather than alone.
    var pixel: CGFloat = 2
    /// Off for a session that is not working: a card that has stopped should not keep
    /// pulsing at you from the corner of the screen.
    var isBreathing = true

    @State private var phase = false

    /// `x` is the body, `o` the accent, `.` is nothing. Eyes are holes rather than a third
    /// colour — at eight pixels across, a gap reads as an eye and a dark square reads as
    /// dirt.
    private var art: (rows: [String], body: Color, accent: Color) {
        switch agent {
        // Fire: heavy head facing left, tail sweeping down-right into a flame. Eight
        // pixels across was not enough for the tail to read as a tail — the flame looked
        // like something the creature was holding — so all three are drawn on ten.
        case .claude:
            return (
                [
                    "..xxx.....",
                    ".xx.xx....",
                    ".xxxxx...o",
                    ".xxxxxx.oo",
                    "..xxxxxoo.",
                    "..xxxxx...",
                    "..xxxxx...",
                    ".xx..xx...",
                    ".x....x...",
                    "..........",
                ], Theme.claude, Theme.warning
            )
        // Water: rounded head over a banded shell, the band carrying the accent.
        case .codex:
            return (
                [
                    "...xxx....",
                    "..xx.xx...",
                    "..xxxxx...",
                    ".ooooooo..",
                    "oxxxxxxxo.",
                    "oxxxxxxxo.",
                    ".ooooooo..",
                    "..xx.xx...",
                    "..x...x...",
                    "..........",
                ], Theme.info, Theme.primary.opacity(0.75)
            )
        // Grass: a bulb riding on the back, head low and forward.
        case .gemini:
            return (
                [
                    "....ooo...",
                    "...ooooo..",
                    "..xxxxxx..",
                    ".xxxxxxxx.",
                    "xx.xxxxxx.",
                    "xxxxxxxxx.",
                    ".xxxxxxx..",
                    ".xx...xx..",
                    ".x.....x..",
                    "..........",
                ], Theme.active, Theme.warning
            )
        // Anything Perch has not met. Deliberately not a creature: an unrecognised agent
        // should look unrecognised rather than borrow one of the three identities.
        case .unknown:
            return (
                [
                    "..........",
                    "..xxxxxx..",
                    "..x....x..",
                    "..x....x..",
                    "..x....x..",
                    "..x....x..",
                    "..x....x..",
                    "..xxxxxx..",
                    "..........",
                    "..........",
                ], Theme.secondary, Theme.secondary
            )
        }
    }

    /// The bundled sprite for this agent, if one shipped.
    ///
    /// Loaded per agent and cached for the process: a glyph is drawn once per session card
    /// per redraw, and reading a PNG off disk on that path would be absurd.
    private static var sprites: [Agent: NSImage] = [:]

    private static func sprite(for agent: Agent) -> NSImage? {
        if let cached = sprites[agent] { return cached }
        let names: [Agent: String] = [
            .claude: "agent-claude", .codex: "agent-codex", .gemini: "agent-gemini",
        ]
        guard let name = names[agent],
            let url = Bundle.main.url(
                forResource: name, withExtension: "png", subdirectory: "Sprites"),
            let image = NSImage(contentsOf: url)
        else { return nil }
        sprites[agent] = image
        return image
    }

    /// The box a glyph occupies, whichever way it is drawn — ten pixels of the grid, or
    /// the sprite scaled to the same square, so a row of them lines up either way.
    private var side: CGFloat { pixel * 10 }

    var body: some View {
        Group {
            if let sprite = Self.sprite(for: agent) {
                Image(nsImage: sprite)
                    .resizable()
                    .scaledToFit()
                    .frame(width: side, height: side)
            } else {
                drawn
            }
        }
        .opacity(isBreathing && phase ? 0.5 : 1)
        .animation(
            isBreathing
                ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                : .default,
            value: phase
        )
        .onAppear { phase = true }
        .help(agent.displayName)
    }

    /// The original, drawn here from nothing — and what you get back the moment the
    /// `Sprites` directory is not in the bundle. Kept deliberately: it owes nobody
    /// anything, which is the property that matters for something shipped to other people.
    private var drawn: some View {
        let art = self.art
        return VStack(spacing: 0) {
            ForEach(Array(art.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Rectangle()
                            .fill(colour(cell, art: art))
                            .frame(width: pixel, height: pixel)
                    }
                }
            }
        }
    }

    private func colour(_ cell: Character, art: (rows: [String], body: Color, accent: Color))
        -> Color
    {
        switch cell {
        case "x": return art.body
        case "o": return art.accent
        default: return .clear
        }
    }
}
