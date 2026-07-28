import AppKit
import SwiftUI

/// Design tokens for the notch UI.
///
/// The direction is the one the category has converged on and that reads well against a
/// physically black cutout: near-black surfaces, hairline white borders, monospaced text,
/// and one saturated accent per state. Colours are stated as hex so the palette is
/// auditable in one place rather than scattered through the views.
enum Theme {
    // MARK: - Surfaces

    static let surface = Color.black
    static let raised = Color(hex: 0x1A1A1A)
    static let hairline = Color.white.opacity(0.08)
    static let hairlineStrong = Color.white.opacity(0.14)

    // MARK: - Text

    static let primary = Color.white
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.38)

    // MARK: - Accents

    /// Working / succeeded.
    static let active = Color(hex: 0x4ADE80)
    /// Claude's own colour — used for anything permission-related.
    static let claude = Color(hex: 0xD97757)
    /// Informational: token counts, cache, rank.
    static let info = Color(hex: 0x60A5FA)
    static let warning = Color(hex: 0xF59E0B)
    static let danger = Color(hex: 0xEF4444)

    // MARK: - Type
    //
    // One typeface, everywhere. The content is commands, paths and numbers, and a fixed
    // advance keeps a live-updating token counter from shifting the layout on every tick —
    // but the reason it is *this* face rather than SF Mono is that a panel hanging off a
    // physical cutout reads as hardware, and a bitmap face reads that way where a humanist
    // one reads as a document. It is also the one thing that makes two lines of unrelated
    // content look like they belong to the same instrument.
    //
    // Departure Mono, by Helena Zhang, SIL Open Font License 1.1 — bundled under
    // `Resources/Fonts` and registered for this process alone.

    private static let family = "DepartureMono-Regular"

    /// False in a `swift run` build, which has no bundle to register the font from. The
    /// check is done once: `NSFont(name:)` misses are not cheap, and this is on the path
    /// of every label in a view that redraws on every hook event.
    private static let isBundled = NSFont(name: family, size: 12) != nil

    /// What `--diagnose` reports, so a bundle that failed to register its font says so.
    static var resolvedTypefaceName: String {
        isBundled ? family : "\(family) NOT REGISTERED — falling back to the system face"
    }

    /// How wide a run of monospaced text will actually be.
    ///
    /// The resting strip is a fixed-width window sized before it draws, so a guess at the
    /// advance is a guess at whether the last character is clipped by the edge it is meant
    /// to sit inside — which is how the session count lost a digit once already.
    static func monoWidth(_ text: String, size: CGFloat) -> CGFloat {
        let font =
            (isBundled ? NSFont(name: family, size: size) : nil)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard isBundled else { return .system(size: size, weight: weight, design: .monospaced) }
        // Departure Mono ships one weight. Emphasis has to come from colour and from the
        // pill backgrounds, which is how the panel was already built.
        return .custom(family, fixedSize: size)
    }

    /// Kept as a separate call site because the two are not interchangeable in intent —
    /// `mono` is for content, `label` is for chrome — even though they now resolve to the
    /// same face.
    static func label(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        guard isBundled else { return .system(size: size, weight: weight, design: .rounded) }
        return .custom(family, fixedSize: size)
    }

    /// Sentences, in a face built for sentences.
    ///
    /// Everything used to be Departure Mono, which is right for the things this panel was
    /// built around — commands, paths, token counts, a live-updating number whose fixed
    /// advance stops the layout shifting on every tick. It is wrong for a paragraph. A
    /// bitmap face at 9pt with a uniform advance gives a reply the texture of a terminal
    /// dump: even colour, no word shapes, nothing for the eye to land on. The panel read as
    /// output rather than as an answer, and that was the whole complaint.
    ///
    /// So prose gets the system face and the machine keeps the pixels. A code block inside
    /// a reply stays monospaced, because there it is doing the job it is for.
    static func prose(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    // MARK: - Metrics

    static let cornerRadius: CGFloat = 8
    static let rowSpacing: CGFloat = 8
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Compact number formatting — the notch has room for `1.2M`, not `1 203 481`.
extension Int {
    var compactTokens: String {
        switch self {
        case ..<1_000: return String(self)
        case ..<1_000_000:
            return String(format: "%.1fK", Double(self) / 1_000)
        case ..<1_000_000_000:
            return String(format: "%.1fM", Double(self) / 1_000_000)
        default:
            return String(format: "%.2fB", Double(self) / 1_000_000_000)
        }
    }
}

extension Double {
    /// Costs are shown to the cent above a dollar, and to a tenth of a cent below it —
    /// a run that cost $0.004 should not render as `$0.00`.
    var compactCost: String {
        if self >= 1 { return String(format: "$%.2f", self) }
        if self >= 0.01 { return String(format: "$%.2f", self) }
        return String(format: "$%.3f", self)
    }
}
