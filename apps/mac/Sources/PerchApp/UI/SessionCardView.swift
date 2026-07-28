import PerchKit
import SwiftUI

/// One running agent, as a card.
///
/// The panel used to be a feed of tool calls, which answers "what just happened" but not
/// "what are my agents doing" — and the second is the question you open the notch for.
/// A card is per session: what it is working on, what you asked, where it runs, how long
/// it has been going.
struct SessionCardView: View {
    let session: SessionSnapshot
    /// The session's plan, empty for the many sessions that never use the task tool.
    var tasks: TaskBoard = .empty
    /// How much of the session to spell out. Clean keeps one line of chrome per card so
    /// six agents still fit on screen.
    var layout: PanelLayout = .detailed
    /// Selected by the switcher. Distinct from hover: the keyboard and the mouse can point
    /// at different cards at the same time.
    var isSelected = false
    var onJump: (() -> Void)?
    var onSilence: ((AdmissionRule) -> Void)?

    @State private var isHovered = false

    private var plan: JumpPlan { TerminalJump.plan(for: session.client) }

    /// Each agent keeps its own colour, so two of them in the same project stay apart.
    private var agentTint: Color {
        switch session.agent {
        case .claude: return Theme.claude
        case .codex: return Theme.info
        case .gemini: return Theme.warning
        case .unknown: return Theme.secondary
        }
    }

