import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = NotchController()
    private lazy var model = AppModel(notch: controller)
    /// Held for the process's lifetime: `UNUserNotificationCenter` keeps its delegate
    /// weakly, and a router that deallocates turns every notification click into nothing.
    private let notifications = NotificationRouter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = notifications
        model.start()
        controller.start(content: NotchRootView(controller: controller, model: model))
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Leaving a stale runtime.json behind would make every hook wait for a timeout.
        model.stop()
    }
}

let application = NSApplication.shared

if CommandLine.arguments.contains("--diagnose") {
    Diagnostics.run()
    exit(0)
}

if CommandLine.arguments.contains("--status") {
    exit(Diagnostics.status())
}

if CommandLine.arguments.contains("--index") {
    exit(Diagnostics.index())
}

if CommandLine.arguments.contains("--report") {
    exit(Diagnostics.report())
}

if CommandLine.arguments.contains("--update") {
    exit(Diagnostics.update(install: CommandLine.arguments.contains("--install")))
}

if CommandLine.arguments.contains("--settings") {
    exit(Diagnostics.settings())
}

if CommandLine.arguments.contains("--quota") {
    exit(Diagnostics.quota())
}

if let index = CommandLine.arguments.firstIndex(of: "--render") {
    let path =
        CommandLine.arguments.count > index + 1
        ? CommandLine.arguments[index + 1] : "perch-panel.png"
    exit(
        Diagnostics.render(
            path, layout: CommandLine.arguments.contains("--clean") ? .clean : .detailed))
}

if let index = CommandLine.arguments.firstIndex(of: "--tasks") {
    let session = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : ""
    exit(Diagnostics.tasks(session))
}

if let index = CommandLine.arguments.firstIndex(of: "--answer") {
    let labels = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : ""
    exit(Diagnostics.answer(labels))
}

if let index = CommandLine.arguments.firstIndex(of: "--rank") {
    exit(LeaderboardCLI.run(Array(CommandLine.arguments.dropFirst(index + 1))))
}

if let index = CommandLine.arguments.firstIndex(of: "--decide") {
    let decision = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : ""
    exit(Diagnostics.decide(decision, remember: CommandLine.arguments.contains("--remember")))
}

let delegate = AppDelegate()
application.delegate = delegate
// No Dock icon, no menu bar: Perch lives in the notch only.
application.setActivationPolicy(.accessory)
application.run()
