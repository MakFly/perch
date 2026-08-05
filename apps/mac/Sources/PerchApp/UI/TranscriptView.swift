import PerchKit
import SwiftUI

/// The conversation, on the card.
///
/// The panel answered "what is it doing" and never "what did it say" — so the answer was
/// always one context switch away, in the terminal, which is the switch the notch exists to
/// avoid. This shows the last exchange: what was asked, and the prose that came back.
///
/// Bounded on purpose. A reply runs to pages and the panel hangs off a cutout, so it gets a
/// fixed height and fades out at the bottom rather than pushing every other session off
/// screen.
struct TranscriptView: View {
    let turn: TranscriptTurn
    /// The prompt the hook carried, used when the reading window opened mid-turn and the
    /// question itself is further back in the file than we read.
    var fallbackPrompt: String?
    /// Said out loud, because "the agent stopped" and "the agent is still writing" look
    /// identical when all you can see is text that is not moving.
    var isFinished: Bool

    private var prompt: String? {
        let prompt = turn.prompt ?? fallbackPrompt
        return (prompt?.isEmpty == false) ? prompt : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let prompt {
                HStack(alignment: .top, spacing: 6) {
                    Text(t("You:"))
                        .font(Theme.mono(9, .semibold))
                        .foregroundStyle(Theme.tertiary)
                    Text(prompt)
                        .font(Theme.prose(11))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    // Only while it is being written. `Done` beside a row whose own line
                    // already says "Waiting for you" is the same fact twice, and it was
                    // the pair of them that read as a contradiction.
                    if !isFinished {
                        Text(t("Writing…"))
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.active)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Theme.hairline.opacity(0.5))
            }

            if !turn.reply.isEmpty {
                // Clipped, not scrolled. A scroll view inside a card inside a panel that
                // scrolls takes the wheel away from the panel the moment the cursor is over
                // a reply — and the panel is the thing being scrolled. The bounded height
                // and the fade say "there is more" without competing for the gesture; the
                // card is one click from the terminal that has all of it.
                MarkdownText(turn.reply)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxHeight: 132, alignment: .top)
                    .clipped()
                // A reply that fills the box has to look like it continues, or a cut-off
                // sentence reads as the agent having stopped mid-word.
                // The fade starts well before the cut. At 0.88 the last line was still
                // nearly opaque where it was sliced through, which reads as a drawing bug
                // rather than as more text below it.
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.70),
                            .init(color: .black.opacity(0.05), location: 1),
                        ], startPoint: .top, endPoint: .bottom))
            }
        }
        .background(Theme.surface.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 1))
    }
}

// The renderer moved to `MarkdownText.swift` — it draws the plan card too now, and the
// parsing behind it moved to `PerchKit/Markdown.swift` where it can be tested.
