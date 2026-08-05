import Foundation
import Testing

@testable import PerchKit

/// The plan, as it comes out of `ExitPlanMode`: headings, prose, a numbered list and a
/// diagram. Every regression these tests guard against was visible in this shape.
private let plan = """
    ## Décisions

    La clé n'est jamais validée par le schéma zod de `config.ts`.
    Un schéma fixe imposerait d'éditer un fichier par fournisseur.

    ### Architecture

    ```
    | models.dev/api.json |
    | hermes_cli/models.py | ──→ fusion
    ```

    Étapes

    1. Tables et migration — 0009_add_ai_catalog
    2. Port AiCatalogRepository
    """

@Test func aHeadingAndItsParagraphAreTwoBlocks() {
    // The bug the whole file exists for: `AttributedString(markdown:)` welded them into
    // "DécisionsLa clé n'est jamais validée…" because block boundaries never become
    // characters.
    let blocks = MarkdownBlock.parse(plan)

    #expect(blocks[0] == .heading(level: 2, text: "Décisions"))
    guard case .paragraph(let text) = blocks[1] else {
        Issue.record("expected a paragraph after the heading, got \(blocks[1])")
        return
    }
    #expect(text.hasPrefix("La clé n'est jamais validée"))
    // The newline inside the paragraph becomes a space, not nothing.
    #expect(text.contains("`config.ts`. Un schéma fixe"))
}

@Test func aFencedBlockKeepsItsLinesExactly() {
    let blocks = MarkdownBlock.parse(plan)
    let code = blocks.compactMap { block -> String? in
        if case .code(let text) = block { return text }
        return nil
    }

    #expect(code.count == 1)
    // Two lines, and no blank line inserted between them — the `\n` → `\n\n` hack this
    // replaces double-spaced every diagram it touched.
    #expect(code.first == "| models.dev/api.json |\n| hermes_cli/models.py | ──→ fusion")
}

@Test func numberedStepsAreAListAndNotProse() {
    let blocks = MarkdownBlock.parse(plan)

    #expect(blocks.contains(.paragraph("Étapes")))
    #expect(
        blocks.contains(
            .ordered(marker: "1.", depth: 0, text: "Tables et migration — 0009_add_ai_catalog")))
    #expect(blocks.contains(.ordered(marker: "2.", depth: 0, text: "Port AiCatalogRepository")))
}

@Test func anUnfencedDiagramIsNotFoldedIntoAParagraph() {
    // This project's own instructions ask for a diagram in every plan, and Claude does not
    // always fence it. Unfenced, every previous renderer turned it into one line of prose.
    let blocks = MarkdownBlock.parse(
        """
        Le flux :

        ┌──────────┐
        │ hook     │ ──→ notch
        └──────────┘

        Et ensuite le panneau décide.
        """)

    #expect(blocks.contains(.code("┌──────────┐\n│ hook     │ ──→ notch\n└──────────┘")))
    #expect(blocks.contains(.paragraph("Et ensuite le panneau décide.")))
}

@Test func aBlankLineInsideADiagramDoesNotSplitIt() {
    // Two boxes with a connector between them is one drawing, not three.
    let blocks = MarkdownBlock.parse(
        """
        | api.json |

              |
              v

        | models |
        """)

    let code = blocks.compactMap { block -> String? in
        if case .code(let text) = block { return text }
        return nil
    }
    #expect(code.count == 1)
    #expect(code.first?.components(separatedBy: "\n").count == 6)
}

@Test func aSingleDiagramLineStaysProse() {
    // One stray character in a sentence is not a drawing, and turning it into a code block
    // would be worse than the problem.
    let blocks = MarkdownBlock.parse("Le pipe | sépare les deux moitiés.")
    #expect(blocks == [.paragraph("Le pipe | sépare les deux moitiés.")])
}

@Test func anIndentedBlockIsCodeAndKeepsItsShape() {
    let blocks = MarkdownBlock.parse(
        """
        Voici :

            run()
              step()
        """)

    // The shared indentation goes, the relative one stays.
    #expect(blocks.last == .code("run()\n  step()"))
}

@Test func anIndentedLineUnderABulletBelongsToThatBullet() {
    let blocks = MarkdownBlock.parse(
        """
        - Le premier point
          qui continue ici
        - Le second
        """)

    #expect(blocks == [
        .bullet(depth: 0, text: "Le premier point qui continue ici"),
        .bullet(depth: 0, text: "Le second"),
    ])
}

@Test func nestedBulletsKeepTheirDepth() {
    let blocks = MarkdownBlock.parse(
        """
        - Racine
          - Enfant
        """)

    #expect(blocks == [.bullet(depth: 0, text: "Racine"), .bullet(depth: 1, text: "Enfant")])
}

@Test func anUnterminatedFenceStillShowsWhatIsInside() {
    // The normal state of a reply still being written.
    let blocks = MarkdownBlock.parse("Voici :\n\n```\nbun test\n")
    #expect(blocks.contains(.code("bun test")))
}

@Test func rulesAndQuotesAreTheirOwnBlocks() {
    let blocks = MarkdownBlock.parse("---\n> Attention ici\n")
    #expect(blocks == [.rule, .quote("Attention ici")])
}

@Test func planHeightGrowsWithThePlanAndStaysCapped() {
    let short = PlanApprovalRequest(plan: "## Titre\n\nUne ligne.")
    let long = PlanApprovalRequest(
        plan: (0..<200).map { "- Point numéro \($0) avec assez de texte pour envelopper." }
            .joined(separator: "\n"))

    let shortHeight = PlanCard.extraHeight(for: short, width: 660)
    let longHeight = PlanCard.extraHeight(for: long, width: 660)

    #expect(shortHeight < longHeight)
    // A short plan no longer opens half a screen of black under itself.
    #expect(shortHeight < 200)
    #expect(longHeight <= PlanCard.maxBodyHeight + 20)
}