    var body: some View {
        card
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture { if plan.isPossible { onJump?() } }
            .help(plan.summary)
            // Silencing from the card itself is the only entry point that costs nothing:
            // the session you want gone is the one you are already looking at.
            .contextMenu {
                if let cwd = session.cwd {
                    Button(t("Hide sessions in %@", session.projectName ?? cwd)) {
                        onSilence?(
                            AdmissionRule(field: .directory, match: .contains, pattern: cwd))
                    }
                }
                if let prompt = session.prompt, !prompt.isEmpty {
                    Button(t("Silence prompts starting with “%@…”", String(prompt.prefix(28)))) {
                        onSilence?(
                            AdmissionRule(
                                field: .prompt, match: .prefix,
                                pattern: String(prompt.prefix(28))))
                    }
                }
            }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 8) {
            // The agent's own mark leads the row, and the status moved to the far end.
            // A dot on the left says "something is happening" and nothing else; the mark
            // says *which* agent, which is the question you have when three of them are
            // running and one of them is the one you left unattended.
            AgentGlyph(agent: session.agent, pixel: 1.5, isBreathing: session.isWorking)
                // Optical alignment with the first line of text rather than the box.
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                headline

                // The exchange itself, when it has been read. This replaces the one-line
                // echo of the prompt: the same question is in it, with the answer under it.
                if layout.showsPrompt, let turn = session.turn, !turn.isEmpty {
                    TranscriptView(
                        turn: turn,
                        fallbackPrompt: session.prompt,
                        isFinished: !session.isWorking
                    )
                    .padding(.top, 3)
                    .padding(.bottom, 1)
                } else if layout.showsPrompt, let prompt = session.prompt, !prompt.isEmpty {
                    Text(t("You: %@", prompt))
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                activityLine

                // Children, not a number. A count says a session is busy; this says what
                // it fanned out to and how long that one has been going, which is the
                // question you actually have ten minutes into a quiet card.
                if layout.showsTasks, !session.children.isEmpty {
                    ForEach(session.children) { child in
                        HStack(spacing: 4) {
                            Text("└")
                                .font(Theme.mono(9))
                                .foregroundStyle(Theme.hairline)
                            Text(child.label)
                                .font(Theme.mono(9))
                                .foregroundStyle(Theme.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(SessionCardView.elapsed(since: child.startedAt))
                                .font(Theme.mono(9))
                                .foregroundStyle(Theme.hairline)
                                .monospacedDigit()
                        }
                    }
                }

                if layout.showsTasks, !tasks.isEmpty {
                    TaskBoardView(board: tasks)
                        .padding(.top, 2)
                } else if !tasks.isEmpty, let current = tasks.current {
                    // Clean still says where the plan is: the running step and the score,
                    // on the one line it has. A card that hides the plan entirely makes
                    // Clean a different product rather than a denser one.
                    Text("▸ \(current.subject)  \(tasks.completed)/\(tasks.tasks.count)")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .fill(Theme.raised.opacity(isSelected || (isHovered && plan.isPossible) ? 0.9 : 0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .stroke(
                    isSelected
                        ? Theme.info
                        : (isHovered && plan.isPossible ? Theme.hairlineStrong : Theme.hairline),
                    lineWidth: isSelected ? 1.5 : 1)
        )
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var headline: some View {
        HStack(spacing: 5) {
            // Project first, then what it is doing. Three cards deep, the eye is looking
            // for *which repo* before it reads the task — and the project is the short,
            // stable half, so putting it first gives every row the same left edge to scan.
            if session.aiTitle != nil, let project = session.projectName {
                Text(project)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                Text("·")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.tertiary)
            }

            Text(session.title)
                .font(Theme.label(11, .semibold))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if session.subagents > 0 {
                Chip(text: t("%lld agents", session.subagents), tint: Theme.info)
            }
            // Loudest chip on the row, and first, because it is the only one that says what
            // this agent is allowed to do to the machine without asking.
            if let badge = session.permissionBadge {
                Chip(
                    text: badge,
                    tint: session.permissionIsPermissive ? Theme.danger : Theme.info)
            }
            Chip(text: session.agent.displayName, tint: agentTint)
            if let terminal = session.client?.displayName {
                // Tinted while hovered: the chip is the thing that says where you land.
                Chip(text: terminal, tint: isHovered && plan.isPossible ? Theme.info : nil)
            }

            Text(age)
                .font(Theme.mono(9))
                .foregroundStyle(Theme.tertiary)
                .monospacedDigit()

            StatusDot(status: session.status)
        }
    }

    /// What it is doing right now — the line that changes while you watch.
    @ViewBuilder
    private var activityLine: some View {
        switch session.status {
        case .compacting:
            Text(t("Compacting context…"))
                .font(Theme.mono(10))
                .foregroundStyle(Theme.warning)
        case .idle:
            Text(t("Waiting for you"))
                .font(Theme.mono(10))
                .foregroundStyle(Theme.tertiary)
        case .failed:
            Text(session.lastDetail.isEmpty ? t("Ended on a failure") : session.lastDetail)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.danger)
                .lineLimit(1)
                .truncationMode(.middle)
        case .needsApproval:
            Text(t("Waiting for your approval"))
                .font(Theme.mono(10))
                .foregroundStyle(Theme.warning)
        case .waitingForAnswer:
            Text(t("Waiting for your answer"))
                .font(Theme.mono(10))
                .foregroundStyle(Theme.warning)
        case .waitingForInput:
            Text(t("Waiting for your input"))
                .font(Theme.mono(10))
                .foregroundStyle(Theme.warning)
        case .working, .runningTool:
            // The same line either way: what it is doing is the command, and the dot
            // beside it already says whether a tool is in flight.
            Text(session.lastDetail)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.info)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// Coarse on purpose: a second-by-second counter on every card is noise, and the
    /// panel redraws often enough that it would never settle.
    private var age: String { Self.elapsed(since: session.startedAt) }

    static func elapsed(since date: Date, now: Date = .now) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "\(max(1, seconds))s"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}

private struct StatusDot: View {
    let status: SessionStatus
    @State private var isPulsing = false

    private var tint: Color {
        switch status {
        case .working, .runningTool: return Theme.active
        // Everything that is blocked on a person shares one colour. Which flavour of
        // waiting it is belongs on the line; the dot answers "does this need me".
        case .needsApproval, .waitingForAnswer, .waitingForInput: return Theme.warning
        case .compacting: return Theme.warning
        case .idle: return Theme.tertiary
        case .failed: return Theme.danger
        }
    }

    /// Pulses while something is happening on its own. A session waiting on you is not
    /// live — it is stopped, and a heartbeat would say the opposite.
    private var isLive: Bool {
        status == .working || status == .runningTool || status == .compacting
    }

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 6, height: 6)
            .opacity(isLive && isPulsing ? 0.35 : 1)
            .animation(
                isLive
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .default,
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

/// Small capsule label: the agent, the terminal, a subagent count.
struct Chip: View {
    let text: String
    let tint: Color?

    var body: some View {
        Text(text)
            .font(Theme.mono(9, .medium))
            .foregroundStyle(tint ?? Theme.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(
                Capsule().fill((tint ?? Color.white).opacity(0.12))
            )
            .fixedSize()
    }
}
