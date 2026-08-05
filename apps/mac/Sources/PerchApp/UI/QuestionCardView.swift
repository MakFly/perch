import PerchKit
import SwiftUI

/// Answering `AskUserQuestion` from the notch.
///
/// Approving the *asking* of a question is useless — the point of the tool is the answer.
/// A session is blocked while this is up, so it shows one question at a time with its
/// options, and only submits once every question has one.
struct QuestionCardView: View {
    let request: AskUserQuestionRequest
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
                // The question, its options and the answer field scroll together; the
                // header and the controls do not. The panel is sized to fit this whole
                // body — see `QuestionCard` — so the scroll is the overflow case rather
                // than the normal one, and when it does happen the buttons are still
                // where they were. A card that has to be scrolled to reach its own
                // Submit is a card nobody submits.
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(question.question)
                            .font(Theme.label(12, .semibold))
                            .foregroundStyle(Theme.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        options(for: question)
                        otherField(for: question)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 4)
                }
                .frame(maxHeight: QuestionCard.maxBodyHeight)
                .scrollIndicators(.automatic)
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
                        // Unclipped. Two lines was enough for a label and never enough for
                        // a reason, and the reason is what the option is being chosen on —
                        // an ellipsis here sends you to the terminal to read the question
                        // this card exists to answer.
                        Text(option.description)
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.secondary)
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

/// Approving a plan, or sending back what to change.
///
/// Denying with a message is not a refusal here — Claude Code reads it as feedback and
/// keeps going, which is what "tell it what to fix" means.
///
/// Approving is a choice of mode rather than a yes: that is what Claude Code's own prompt
/// asks, and one button saying "Approve" could only ever guess which one it meant.
struct PlanCardView: View {
    let request: PlanApprovalRequest
    /// What the panel is drawn at, less its padding. Code blocks are never wrapped, so the
    /// only way they can be made to fit is to be measured against this.
    var contentWidth: CGFloat = NotchState.alertWidth
    let approve: (PlanMode) -> Void
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
                Spacer(minLength: 0)
            }

            ScrollView {
                // Block by block, because a plan's structure is the plan. Passing the whole
                // document through `AttributedString(markdown:)` parsed the syntax and then
                // dropped every block boundary — a heading welded to the paragraph under it
                // and an ASCII diagram double-spaced into nonsense, which is the state in
                // which nobody reads it and everybody approves it.
                MarkdownText(request.plan, density: .reading, width: contentWidth - 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 4)
            }
            // The card is sized for its content — see `PlanCard.extraHeight` — so this cap
            // is the overflow case rather than the normal one. Shared with the sizing so
            // the two cannot disagree about where the plan stops fitting.
            .frame(maxHeight: PlanCard.maxBodyHeight)
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
                SmallButton(
                    title: feedback.isEmpty ? t("Reject") : t("Send feedback"),
                    tint: Theme.warning
                ) {
                    reject(feedback)
                }
                Spacer(minLength: 0)
                ForEach(PlanMode.allCases, id: \.self) { mode in
                    SmallButton(
                        title: t(mode.title),
                        // Bypass is the one that stops asking about anything at all, and
                        // it reads the same as the other two if it is not coloured.
                        tint: mode == .bypassPermissions ? Theme.danger : Theme.active
                    ) {
                        approve(mode)
                    }
                }
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
