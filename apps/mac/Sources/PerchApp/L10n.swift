import AppKit
import Foundation
import PerchKit

/// Puts the chosen language in front of whatever macOS would have picked.
///
/// `AppleLanguages` in the app's own defaults is the same lever `defaults write` pulls, and
/// it is read by `Bundle.main` the first time a string is looked up — so this has to run
/// before anything is drawn, and before the CLI paths that render off screen. Setting it
/// here rather than asking the user to run a command means English is what a fresh install
/// speaks, on a French Mac as much as on any other.
///
/// `.system` removes the key instead of writing one: the point of that setting is to stop
/// overriding, not to override with something else.
@MainActor
func applyLanguagePreference(_ preferences: Preferences = .load()) {
    let defaults = UserDefaults.standard
    if let identifiers = preferences.language.localeIdentifiers {
        defaults.set(identifiers, forKey: "AppleLanguages")
    } else {
        defaults.removeObject(forKey: "AppleLanguages")
    }
}

/// Quits and comes back, which is what a language change needs.
///
/// `Bundle.main` resolves its localisation once per process, so a picker that only wrote the
/// preference would leave the window half translated until the next launch. Same shape as
/// the updater's swap: a small script that outlives this process, waits for it to go, and
/// opens the bundle again.
@MainActor
func relaunchPerch() {
    let bundle = Bundle.main.bundleURL.path
    let pid = ProcessInfo.processInfo.processIdentifier
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
        "-c",
        """
        for _ in $(seq 1 100); do
          kill -0 \(pid) 2>/dev/null || break
          sleep 0.1
        done
        open "\(bundle)"
        """,
    ]
    try? process.run()
    NSApp.terminate(nil)
}

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
