import AppKit
import SwiftUI

/// Hosts the settings window.
///
/// Perch is an accessory app with no Dock icon and no menu bar, so there is nothing that
/// would normally bring a window forward — the app has to activate itself, and the window
/// has to be reused rather than stacked up one per click.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    /// Reports what actually happened, so `--settings` can be verified from a terminal on
    /// a machine where nothing is allowed to enumerate windows.
    var isVisible: Bool { window?.isVisible ?? false }

    @discardableResult
    func show(model: AppModel) -> Bool {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return window.isVisible
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Perch Settings"
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.isReleasedWhenClosed = false
        window.center()

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window.isVisible
    }
}
