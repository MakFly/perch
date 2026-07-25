import PerchKit
import SwiftUI

/// The panel, rendered off screen to a file.
///
/// The notch is the one part of Perch that cannot be looked at from a terminal: taking a
/// screenshot of it needs Screen Recording, and opening it needs a synthetic click, which
/// needs Accessibility — two permissions Perch is built never to ask for. So the panel is
/// drawn into a bitmap instead, with fabricated sessions that exercise every branch worth
/// seeing at once. `ImageRenderer` needs neither permission.
///
/// This is a design harness, not a test: it says what the panel looks like, and nothing
/// about whether the app wires it to real data. `--status` covers that half.
@MainActor
enum PanelPreview {
    /// A session per case the card has to handle, so one image answers all of them.
    static func scene(layout: PanelLayout = .detailed) -> some View {
        VStack(alignment: .leading, spacing: Theme.rowSpacing) {
            header

            SessionCardView(session: working, tasks: plan, layout: layout)
            SessionCardView(session: unattended, layout: layout)
            SessionCardView(session: waiting, layout: layout)
        }
        .padding(.horizontal, 14)
        .padding(.top, 32 + 12)
        .padding(.bottom, 12)
        .frame(width: 680, alignment: .topLeading)
        .background(Theme.surface)
    }

    private static var header: some View {
        HStack(spacing: 8) {
            ForEach(["activity", "stats", "rank"], id: \.self) { tab in
                Text(tab)
                    .font(Theme.label(11, .medium))
                    .foregroundStyle(tab == "activity" ? Theme.primary : Theme.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(tab == "activity" ? Theme.hairlineStrong : .clear))
            }

            Spacer(minLength: 0)

            UsageLimitsStrip(reading: quota)

            ForEach(["speaker.wave.2", "gearshape", "xmark"], id: \.self) { symbol in
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .padding(5)
                    .background(Circle().fill(Theme.hairline))
            }
        }
    }

    // MARK: - Fabricated data

    private static func session(
        id: String, cwd: String, title: String, prompt: String, detail: String,
        status: SessionStatus, agent: Agent, mode: String?, subagents: Int = 0,
        age: TimeInterval
    ) -> SessionSnapshot {
        var snapshot = SessionSnapshot(
            id: id, cwd: cwd, lastEvent: .now, lastDetail: detail, status: status,
            subagents: subagents, startedAt: Date.now.addingTimeInterval(-age))
        snapshot.prompt = prompt
        snapshot.aiTitle = title
        snapshot.agent = agent
        snapshot.permissionMode = mode
        return snapshot
    }

    private static var working: SessionSnapshot {
        session(
            id: "a", cwd: "/Users/dev/design-ui", title: "Fix agent progress animation",
            prompt: "run the steps in order with a commit each",
            detail: "chrome-devtools: take_screenshot thread-store.ts",
            status: .working, agent: .claude, mode: "default", age: 22 * 60)
    }

    /// The one the panel exists for: nobody is watching and it may act without asking.
    private static var unattended: SessionSnapshot {
        session(
            id: "b", cwd: "/Users/dev/tools", title: "Perch animation typography sync",
            prompt: "make the notch move like Vibe Island",
            detail: "Bash(swift build)", status: .working, agent: .claude,
            mode: "bypassPermissions", subagents: 3, age: 96 * 60)
    }

    private static var waiting: SessionSnapshot {
        session(
            id: "c", cwd: "/Users/dev/server-api", title: "Port the ledger to polars",
            prompt: "keep decimal arithmetic end to end",
            detail: "", status: .idle, agent: .codex, mode: "plan", age: 3 * 3_600)
    }

    private static var plan: TaskBoard {
        func task(_ id: Int, _ subject: String, _ status: AgentTask.Status) -> AgentTask {
            AgentTask(id: "\(id)", subject: subject, status: status)
        }
        return TaskBoard.make(
            from: [
                task(0, "Safe defaults and invisible state leaks", .completed),
                task(1, "Split the chat/agent system prompt", .completed),
                task(2, "Explicit workspace root, checked at boot", .completed),
                task(3, "Read-only tools + tool_call/tool_result events", .completed),
                task(4, "Writes plus human approval, same increment", .inProgress),
                task(5, "Binding plan mode and loop repair", .pending),
                task(6, "Project registry and a real picker", .pending),
            ].compactMap { try? JSONEncoder().encode(TaskFile($0)) })
    }

    /// The board is built from raw files on purpose — the preview then exercises the same
    /// decoding and ordering the app does, rather than a shortcut only the preview has.
    private struct TaskFile: Encodable {
        let id: String
        let subject: String
        let status: String

        init(_ task: AgentTask) {
            id = task.id
            subject = task.subject
            status = task.status.rawValue
        }
    }

    private static var quota: UsageLimitsReader.Reading {
        UsageLimitsReader.Reading(
            limits: RateLimits(
                fiveHour: RateLimitWindow(
                    utilization: 13, resetsAt: .now.addingTimeInterval(2 * 3_600 + 120)),
                sevenDay: RateLimitWindow(
                    utilization: 28, resetsAt: .now.addingTimeInterval(4 * 86_400 + 17 * 3_600))),
            updatedAt: .now)
    }
}
