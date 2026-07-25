import Foundation

/// Localised strings.
///
/// Perch's bundle is assembled by hand rather than by Xcode, so the `.lproj` folders are
/// copied into `Contents/Resources` and looked up through `Bundle.main` — the classic
/// layout, and the one that keeps working without a `.xcodeproj`.
///
/// Keys are the English text. A missing translation therefore falls back to something
/// readable rather than to `settings.quiet.section.title`.
func t(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "")
}

/// Formats *after* looking up, so a placeholder lands inside the translated sentence
/// rather than being appended to it — French puts `%@` in a different place than English
/// more often than not.
func t(_ key: String, _ arguments: any CVarArg...) -> String {
    String(format: NSLocalizedString(key, bundle: .main, comment: ""), arguments: arguments)
}
