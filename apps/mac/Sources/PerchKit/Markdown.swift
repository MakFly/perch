import Foundation

/// Markdown, split into the blocks a panel can draw.
///
/// Not a Markdown implementation — a structural one. `AttributedString(markdown:)` parses
/// the syntax correctly and then throws away the only thing this panel needs: block
/// boundaries live in `presentationIntent` attributes and never become characters, so
/// `Text` draws a heading and the paragraph under it as one run — "DécisionsLa clé n'est
/// jamais validée". Every newline inside a paragraph disappears the same way, without even
/// a space where it was. A plan rendered that way is a wall, and a wall is what gets
/// approved unread.
///
/// So the document is cut into blocks here, line by line, and each block is drawn as its
/// own view. Everything below the block level — `**bold**`, `` `code` `` — still goes
/// through the system parser, which is good at exactly that.
public enum MarkdownBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(depth: Int, text: String)
    /// The marker is kept as written (`1.`, `2)`) rather than renumbered: a plan that
    /// starts its steps at 3 means 3.
    case ordered(marker: String, depth: Int, text: String)
    /// Verbatim. Fenced, indented, or recognised as a diagram — all three want the same
    /// thing, which is to be left alone.
    case code(String)
    case quote(String)
    case rule
}

extension MarkdownBlock {
    /// Characters that only appear on purpose.
    ///
    /// A line carrying one of these is a drawing, not a sentence, and the difference
    /// between the two is whether its line breaks and its spacing survive.
    private static let boxDrawing: Set<Character> = [
        "│", "─", "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼", "╌", "╎",
        "║", "═", "╔", "╗", "╚", "╝", "╠", "╣", "╦", "╩", "╬",
        "▼", "▲", "◀", "▶", "▸", "▾", "↓", "↑", "⟶",
    ]

    /// Does this line belong to a diagram?
    ///
    /// Claude Code plans carry ASCII diagrams — this project's own instructions require one
    /// in every plan — and they are not always fenced. Unfenced, every previous renderer
    /// folded them into a paragraph, which is the one transformation that destroys them
    /// completely.
    ///
    /// Deliberately narrow, because a false positive turns a sentence into a code block:
    /// box-drawing characters, a row of pipes (which also catches a Markdown table, and a
    /// table shown verbatim in mono is a table you can still read), or an ASCII border.
    static func looksLikeDiagram(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains(where: { boxDrawing.contains($0) }) { return true }
        if trimmed.filter({ $0 == "|" }).count >= 2 { return true }
        // `+------+`, `+--+--+` — a border drawn out of ASCII.
        if trimmed.contains("+-") && trimmed.allSatisfy({ "+-= ".contains($0) }) { return true }
        return false
    }

    /// Looser, and only used once a diagram is already open: the connectors *between* two
    /// boxes are a lone pipe or caret on an otherwise empty line, which nothing above would
    /// recognise on its own.
    private static func continuesDiagram(_ line: String) -> Bool {
        if looksLikeDiagram(line) { return true }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { "|+^v<>/\\-_ ".contains($0) }
    }

