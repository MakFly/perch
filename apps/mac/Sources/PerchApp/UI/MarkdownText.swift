import PerchKit
import SwiftUI

/// Markdown, drawn one block at a time.
///
/// The structure comes from `MarkdownBlock.parse` — see the note there for why the system
/// parser cannot be used for it — and each block is laid out as its own view. That is the
/// whole reason a heading sits above its paragraph instead of inside it.
///
/// Two densities, because the same renderer now serves two very different jobs: a clipped
/// preview of a reply on a session card, and a plan the user is about to approve. The plan
/// is the longest thing Perch shows and the one with the most consequence behind the
/// button, so it gets the larger type, the brighter ink and the air between blocks.
struct MarkdownText: View {
    enum Density {
        /// The transcript preview: small, tight, secondary. Unchanged from what it was.
        case compact
        /// The plan card: sized to be read rather than skimmed.
        case reading
    }

    private let blocks: [MarkdownBlock]
    private let density: Density
    /// Points available for content, when the caller knows it. Only code blocks need it —
    /// they are the one thing here that is never wrapped, so they are the one thing that
    /// has to be measured against the panel it is drawn in.
    private let width: CGFloat?

    init(_ text: String, density: Density = .compact, width: CGFloat? = nil) {
        self.blocks = MarkdownBlock.parse(text)
        self.density = density
        self.width = width
    }

    var body: some View {
        // Spacing is per block rather than uniform on the stack: a heading needs air above
        // it and none below, and two items of one list need less than two paragraphs.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block)
                    .padding(.top, index == 0 ? 0 : spacing(before: index))
            }
        }
    }

    // MARK: - Metrics

    private var proseSize: CGFloat { density == .reading ? 11.5 : 10.5 }
    private var proseColor: Color {
        density == .reading ? Theme.primary.opacity(0.86) : Theme.secondary
    }
    private var lineSpacing: CGFloat { density == .reading ? 3 : 1.5 }
    private var blockSpacing: CGFloat { density == .reading ? 10 : 6 }
    private var codeSize: CGFloat { density == .reading ? 11 : 9 }

    private func isListItem(_ block: MarkdownBlock) -> Bool {
        if case .bullet = block { return true }
        if case .ordered = block { return true }
        return false
    }

    private func spacing(before index: Int) -> CGFloat {
        let block = blocks[index]
        let previous = blocks[index - 1]

        // A heading belongs to what follows it, so the gap goes above.
        if case .heading = block { return blockSpacing + (density == .reading ? 6 : 2) }
        // A list reads as one thing when its items are closer to each other than to the
        // paragraph around them.
        if isListItem(block) && isListItem(previous) { return density == .reading ? 4 : 3 }
        if case .heading = previous { return density == .reading ? 5 : 4 }
        return blockSpacing
    }

    // MARK: - Blocks

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            heading(level: level, text: text)

        case .paragraph(let text):
            inline(text)

        case .bullet(let depth, let text):
            HStack(alignment: .top, spacing: 6) {
                Text(depth == 0 ? "•" : "◦")
                    .font(Theme.prose(proseSize - 0.5))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 8, alignment: .center)
                inline(text)
            }
            .padding(.leading, CGFloat(depth) * 14)

        case .ordered(let marker, let depth, let text):
            HStack(alignment: .top, spacing: 6) {
                // Mono, so `9.` and `10.` do not shift the text beside them, and right
                // aligned so the numbers line up rather than the dots.
                Text(marker)
                    .font(Theme.mono(proseSize - 1.5))
                    .foregroundStyle(Theme.tertiary)
                    .frame(minWidth: 16, alignment: .trailing)
                inline(text)
            }
            .padding(.leading, CGFloat(depth) * 14)

        case .code(let text):
            CodeBlock(
                text: text, baseSize: codeSize,
                // Low, on purpose. Small type you can see the shape of beats a scroll bar
                // under a diagram, and at 7.5pt a 660pt panel still holds ~145 columns —
                // wider than anything an agent actually draws. Scrolling is the exception
                // this floor exists to make rare.
                minSize: density == .reading ? 7.5 : 8,
                available: width, scrolls: density == .reading)

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(Theme.hairlineStrong).frame(width: 2)
                inline(text)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .rule:
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func heading(level: Int, text: String) -> some View {
        // In the plan the top two levels are the spine of the document, and a rule under
        // them is what makes a section look like a section rather than a bold sentence.
        let size: CGFloat =
            density == .reading ? (level <= 1 ? 13.5 : level == 2 ? 12.5 : 11.5) : 11

        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(Theme.prose(size, .semibold))
                .foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
            if density == .reading && level <= 2 {
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
        }
    }

    /// `**bold**`, `` `code` `` and the rest, through the system parser — which handles
    /// inline spans well and only falls down on block structure, done in `MarkdownBlock`.
    private func inline(_ text: String) -> some View {
        Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
            .font(Theme.prose(proseSize))
            .foregroundStyle(proseColor)
            .lineSpacing(lineSpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A code block, or a diagram — the same thing as far as drawing goes.
///
/// The one rule is that it is never wrapped. A diagram is drawn in the vertical alignment
/// of its lines and folding one of them at the panel's edge does not shorten it, it makes
/// it wrong. So the type shrinks until the widest line fits, and if it still does not, the
/// block scrolls sideways rather than reflows.
private struct CodeBlock: View {
    let text: String
    let baseSize: CGFloat
    /// How small the type may go before scrolling is the better answer.
    let minSize: CGFloat
    let available: CGFloat?
    let scrolls: Bool

    /// One measurement, not a search: the face is monospaced, so width is linear in the
    /// character count and the longest line decides for all of them.
    private var fitted: (size: CGFloat, fits: Bool) {
        let longest = text.components(separatedBy: "\n").max(by: { $0.count < $1.count }) ?? ""
        guard let available, available > 0, !longest.isEmpty else { return (baseSize, true) }

        // 12pt of padding inside the box.
        let room = available - 12
        let measured = Theme.monoWidth(longest, size: baseSize)
        guard measured > room else { return (baseSize, true) }

        // Half-point steps: whole points jump from 11 to 10 and lose more than the fit is
        // worth on a block that only overruns by a character.
        let scaled = (baseSize * room / measured * 2).rounded(.down) / 2
        return scaled >= minSize ? (scaled, true) : (minSize, false)
    }

    var body: some View {
        let (size, fits) = fitted
        let content = Text(text)
            .font(Theme.mono(size))
            .foregroundStyle(Theme.primary.opacity(0.9))
            .textSelection(.enabled)
            // The whole point: ideal width, no wrapping, whatever that costs.
            .fixedSize(horizontal: true, vertical: true)

        Group {
            if fits {
                content.frame(maxWidth: .infinity, alignment: .leading)
            } else if scrolls {
                // `fixedSize` vertically or the scroll view takes every point the stack
                // will give it: a horizontal scroll view has no intrinsic height, so
                // without this the block draws as an empty band and the diagram is gone.
                ScrollView(.horizontal, showsIndicators: true) { content }
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // The transcript is already a clipped preview with a fade under it, and a
                // second scroll view inside it would take the wheel from the panel that is
                // the thing being scrolled.
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.raised.opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
