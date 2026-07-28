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

    /// A reply with a heading, prose, a bullet and a fenced block — the four shapes the
    /// card has to render, in one card, so the image answers all of them.
    private static let reply = """
        ## What the code actually does

        The latency is not the right measure here, and the numbers show it — the read is \
        cached after the first call.

        - `distillBatch = 24` episodes per call
        - the fallback path is never taken
        - the second read is served from the page cache, which is why the median moved
        - and the tail did not, because the tail is the first call of each session

        ```
        swift build && swift test
        ```
        """

    private static var working: SessionSnapshot {
        var snapshot = session(
            id: "a", cwd: "/Users/dev/design-ui", title: "Fix agent progress animation",
            prompt: "run the steps in order with a commit each",
            detail: "chrome-devtools: take_screenshot thread-store.ts",
            status: .working, agent: .claude, mode: "default", age: 22 * 60)
        snapshot.turn = TranscriptTurn(
            prompt: "why is the nvidia key path slower than the cached one?", reply: reply)
        return snapshot
    }

    /// The one the panel exists for: nobody is watching and it may act without asking.
    private static var unattended: SessionSnapshot {
        session(
            id: "b", cwd: "/Users/dev/tools", title: "Perch animation typography sync",
            prompt: "make the notch move like Vibe Island",
            detail: "Bash(swift build)", status: .working, agent: .claude,
            mode: "bypassPermissions", subagents: 3, age: 96 * 60)
    }

    /// Finished, so the card says `Done` rather than `Writing…`.
    private static var waiting: SessionSnapshot {
        var snapshot = session(
            id: "c", cwd: "/Users/dev/server-api", title: "Port the ledger to polars",
            prompt: "keep decimal arithmetic end to end",
            detail: "", status: .idle, agent: .codex, mode: "plan", age: 3 * 3_600)
        snapshot.turn = TranscriptTurn(
            prompt: "keep decimal arithmetic end to end",
            reply: "Ported. Every column is `Decimal` now, and the two totals agree to the cent.")
        return snapshot
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

    /// The resting strip, above a stand-in for the hardware cutout.
    ///
    /// The one part of the UI that cannot be photographed without Screen Recording *and*
    /// cannot be opened without Accessibility — so it is the part most worth drawing here.
    /// Two rows: what it looks like with agents running and a request held, and what it
    /// looks like with nothing running at all, which has to be exactly nothing.
    static func idleScene() -> some View {
        VStack(spacing: 24) {
            ForEach([true, false], id: \.self) { busy in
                VStack(spacing: 6) {
                    Text(busy ? "two agents · one request held" : "nothing running")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.tertiary)

                    let reading =
                        busy
                        ? IdleReading(
                            agents: [(.claude, true), (.codex, false)], count: 3, needsYou: true)
                        : IdleReading(agents: [], count: 0, needsYou: false)
                    let flank = IdleView.flank(
                        for: reading, quota: busy ? quota : nil, waiting: busy ? 1 : 0)

                    ZStack(alignment: .top) {
                        // The cutout, drawn as the hardware would be: nothing may cross it.
                        Rectangle()
                            .fill(Color.black)
                            .frame(width: 200 + flank * 2, height: 32)
                        IdleView(
                            reading: reading, notchWidth: 200, notchHeight: 32,
                            quota: busy ? quota : nil, waiting: busy ? 1 : 0)
                    }
                    .overlay(
                        Rectangle().stroke(Theme.hairline, lineWidth: 1)
                            .frame(width: 200, height: 32))

                    Text("flank \(Int(flank))pt")
                        .font(Theme.mono(8))
                        .foregroundStyle(Theme.hairlineStrong)
                }
            }
        }
        .padding(28)
        .frame(width: 680)
        .background(Theme.raised)
    }

    private static var quota: UsageLimitsReader.Reading {
        UsageLimitsReader.Reading(
            limits: RateLimits(
                fiveHour: RateLimitWindow(
                    utilization: 13, resetsAt: .now.addingTimeInterval(2 * 3_600 + 120)),
                sevenDay: RateLimitWindow(
                    utilization: 28, resetsAt: .now.addingTimeInterval(4 * 86_400 + 17 * 3_600)),
                sevenDayOpus: RateLimitWindow(
                    utilization: 61, resetsAt: .now.addingTimeInterval(2 * 86_400))),
            updatedAt: .now)
    }
}
