import Foundation
import ServiceManagement

/// Whether macOS opens Perch when the user logs in.
///
/// `SMAppService.mainApp` rather than a hand-written `~/Library/LaunchAgents` plist: it
/// registers the bundle that is running, needs no path baked into a file that goes stale
/// the moment the app moves, and puts the entry in System Settings › General › Login Items
/// where a user looks for it. macOS 13 and up, and Perch targets 14.
///
/// Nothing here throws outward. A login item that could not be registered is worth a line
/// in the log and nothing more — it must never take down a launch, and it must never put a
/// dialog in front of someone who only opened the settings window.
enum LoginItem {
    /// False outside an app bundle — `swift test`, `swift run`, the `--render` and
    /// `--diagnose` paths in main.swift. `SMAppService.mainApp` in those contexts would be
    /// registering whatever binary SwiftPM happened to build, which is never what anyone
    /// asked for.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// What macOS thinks, which is the answer the settings toggle shows.
    ///
    /// Deliberately not derived from the preference: the same switch exists in System
    /// Settings, and a toggle that ignores it would claim Perch starts at login while
    /// macOS has been told otherwise.
    static var isRegistered: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters, skipping the call when it would change nothing —
    /// `updatePreferences` runs on every settings change, and re-registering an already
    /// registered app is a system write for no reason.
    static func apply(_ enabled: Bool) {
        guard isAvailable else { return }
        let service = SMAppService.mainApp
        do {
            if enabled {
                guard service.status != .enabled else { return }
                try service.register()
            } else {
                guard service.status == .enabled else { return }
                try service.unregister()
            }
        } catch {
            NSLog("perch: could not \(enabled ? "register" : "unregister") login item: \(error)")
        }
    }
}
