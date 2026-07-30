import Foundation

/// Where a sprite sheet is looked for, and in what order.
///
/// The sheets are optional by construction — with none installed the app draws its own
/// pixel art — and they are kept out of the repository because what is in them is not ours
/// to redistribute. Which means the DMG anyone downloads has no `Sprites` directory in it,
/// and a build that had them locally loses them the moment it is replaced by one that
/// shipped: the updater swaps the whole bundle, so anything dropped inside goes with it.
///
/// So the sheets live next to the rest of Perch's own state instead. `~/.perch/sprites`
/// survives an update, a reinstall, and a version that never knew about it — and it wins
/// over the bundle, because a file someone put there by hand is a decision, and one that
/// shipped is a default.
public enum SpriteLocation {
    /// `~/.perch/sprites`, beside `cache/` and `preferences.json`.
    public static var userDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".perch/sprites", isDirectory: true)
    }

    /// The sheet to load for `name`, or nil when neither place has one.
    ///
    /// `bundled` is passed in rather than looked up here: `Bundle.main` is the app's
    /// question, and this type is in the framework the tests can reach.
    public static func sheetURL(
        named name: String,
        bundled: URL?,
        in directory: URL = userDirectory,
        fileManager: FileManager = .default
    ) -> URL? {
        let installed = directory.appendingPathComponent("\(name).png")
        if fileManager.fileExists(atPath: installed.path) { return installed }
        return bundled
    }
}
