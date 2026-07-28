import PerchKit
import SwiftUI

/// Answering `AskUserQuestion` from the notch.
///
/// Approving the *asking* of a question is useless — the point of the tool is the answer.
/// A session is blocked while this is up, so it shows one question at a time with its
/// options, and only submits once every question has one.
struct QuestionCardView: View {
    let request: AskUserQuestionRequest
    let projectName: String?
    let submit: ([String: [String]]) -> Void
    let cancel: () -> Void

    @State private var answers: [String: [String]] = [:]
    /// What was typed rather than picked, keyed by question.
    @State private var typed: [String: String] = [:]
    @State private var index = 0

    private var question: AskQuestion? {
        request.questions.indices.contains(index) ? request.questions[index] : nil
    }

    /// Picked plus typed — what actually gets submitted, and what "is this answered yet"
    /// is judged against.
    private var effective: [String: [String]] {
        request.merged(picked: answers, typed: typed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if let question {
                Text(question.question)
                    .font(Theme.label(12, .semibold))
                    .foregroundStyle(Theme.primary)
                    .fixedSize(horizontal: false, vertical: true)

                options(for: question)
                otherField(for: question)
            }
            controls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.claude)

            Text(question?.header.isEmpty == false ? question!.header : t("Question"))
                .font(Theme.label(12, .semibold))
                .foregroundStyle(Theme.primary)

            if let projectName {
                Text(projectName)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if request.questions.count > 1 {
                Text(t("%lld of %lld", index + 1, request.questions.count))
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.tertiary)
            }
            if question?.multiSelect == true {
                Chip(text: t("multi"), tint: Theme.info)
            }
        }
    }

    private func options(for question: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(question.options) { option in
                OptionRow(
                    option: option,
                    isSelected: selected(question).contains(option.label),
                    multiSelect: question.multiSelect
                ) {
                    toggle(option.label, in: question)
                }
            }
        }
    }

    /// The free-text answer — the "none of these" every question implicitly has.
    ///
    /// Without it the only way to say something the options do not cover was to leave the
    /// notch and type in the terminal, which defeats the card.
    private func otherField(for question: AskQuestion) -> some View {
        TextField(
            question.multiSelect ? t("…and something else") : t("Other — write your answer"),
            text: Binding(
                get: { typed[question.question] ?? "" },
                set: { typed[question.question] = $0 })
        )
        .textFieldStyle(.plain)
        .font(Theme.mono(10))
        .foregroundStyle(Theme.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raised.opacity(0.6)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    hasTyped(question) ? Theme.active.opacity(0.5) : Theme.hairline,
                    lineWidth: 1)
        )
        // Enter submits, the way it does in the terminal prompt this replaces.
        .onSubmit {
            guard request.isComplete(effective) else { return }
            if index < request.questions.count - 1 { index += 1 } else { submit(effective) }
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if index > 0 {
                SmallButton(title: t("Back"), tint: nil) { index -= 1 }
            }

            Spacer(minLength: 0)

            SmallButton(title: t("Answer in terminal"), tint: nil, action: cancel)

            if index < request.questions.count - 1 {
                SmallButton(title: t("Next"), tint: Theme.info) { index += 1 }
                    .disabled(effective[question?.question ?? ""]?.isEmpty ?? true)
            } else {
                SmallButton(
                    title: request.questions.count > 1 ? t("Submit all") : t("Submit"),
                    tint: Theme.active
                ) {
                    submit(effective)
                }
                .disabled(!request.isComplete(effective))
            }
        }
    }

    private func hasTyped(_ question: AskQuestion) -> Bool {
        !(typed[question.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the option rows draw as picked.
    ///
    /// For a single-select question, typing hides the option tick: the two are alternatives
    /// and showing both selected would misrepresent what is about to be submitted.
    private func selected(_ question: AskQuestion?) -> [String] {
        guard let question else { return [] }
        if !question.multiSelect && hasTyped(question) { return [] }
        return answers[question.question] ?? []
    }

    /// Single-select replaces; multi-select accumulates and can be unpicked.
    private func toggle(_ label: String, in question: AskQuestion) {
        // Picking an option in a single-select question retracts anything typed — the
        // click is the more recent statement of intent.
        if !question.multiSelect { typed[question.question] = "" }

        var current = answers[question.question] ?? []
        if question.multiSelect {
            if let existing = current.firstIndex(of: label) {
                current.remove(at: existing)
            } else {
                current.append(label)
            }
        } else {
            current = current == [label] ? [] : [label]
        }
        answers[question.question] = current
    }
}

private struct OptionRow: View {
    let option: AskQuestion.Option
    let isSelected: Bool
    let multiSelect: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 7) {
                Image(
                    systemName: multiSelect
                        ? (isSelected ? "checkmark.square.fill" : "square")
                        : (isSelected ? "largecircle.fill.circle" : "circle")
                )
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? Theme.active : Theme.tertiary)
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(Theme.label(11, .medium))
                        .foregroundStyle(Theme.primary)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Theme.active.opacity(0.12) : Theme.raised.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Theme.active.opacity(0.5) : Theme.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension PlanCardView {
    /// The plan, as Markdown, falling back to the raw text when it will not parse.
    ///
    /// `.full` rather than `.inlineOnlyPreservingWhitespace`: a plan's structure *is* its
    /// headings and bullets, and dropping them to keep the newlines was the previous
    /// behaviour by accident. Blank lines are preserved before parsing, because
    /// `AttributedString` collapses paragraph breaks that the plan needs.
    var styledPlan: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        let spaced = request.plan.replacingOccurrences(of: "\n", with: "\n\n")
        if let parsed = try? AttributedString(markdown: spaced, options: options) {
            return parsed
        }
        return AttributedString(request.plan)
    }
}

/// Approving a plan, or sending back what to change.
///
/// Denying with a message is not a refusal here — Claude Code reads it as feedback and
/// keeps going, which is what "tell it what to fix" means.
struct PlanCardView: View {
    let request: PlanApprovalRequest
    let projectName: String?
    let approve: () -> Void
    let reject: (String) -> Void

    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.info)
                Text(t("Plan"))
                    .font(Theme.label(12, .semibold))
                    .foregroundStyle(Theme.primary)
                if let projectName {
                    Text(projectName)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.tertiary)
                }
                Spacer(minLength: 0)
            }

            ScrollView {
                // Rendered as Markdown, because that is what it is. A plan is the longest
                // thing Perch ever shows and it arrived as one undifferentiated block of
                // mono — headings, bullets and code spans all looking like prose, which is
                // the state in which nobody reads it and everybody approves it.
                Text(styledPlan)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 4)
            }
            // Three times what it was. The card is sized for its content — see
            // `AppModel.extraHeight` — and a plan is the one payload worth spending the
            // screen on: it is the decision with the most in it and the least room to
            // read it.
            .frame(maxHeight: 420)
            .scrollIndicators(.automatic)

            TextField(t("Tell Claude what to change…"), text: $feedback)
                .textFieldStyle(.plain)
                .font(Theme.mono(10))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(Theme.raised.opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 1)
                )

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                SmallButton(
                    title: feedback.isEmpty ? t("Reject") : t("Send feedback"),
                    tint: Theme.warning
                ) {
                    reject(feedback)
                }
                SmallButton(title: t("Approve"), tint: Theme.active, action: approve)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shared button shape for the answer cards.
struct SmallButton: View {
    let title: String
    let tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.label(11, .medium))
                .foregroundStyle(tint ?? Theme.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill((tint ?? Color.white).opacity(0.14))
                )
        }
        .buttonStyle(.plain)
    }
}