    private static func isRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        return trimmed.allSatisfy { $0 == "-" } || trimmed.allSatisfy { $0 == "_" }
            || trimmed.allSatisfy { $0 == "*" }
    }

    /// `1.` / `2)` and what follows, or nil.
    private static func orderedMarker(_ trimmed: String) -> (marker: String, rest: String)? {
        let digits = trimmed.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let after = trimmed.dropFirst(digits.count)
        guard let punctuation = after.first, punctuation == "." || punctuation == ")" else {
            return nil
        }
        let rest = after.dropFirst()
        guard rest.first == " " else { return nil }
        return (
            String(digits) + String(punctuation),
            String(rest).trimmingCharacters(in: .whitespaces)
        )
    }

    /// Two spaces to a level, capped: past the third the indent costs more width than the
    /// nesting is worth in a panel this narrow.
    private static func depth(of line: String) -> Int {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
            .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        return min(3, indent / 2)
    }

    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var fenced: [String] = []
        var verbatim: [String] = []
        /// Blank lines held back inside a diagram — a gap between two boxes is part of the
        /// drawing, but a gap after the last one is just the end of it.
        var heldBlanks = 0
        /// What opened the verbatim run, because the two end differently: an indented block
        /// runs until the indentation stops, a diagram until the drawing does.
        var verbatimIsIndented = false
        var inFence = false
        /// Whether the last thing emitted can absorb an indented continuation line.
        var lastWasListItem = false

        func flushParagraph() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty {
                blocks.append(.paragraph(joined))
                lastWasListItem = false
            }
            paragraph = []
        }

        func flushVerbatim() {
            defer {
                verbatim = []
                heldBlanks = 0
                verbatimIsIndented = false
            }
            guard !verbatim.isEmpty else { return }
            // One line is a stray character in a sentence more often than it is a drawing.
            if verbatim.count == 1 {
                paragraph.append(verbatim[0].trimmingCharacters(in: .whitespaces))
                return
            }
            blocks.append(.code(trimIndent(verbatim)))
            lastWasListItem = false
        }

        func flushAll() {
            flushVerbatim()
            flushParagraph()
        }

        /// A continuation line under a list item belongs to that item — appending it as its
        /// own paragraph is how one bullet becomes two.
        func appendToLastItem(_ text: String) -> Bool {
            guard lastWasListItem, let last = blocks.last else { return false }
            switch last {
            case .bullet(let depth, let existing):
                blocks[blocks.count - 1] = .bullet(depth: depth, text: existing + " " + text)
                return true
            case .ordered(let marker, let depth, let existing):
                blocks[blocks.count - 1] = .ordered(
                    marker: marker, depth: depth, text: existing + " " + text)
                return true
            default:
                return false
            }
        }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " || $0 == "\t" }
                .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if inFence {
                    blocks.append(.code(trimIndent(fenced)))
                    lastWasListItem = false
                    fenced = []
                } else {
                    flushAll()
                }
                inFence.toggle()
                continue
            }
            if inFence {
                fenced.append(line)
                continue
            }

            if trimmed.isEmpty {
                // Inside a diagram, hold the blank rather than end the block on it.
                if !verbatim.isEmpty {
                    heldBlanks += 1
                } else {
                    flushParagraph()
                }
                continue
            }

            if !verbatim.isEmpty {
                if continuesDiagram(line) || (verbatimIsIndented && indent >= 4) {
                    for _ in 0..<heldBlanks { verbatim.append("") }
                    heldBlanks = 0
                    verbatim.append(line)
                    continue
                }
                flushVerbatim()
            }

            if trimmed.hasPrefix("#") {
                flushAll()
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                let title = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                // `#hashtag` is not a heading, and a bare row of hashes is a rule.
                if title.isEmpty {
                    blocks.append(.rule)
                } else {
                    blocks.append(.heading(level: min(4, hashes), text: title))
                }
                lastWasListItem = false
                continue
            }

            if isRule(trimmed) {
                flushAll()
                blocks.append(.rule)
                lastWasListItem = false
                continue
            }

            if let marker = ["- ", "* ", "• ", "+ "].first(where: { trimmed.hasPrefix($0) }) {
                flushParagraph()
                blocks.append(
                    .bullet(depth: depth(of: line), text: String(trimmed.dropFirst(marker.count))))
                lastWasListItem = true
                continue
            }

            if let (marker, rest) = orderedMarker(trimmed) {
                flushParagraph()
                blocks.append(.ordered(marker: marker, depth: depth(of: line), text: rest))
                lastWasListItem = true
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(
                    .quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                lastWasListItem = false
                continue
            }

            // Indented: code, unless it is the second line of the list item above it.
            if indent >= 4 && paragraph.isEmpty {
                if appendToLastItem(trimmed) { continue }
                verbatim.append(line)
                verbatimIsIndented = true
                continue
            }

            if looksLikeDiagram(line) {
                flushParagraph()
                verbatim.append(line)
                verbatimIsIndented = false
                continue
            }

            if paragraph.isEmpty && appendToLastItem(trimmed) { continue }
            paragraph.append(trimmed)
            lastWasListItem = false
        }

        // An unterminated fence is the normal state of a reply still being written, not a
        // malformed document — what is inside it still shows.
        if !fenced.isEmpty { blocks.append(.code(trimIndent(fenced))) }
        flushAll()
        return blocks
    }

    /// Drops the indentation every line shares, so a diagram written four spaces in does
    /// not start four spaces from the edge of a panel that has none to spare. Relative
    /// indentation — the whole content of a drawing — is untouched.
    private static func trimIndent(_ lines: [String]) -> String {
        let common = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " }.count }
            .min() ?? 0
        let trimmed = lines.map { String($0.dropFirst(min(common, $0.count))) }
        return trimmed.drop(while: { $0.isEmpty }).reversed()
            .drop(while: { $0.isEmpty }).reversed()
            .joined(separator: "\n")
    }
}

