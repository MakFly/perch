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
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text(isFinished ? t("Done") : t("Writing…"))
                        .font(Theme.mono(9))
                        .foregroundStyle(isFinished ? Theme.tertiary : Theme.active)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Theme.hairline.opacity(0.5))
            }

            if !turn.reply.isEmpty {
                // Clipped, not scrolled. A scroll view inside a card inside a panel that
                // scrolls takes the wheel away from the panel the moment the cursor is over
                // a reply — and the panel is the thing being scrolled. The bounded height
                // and the fade say "there is more" without competing for the gesture; the
                // card is one click from the terminal that has all of it.
                MarkdownText(turn.reply)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxHeight: 132, alignment: .top)
                    .clipped()
                // A reply that fills the box has to look like it continues, or a cut-off
                // sentence reads as the agent having stopped mid-word.
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.88),
                            .init(color: .black.opacity(0.15), location: 1),
                        ], startPoint: .top, endPoint: .bottom))
            }
        }
        .background(Theme.surface.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 1))
    }
}

/// Just enough markdown to read an agent's reply.
///
/// Headings, fenced code, list items and inline code — which is most of what a coding agent
/// writes and all of what is legible at 9pt in a panel. Rendered line by line rather than
/// with `AttributedString(markdown:)` so a fenced block keeps its monospace and its
/// background: the built-in parser drops fences entirely, which turns a shell command into
/// prose and loses the one thing you were looking for.
struct MarkdownText: View {
    private let blocks: [Block]

    init(_ text: String) {
        self.blocks = MarkdownText.parse(text)
    }

    enum Block: Identifiable {
        case heading(String)
        case code(String)
        case bullet(String)
        case paragraph(String)

        var id: String {
            switch self {
            case .heading(let s): return "h\(s)"
            case .code(let s): return "c\(s)"
            case .bullet(let s): return "b\(s)"
            case .paragraph(let s): return "p\(s)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(text)
                        .font(Theme.label(10, .semibold))
                        .foregroundStyle(Theme.primary)
                case .code(let text):
                    Text(text)
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.info)
                        .textSelection(.enabled)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 4).fill(Theme.hairline.opacity(0.6)))
                case .bullet(let text):
                    HStack(alignment: .top, spacing: 5) {
                        Text("•").font(Theme.mono(9)).foregroundStyle(Theme.tertiary)
                        inline(text)
                    }
                case .paragraph(let text):
                    inline(text)
                }
            }
        }
    }

    /// `**bold**`, `` `code` `` and the rest, through the system parser — which handles
    /// inline spans well and only falls down on block structure, done above.
    private func inline(_ text: String) -> some View {
        Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
            .font(Theme.mono(9))
            .foregroundStyle(Theme.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String] = []
        var inFence = false

        func flushParagraph() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inFence {
                    blocks.append(.code(code.joined(separator: "\n")))
                    code = []
                } else {
                    flushParagraph()
                }
                inFence.toggle()
                continue
            }
            if inFence {
                code.append(line)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if trimmed.hasPrefix("#") {
                flushParagraph()
                blocks.append(
                    .heading(
                        trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
                continue
            }
            paragraph.append(trimmed)
        }

        // An unterminated fence is the normal state of a reply being written, not a
        // malformed document — what is inside it still shows.
        if !code.isEmpty { blocks.append(.code(code.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }
}
