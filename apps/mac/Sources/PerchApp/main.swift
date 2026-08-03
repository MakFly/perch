import AppKit
import PerchKit
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
        // The one line that has to be there whether or not anything goes wrong.
        //
        // Every other call into `PerchLog` is on a failure path, which means a log file
        // that only exists once the app has already broken — and a crash reconstructed
        // from it could not tell "started at 21:03 and died" from "never started". A
        // launch is also the only place the version and the pid are both known, and the
        // pid is what ties a line here to a `.ips` report.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        PerchLog.info(
            "Perch \(version ?? "?") launched, pid \(ProcessInfo.processInfo.processIdentifier)")

        UNUserNotificationCenter.current().delegate = notifications
        model.start()
        controller.start(content: NotchRootView(controller: controller, model: model))
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Paired with the launch line: a log that ends here records a quit, and a log that
        // ends without it records a death. That difference is the whole question being
        // asked of this file after a crash, and nothing else in the app answers it.
        PerchLog.info("Perch is quitting")
        // Leaving a stale runtime.json behind would make every hook wait for a timeout.
        model.stop()
        // After the stop, so anything it logs on the way down is included: an `info` is
        // written on a queue this process is about to stop draining.
        PerchLog.flush()
    }
}

// Before `NSApplication`, not merely before the first window: AppKit resolves the bundle's
// localisation as it starts up, and a language written after that lands one launch late.
// English is the default whatever the Mac is set to.
applyLanguagePreference()

let application = NSApplication.shared

if CommandLine.arguments.contains("--diagnose") {
    Diagnostics.run()
    exit(0)
}

if CommandLine.arguments.contains("--status") {
    exit(Diagnostics.status())
}

if CommandLine.arguments.contains("--codex") {
    exit(Diagnostics.codex())
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

if CommandLine.arguments.contains("--reveal") {
    exit(Diagnostics.reveal())
}

if CommandLine.arguments.contains("--settings") {
    exit(Diagnostics.settings())
}

if CommandLine.arguments.contains("--forget-login-item") {
    exit(Diagnostics.forgetLoginItem())
}

if let index = CommandLine.arguments.firstIndex(of: "--render") {
    let path =
        CommandLine.arguments.count > index + 1
        ? CommandLine.arguments[index + 1] : "perch-panel.png"
    exit(
        Diagnostics.render(
            path, layout: CommandLine.arguments.contains("--clean") ? .clean : .detailed,
            // `--render x.png --idle` draws the resting strip instead of the panel, and
            // `--phases` draws every state in its own shape, over a menu bar.
            idle: CommandLine.arguments.contains("--idle"),
            phases: CommandLine.arguments.contains("--phases"),
            // `--render x.png --stats opencode` draws the Stats pane for one agent, off
            // this machine's own index. The tabs are the one part of that pane no
            // fabricated scene can stand in for: whether they are right is a question
            // about what was actually indexed here.
            stats: CommandLine.arguments.firstIndex(of: "--stats").map { index in
                CommandLine.arguments.count > index + 1
                    ? UsageStore.Agent(rawValue: CommandLine.arguments[index + 1]) ?? .claude
                    : .claude
            }))
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
