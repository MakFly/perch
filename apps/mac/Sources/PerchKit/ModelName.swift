import Foundation

/// Turning a model id into something a person reads.
///
/// Transcripts carry ids — `claude-opus-4-8`, `claude-haiku-4-5-20251001` — and a
/// leaderboard column is one of the places that difference shows: two spellings of the
/// same model rank as two models, and `claude-haiku-4-5-20251001` is four characters of
/// information in thirty.
///
/// This lives in `PerchKit` rather than next to a view because the *published* name goes
/// through it too. A board fed by several machines has to agree on what a model is called,
/// and agreeing at display time only works if everyone displays it the same way.
public enum ModelName {

    /// `claude-opus-4-8` → `Opus 4.8`. Anything unrecognised comes back unchanged, which
    /// is the right failure: an id nobody has taught this function about is still more
    /// useful on screen than a blank.
    public static func display(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return id }

        var parts = trimmed.lowercased().split(separator: "-").map(String.init)

        // A trailing release date is provenance, not identity.
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            parts.removeLast()
        }

        // `latest`, `preview` and friends say when you asked, not what answered.
        let noise: Set<String> = ["latest", "preview", "exp", "v1", "v2"]
        parts.removeAll { noise.contains($0) }

        guard let vendor = parts.first, Self.vendors.contains(vendor) else {
            return trimmed
        }
        parts.removeFirst()

        // Families and version numbers arrive in both orders across generations —
        // `3-5-sonnet` then `sonnet-5` — so they are separated by shape rather than by
        // position.
        let family = parts.filter { $0.contains(where: \.isLetter) }
        let version = parts.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }

        guard !family.isEmpty else { return trimmed }

        let name = family.map(capitalised).joined(separator: " ")
        return version.isEmpty ? name : "\(name) \(version.joined(separator: "."))"
    }

    /// Prefixes that mark an id as belonging to a vendor whose naming this understands.
    /// Anything else is left alone rather than mangled into a guess.
    private static let vendors: Set<String> = ["claude", "anthropic"]

    private static func capitalised(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }
}