/// How tall the plan card wants to be, so the panel can be that tall before it draws.
///
/// Same contract as `QuestionCard`, and for the same reason: the window is a fixed canvas
/// and only the panel inside it animates, so the size has to be known one step ahead of
/// SwiftUI. It was a flat 430 — right for a long plan, and half a screen of black under a
/// five-line one.
///
/// An estimate, and meant to be. Past `maxBodyHeight` the body scrolls, and a few points
/// either way cost some air at the bottom of the card rather than a lost button.
public enum PlanCard {
    /// The tallest the scrolling body may get. Shared with the view so the two cannot
    /// drift — the panel is sized against this and the `ScrollView` is capped at it.
    public static let maxBodyHeight: CGFloat = 440

    /// Header, feedback field and buttons sit outside the body; the alert panel's base
    /// height already covers most of them.
    private static let chrome: CGFloat = 10

    /// Rows a run of text takes at `size` in `width` points.
    ///
    /// Prose is proportional and averages narrower than the 0.6em `QuestionCard` assumes
    /// for monospace, so it gets its own factor. Over-estimating is the safe direction.
    private static func rows(_ text: String, size: CGFloat, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 1 }
        let perLine = max(1, (width / (size * 0.52)).rounded(.down))
        return max(1, (CGFloat(text.count) / perLine).rounded(.up))
    }

    public static func bodyHeight(for request: PlanApprovalRequest, width: CGFloat) -> CGFloat {
        // 14pt of card padding either side, 4pt of gutter for the scrollbar.
        let textWidth = max(160, width - 32)
        var height: CGFloat = 0

        for block in MarkdownBlock.parse(request.plan) {
            // Every block carries the spacing above it.
            height += 10
            switch block {
            case .heading(let level, let text):
                height += rows(text, size: level <= 2 ? 13 : 12, width: textWidth) * 18
                if level <= 2 { height += 8 }
            case .paragraph(let text):
                height += rows(text, size: 11.5, width: textWidth) * 16
            case .bullet(let depth, let text), .ordered(_, let depth, let text):
                height +=
                    rows(text, size: 11.5, width: textWidth - CGFloat(depth) * 14 - 16) * 16
            case .quote(let text):
                height += rows(text, size: 11.5, width: textWidth - 12) * 16
            case .code(let text):
                // Never wrapped — see `CodeBlock`. So it is exactly its own line count,
                // plus the box around it.
                height += CGFloat(text.components(separatedBy: "\n").count) * 14 + 14
            case .rule:
                height += 6
            }
        }
        return height
    }

    public static func extraHeight(for request: PlanApprovalRequest, width: CGFloat) -> CGFloat {
        min(bodyHeight(for: request, width: width), maxBodyHeight) + chrome
    }
}
