import AppKit
import Foundation
import Observation
import PerchKit

/// Watches what the machine is doing that Perch should not interrupt: the screen locked
/// or asleep, a screen recording or share in progress, a Focus mode on.
///
/// All three are read rather than subscribed to where macOS gives no notification, which
/// is why the value is recomputed on demand instead of pushed.
@MainActor
@Observable
final class SceneMonitor {
    private(set) var scene = Scene()

    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            observers.append(
                center.addObserver(forName: .init(name), object: nil, queue: .main) {
                    [weak self] _ in
                    Task { @MainActor in self?.scene.isScreenObscured = true }
                })
        }
        for name in ["com.apple.screenIsUnlocked", "com.apple.screensaver.didstop"] {
            observers.append(
                center.addObserver(forName: .init(name), object: nil, queue: .main) {
                    [weak self] _ in
                    Task { @MainActor in self?.scene.isScreenObscured = false }
                })
        }

        refresh()
    }

    func stop() {
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
    }

    /// Called before anything that would take the screen.
    func refresh() {
        scene.isScreenShared = Self.isScreenBeingCaptured()
        scene.isFocusActive = Self.isFocusActive()
        scene.frontmostBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// `NSScreen.isCaptured` is the only public signal for "someone else is seeing this",
    /// and it covers both recording and sharing.
    private static func isScreenBeingCaptured() -> Bool {
        NSScreen.screens.contains { screen in
            (screen.value(forKey: "isCaptured") as? Bool) ?? false
        }
    }

    /// macOS has no API for "is a Focus on", so this reads the same assertion file the
    /// system writes. Absent or unreadable means not focused, which is the safe reading:
    /// Perch stays useful rather than silently muting itself forever.
    private static func isFocusActive() -> Bool {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/DoNotDisturb/DB/Assertions.json")
        guard let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let records = root["data"] as? [[String: Any]]
        else { return false }

        return records.contains { record in
            guard let details = record["storeAssertionRecords"] as? [[String: Any]] else {
                return false
            }
            return !details.isEmpty
        }
    }
}
