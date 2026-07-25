import Foundation

/// The `AskUserQuestion` tool, as a thing the notch can answer.
///
/// Claude Code asks these constantly — pick a library, pick an approach — and until now
/// Perch could only approve or deny the *asking*, which is useless: the point of the tool
/// is the answer. It arrives as a permission request whose `tool_input` holds the
/// questions, and the answer travels back inside the decision's `updatedInput`.
public struct AskQuestion: Sendable, Equatable, Identifiable {
    public struct Option: Sendable, Equatable, Identifiable {
        public var label: String
        public var description: String
        public var id: String { label }
    }

    /// The question text is the key answers are recorded under, so it is the identity.
    public var id: String { question }
    public var question: String
    public var header: String
    public var multiSelect: Bool
    public var options: [Option]
}

public struct AskUserQuestionRequest: Sendable, Equatable {
    public var questions: [AskQuestion]

    /// Nil for anything that is not this tool, or whose input we cannot make sense of —
    /// in which case the ordinary permission card is still shown and nothing is lost.
    public static func parse(_ toolInput: JSONValue?) -> AskUserQuestionRequest? {
        guard let toolInput, case .array(let raw)? = toolInput["questions"] else { return nil }

        let questions: [AskQuestion] = raw.compactMap { entry in
            guard let question = entry["question"]?.stringValue, !question.isEmpty else {
                return nil
            }
            var options: [AskQuestion.Option] = []
            if case .array(let rawOptions)? = entry["options"] {
                options = rawOptions.compactMap { option in
                    guard let label = option["label"]?.stringValue else { return nil }
                    return AskQuestion.Option(
                        label: label,
                        description: option["description"]?.stringValue ?? "")
                }
            }
            var multiSelect = false
            if case .bool(let value)? = entry["multiSelect"] { multiSelect = value }

            return AskQuestion(
                question: question,
                header: entry["header"]?.stringValue ?? "",
                multiSelect: multiSelect,
                options: options)
        }

        return questions.isEmpty ? nil : AskUserQuestionRequest(questions: questions)
    }

    /// The `updatedInput` to send back: the original input with an `answers` map added.
    ///
    /// Keys are the question text and values are the chosen labels — comma-separated when
    /// several were picked, which is the encoding Claude Code expects.
    public func updatedInput(
        original: JSONValue?,
        answers: [String: [String]]
    ) -> JSONValue {
        var root: [String: JSONValue]
        if case .object(let existing)? = original { root = existing } else { root = [:] }

        var encoded: [String: JSONValue] = [:]
        for question in questions {
            guard let chosen = answers[question.question], !chosen.isEmpty else { continue }
            encoded[question.question] = .string(chosen.joined(separator: ", "))
        }
        root["answers"] = .object(encoded)
        return .object(root)
    }

    /// Every question must be answered before the panel can submit — a partial answer
    /// would leave Claude Code guessing.
    public func isComplete(_ answers: [String: [String]]) -> Bool {
        questions.allSatisfy { !(answers[$0.question] ?? []).isEmpty }
    }
}

/// `ExitPlanMode`: approve the plan, or send back what to change.
public struct PlanApprovalRequest: Sendable, Equatable {
    public var plan: String

    public static func parse(_ toolInput: JSONValue?) -> PlanApprovalRequest? {
        guard let plan = toolInput?["plan"]?.stringValue, !plan.isEmpty else { return nil }
        return PlanApprovalRequest(plan: plan)
    }
}

/// What kind of card the notch should show for a pending request.
public enum RequestKind: Sendable, Equatable {
    case permission
    case question(AskUserQuestionRequest)
    case plan(PlanApprovalRequest)

    public static func of(_ request: PerchRequest) -> RequestKind {
        switch request.payload.toolName {
        case "AskUserQuestion":
            if let parsed = AskUserQuestionRequest.parse(request.payload.toolInput) {
                return .question(parsed)
            }
        case "ExitPlanMode":
            if let parsed = PlanApprovalRequest.parse(request.payload.toolInput) {
                return .plan(parsed)
            }
        default:
            break
        }
        return .permission
    }
}
