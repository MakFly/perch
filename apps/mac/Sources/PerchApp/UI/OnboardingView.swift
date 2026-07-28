import AppKit
import PerchKit
import SwiftUI

/// The first screen.
///
/// It reports rather than interrogates: Perch can see which agents and terminals are on
/// this Mac, so asking you to tick boxes about your own machine would be asking a question
/// it already knows the answer to.
///
/// It appears once — when at least one agent is installed and none of them are wired up —
/// and never again. An app that greets you every launch is an app you learn to dismiss
/// without reading.
struct OnboardingView: View {
    let model: AppModel
    let onDone: () -> Void

    @State private var tools = EnvironmentScan.run()
    @State private var isWorking = false
    @State private var message: String?

    private var agents: [DetectedTool] { tools.filter { $0.kind == .agent } }
    private var terminals: [DetectedTool] { tools.filter { $0.kind == .terminal } }
    private var editors: [DetectedTool] { tools.filter { $0.kind == .editor } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t("Approve Claude Code from the notch"))
                    .font(.title2).bold()
                // Says outright that the list is a report. Without this line the rows read
                // as a form, and the first thing anyone does is try to tick one.
                Text(t("Here is what Perch found on this Mac. Nothing below is a choice — one button sets up everything listed."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if agents.isEmpty {
                Text(t("No agent CLI found. Install Claude Code, then reopen Perch."))
                    .foregroundStyle(.orange)
            } else {
                group(t("Agents"), agents)
            }
            if !terminals.isEmpty { group(t("Terminals"), terminals) }
            if !editors.isEmpty { group(t("Editors"), editors) }

            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Button(t("Set up this Mac")) { configure() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || agents.isEmpty)
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button(t("Not now"), action: onDone)
            }
        }
        .padding(24)
        .frame(width: 560, height: 460)
    }

    private func group(_ title: String, _ items: [DetectedTool]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ForEach(items) { tool in
                HStack(spacing: 8) {
                    Image(systemName: symbol(for: tool))
                        .foregroundStyle(colour(for: tool))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tool.name)
                        Text(tool.evidence).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(status(for: tool))
                        .font(.caption)
                        .foregroundStyle(colour(for: tool))
                }
            }
        }
    }

    /// Deliberately not `circle`.
    ///
    /// An empty circle at the head of a list row is the shape of an unselected radio
    /// button, so that is what people take it for — the first thing anyone did with this
    /// screen was try to click one. These are three *states*, and none of them is a
    /// control: the only control on the screen is the button at the bottom.
    private func symbol(for tool: DetectedTool) -> String {
        switch tool.isConfigured {
        case true: return "checkmark.circle.fill"
        case false: return "arrow.down.circle"
        // Terminals need nothing installed, so anything implying work to do would be a lie.
        case nil: return "checkmark.circle"
        }
    }

    private func status(for tool: DetectedTool) -> String {
        switch tool.isConfigured {
        case true: return t("ready")
        case false: return t("will be set up")
        case nil: return t("nothing to do")
        }
    }

    private func colour(for tool: DetectedTool) -> Color {
        switch tool.isConfigured {
        case true: return .green
        case false: return .accentColor
        case nil: return .secondary
        }
    }

    /// Runs the same scripts the README documents rather than reimplementing them in
    /// Swift: one behaviour, one place to fix it, and what happened is inspectable
    /// afterwards in the files they touched.
    private func configure() {
        isWorking = true
        message = nil

        Task {
            var done: [String] = []

            if RepoScripts.run("install-hooks.sh", ["--global"]) {
                done.append("Claude Code")
            }
            if agents.contains(where: { $0.name == "Codex" }),
                RepoScripts.run("install-hooks.sh", ["--codex"])
            {
                done.append("Codex")
            }
            if !editors.isEmpty, RepoScripts.run("install-extension.sh") {
                done.append("editor extension")
            }

            tools = EnvironmentScan.run()
            isWorking = false
            message =
                done.isEmpty
                ? t("Nothing could be set up automatically — see the README.")
                // The part everyone misses, said last so it is the thing left on screen.
                : t(
                    "Set up: %@.\n\nRestart any Claude Code session you already have open — "
                        + "hooks are read once, when a session starts, so a running one "
                        + "ignores them and the notch stays empty.",
                    done.joined(separator: ", "))
        }
    }

}

/// Hosts the first screen. Same shape as the settings window, and for the same reason:
/// an accessory app has nothing that would otherwise bring a window forward.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?

    func show(model: AppModel) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Perch"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(
            rootView: OnboardingView(model: model) { [weak window] in window?.close() })

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
