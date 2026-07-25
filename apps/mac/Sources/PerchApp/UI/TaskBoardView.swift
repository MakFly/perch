import PerchKit
import SwiftUI

/// A session's plan, under its card.
///
/// The tool feed answers "what did it just do" and the card's activity line answers "what
/// is it doing"; neither answers "how far through is it", which is the question you have
/// when you glance at a machine that has been working for twenty minutes without you.
///
/// Ordered the way it is read rather than the way it is stored — what is happening, then
/// what is next, then what is done — and the done tail is collapsed, because a plan that
/// is mostly finished should not push the next step off the card.
struct TaskBoardView: View {
    let board: TaskBoard

    /// Six rows is what fits under a card without the panel becoming a task list with a
    /// session attached.
    private let visibleRows = 6

    private var shown: [AgentTask] { Array(board.tasks.prefix(visibleRows)) }
    private var hidden: [AgentTask] { Array(board.tasks.dropFirst(visibleRows)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(headline)
                .font(Theme.mono(9))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)

            ForEach(shown) { task in
                TaskRow(task: task)
            }

            if !hidden.isEmpty {
                Text(overflow)
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.tertiary)
                    // Aligned with the subjects above, not with the marks.
                    .padding(.leading, 14)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04))
        )
    }

    /// Counts, not a progress bar: "3 done, 1 running, 3 open" says which of the three
    /// numbers moved since you last looked, and a bar does not.
    private var headline: String {
        var parts: [String] = []
        if board.completed > 0 { parts.append(t("%lld done", board.completed)) }
        if board.inProgress > 0 { parts.append(t("%lld running", board.inProgress)) }
        if board.open > 0 { parts.append(t("%lld open", board.open)) }
        return t("Tasks (%@)", parts.joined(separator: ", "))
    }

    private var overflow: String {
        hidden.allSatisfy { $0.status == .completed }
            ? t("… +%lld done", hidden.count)
            : t("… +%lld more", hidden.count)
    }
}

private struct TaskRow: View {
    let task: AgentTask

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: mark)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 8)

            Text(task.subject)
                .font(Theme.mono(10))
                .foregroundStyle(text)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
    }

    private var mark: String {
        switch task.status {
        case .inProgress: return "circle.fill"
        case .pending: return "square"
        case .completed: return "checkmark.square.fill"
        }
    }

    private var tint: Color {
        switch task.status {
        case .inProgress: return Theme.info
        case .pending: return Theme.tertiary
        case .completed: return Theme.tertiary
        }
    }

    /// The running step is the one you are looking for, so it is the only one at full
    /// contrast. Done steps stay legible but recede — they are context, not news.
    private var text: Color {
        switch task.status {
        case .inProgress: return Theme.primary
        case .pending: return Theme.secondary
        case .completed: return Theme.tertiary
        }
    }
}
