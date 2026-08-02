import Foundation
import Testing

@testable import PerchKit

private func toolInput(_ json: String) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: json.data(using: .utf8)!)
}

private let askInput = toolInput(
    """
    {"questions": [
      {"question": "Which database?", "header": "Database", "multiSelect": false,
       "options": [{"label": "Postgres", "description": "Relational"},
                   {"label": "SQLite", "description": "Embedded"}]},
      {"question": "Which features?", "header": "Features", "multiSelect": true,
       "options": [{"label": "Auth", "description": "Sign-in"},
                   {"label": "Billing", "description": "Payments"}]}
    ]}
    """)

@Test func parsesTheQuestionsAndTheirOptions() throws {
    let request = try #require(AskUserQuestionRequest.parse(askInput))

    #expect(request.questions.count == 2)
    #expect(request.questions[0].header == "Database")
    #expect(request.questions[0].multiSelect == false)
    #expect(request.questions[0].options.map(\.label) == ["Postgres", "SQLite"])
    #expect(request.questions[1].multiSelect)
}

/// Answers go back keyed by the question text, multi-select comma-separated — that is the
/// encoding Claude Code reads.
@Test func answersAreEncodedIntoTheToolInput() throws {
    let request = try #require(AskUserQuestionRequest.parse(askInput))
    let updated = request.updatedInput(
        original: askInput,
        answers: ["Which database?": ["Postgres"], "Which features?": ["Auth", "Billing"]])

    #expect(updated["answers"]?["Which database?"]?.stringValue == "Postgres")
    #expect(updated["answers"]?["Which features?"]?.stringValue == "Auth, Billing")
    // The original input has to survive: the tool still needs its questions.
    #expect(updated["questions"] != nil)
}

@Test func everyQuestionMustBeAnsweredBeforeSubmitting() throws {
    let request = try #require(AskUserQuestionRequest.parse(askInput))

    #expect(!request.isComplete([:]))
    #expect(!request.isComplete(["Which database?": ["Postgres"]]))
    #expect(!request.isComplete(["Which database?": ["Postgres"], "Which features?": []]))
    #expect(
        request.isComplete(["Which database?": ["Postgres"], "Which features?": ["Auth"]]))
}

/// Anything we cannot make sense of falls back to the ordinary permission card rather
/// than showing an empty question.
@Test func unparseableInputFallsBackToAPlainPermission() {
    #expect(AskUserQuestionRequest.parse(nil) == nil)
    #expect(AskUserQuestionRequest.parse(toolInput(#"{"questions": []}"#)) == nil)
    #expect(AskUserQuestionRequest.parse(toolInput(#"{"command": "ls"}"#)) == nil)
    #expect(AskUserQuestionRequest.parse(toolInput(#"{"questions": [{"header": "x"}]}"#)) == nil)
}

@Test func planRequestsCarryTheirPlan() {
    #expect(PlanApprovalRequest.parse(toolInput(#"{"plan": "1. do it"}"#))?.plan == "1. do it")
    #expect(PlanApprovalRequest.parse(toolInput(#"{"plan": ""}"#)) == nil)
    #expect(PlanApprovalRequest.parse(toolInput(#"{}"#)) == nil)
}

/// The plan goes back exactly as it came. Perch approves plans, it does not edit them —
/// and `updatedInput` has to be there at all, or Claude Code drops the approval.
@Test func planApprovalsSendTheInputBackUnchanged() throws {
    let original = toolInput(#"{"plan": "1. do it", "note": "keep me"}"#)
    let request = try #require(PlanApprovalRequest.parse(original))

    #expect(request.updatedInput(original: original) == original)
    // No input to echo is still an answer, not silence.
    #expect(request.updatedInput(original: nil) == toolInput(#"{"plan": "1. do it"}"#))
}

@Test func requestKindIsChosenByToolName() {
    func request(_ tool: String, _ input: JSONValue) -> PerchRequest {
        var payload = ClaudeHookPayload()
        payload.toolName = tool
        payload.toolInput = input
        return PerchRequest(
            token: "t", event: "PermissionRequest", wantsDecision: true, payload: payload)
    }

    #expect(RequestKind.of(request("AskUserQuestion", askInput)) != .permission)
    #expect(RequestKind.of(request("ExitPlanMode", toolInput(#"{"plan": "x"}"#))) != .permission)
    #expect(RequestKind.of(request("Bash", toolInput(#"{"command": "ls"}"#))) == .permission)
    // Right tool, unusable input: still answerable as a plain permission.
    #expect(RequestKind.of(request("AskUserQuestion", toolInput(#"{}"#))) == .permission)
}

/// The answer travels inside the decision, not beside it.
@Test func hookOutputCarriesUpdatedInputOnAllow() throws {
    let output = HookOutput(
        event: "PermissionRequest", decision: .allow, reason: nil,
        updatedInput: toolInput(#"{"answers": {"Which database?": "Postgres"}}"#))
    let data = try JSONEncoder().encode(output)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let body = try #require(json["hookSpecificOutput"] as? [String: Any])
    let decision = try #require(body["decision"] as? [String: Any])
    let updated = try #require(decision["updatedInput"] as? [String: Any])
    let answers = try #require(updated["answers"] as? [String: Any])

    #expect(decision["behavior"] as? String == "allow")
    #expect(answers["Which database?"] as? String == "Postgres")
}

// MARK: - Card height

/// The panel is sized from the request, one step ahead of the view that draws it. It used
/// to be a flat 44pt per option — a description of exactly two lines — and the view kept
/// that true by clipping every longer one to two. It no longer clips, so the estimate has
/// to answer to the text.
@Suite("Card height")
struct CardHeightTests {
    private func request(
        question: String = "Which database?",
        descriptions: [String]
    ) -> AskUserQuestionRequest {
        AskUserQuestionRequest(questions: [
            AskQuestion(
                question: question,
                header: "DB",
                multiSelect: false,
                options: descriptions.enumerated().map {
                    .init(label: "Option \($0.offset)", description: $0.element)
                })
        ])
    }

    private let long = String(repeating: "a reason to pick this one. ", count: 8)

    @Test("a long description is taller than a short one")
    func longerTextIsTaller() {
        let short = QuestionCard.bodyHeight(for: request(descriptions: ["Relational"]), width: 660)
        let tall = QuestionCard.bodyHeight(for: request(descriptions: [long]), width: 660)
        #expect(tall > short)
    }

    @Test("more options are taller")
    func moreOptionsIsTaller() {
        let two = QuestionCard.bodyHeight(for: request(descriptions: [long, long]), width: 660)
        let four = QuestionCard.bodyHeight(
            for: request(descriptions: [long, long, long, long]), width: 660)
        #expect(four > two)
    }

    @Test("the same request is taller in a narrower card")
    func narrowerWraps() {
        let wide = QuestionCard.bodyHeight(for: request(descriptions: [long]), width: 660)
        let narrow = QuestionCard.bodyHeight(for: request(descriptions: [long]), width: 380)
        #expect(narrow > wide)
    }

    /// A question long enough to run past the panel scrolls instead of growing — the window
    /// is a fixed canvas, and a card taller than it is a card with its buttons off screen.
    @Test("the body is capped so the card stays inside the canvas")
    func heightIsClamped() {
        let huge = request(
            descriptions: Array(repeating: String(repeating: "x", count: 4000), count: 4))
        #expect(QuestionCard.bodyHeight(for: huge, width: 660) > QuestionCard.maxBodyHeight)
        #expect(
            QuestionCard.extraHeight(for: huge, width: 660)
                <= QuestionCard.maxBodyHeight + 100)
    }

    /// The card shows one question at a time, so four of them are as tall as the tallest —
    /// not as tall as all four. A panel that resized between "3 of 4" and "4 of 4" would
    /// move the buttons out from under the cursor mid-answer.
    @Test("several questions size to the tallest, not to their sum")
    func sizesToTheTallestQuestion() {
        let one = request(descriptions: [long, long])
        let several = AskUserQuestionRequest(
            questions: one.questions + [
                AskQuestion(
                    question: "And?", header: "B", multiSelect: false,
                    options: [.init(label: "Yes", description: "")])
            ])
        #expect(
            QuestionCard.bodyHeight(for: several, width: 660)
                == QuestionCard.bodyHeight(for: one, width: 660))
    }
}

// MARK: - Free-text answers

/// Every `AskUserQuestion` implicitly offers "none of these" — Claude Code's own prompt
/// always does. Without it in the notch, the only way to say something the options do not
/// cover was to leave the notch and type in the terminal, which is what the card exists to
/// avoid.
@Suite("Typed answers")
struct TypedAnswerTests {
    private func request(multiSelect: Bool) -> AskUserQuestionRequest {
        AskUserQuestionRequest(questions: [
            AskQuestion(
                question: "Which database?",
                header: "DB",
                multiSelect: multiSelect,
                options: [
                    .init(label: "Postgres", description: ""),
                    .init(label: "SQLite", description: ""),
                ])
        ])
    }

    @Test("a typed answer replaces the picked option when only one may be chosen")
    func singleSelectReplaces() {
        let merged = request(multiSelect: false).merged(
            picked: ["Which database?": ["Postgres"]],
            typed: ["Which database?": "Neon, actually"])
        #expect(merged["Which database?"] == ["Neon, actually"])
    }

    @Test("a typed answer joins the picked ones when several may be chosen")
    func multiSelectAppends() {
        let merged = request(multiSelect: true).merged(
            picked: ["Which database?": ["Postgres"]],
            typed: ["Which database?": "and Redis"])
        #expect(merged["Which database?"] == ["Postgres", "and Redis"])
    }

    @Test("whitespace is not an answer")
    func blankTypedIsIgnored() {
        let merged = request(multiSelect: false).merged(
            picked: ["Which database?": ["Postgres"]],
            typed: ["Which database?": "   \n "])
        #expect(merged["Which database?"] == ["Postgres"])
    }

    @Test("typing alone answers the question, so submit becomes reachable")
    func typedAloneCompletes() {
        let request = request(multiSelect: false)
        #expect(!request.isComplete([:]))
        let merged = request.merged(picked: [:], typed: ["Which database?": "Neon"])
        #expect(request.isComplete(merged))
    }

    @Test("the same text is not appended twice")
    func multiSelectDoesNotDuplicate() {
        let merged = request(multiSelect: true).merged(
            picked: ["Which database?": ["Redis"]],
            typed: ["Which database?": "Redis"])
        #expect(merged["Which database?"] == ["Redis"])
    }

    @Test("a typed answer travels back in updatedInput like any other")
    func typedReachesTheWire() {
        let request = request(multiSelect: false)
        let merged = request.merged(picked: [:], typed: ["Which database?": "Neon"])
        let updated = request.updatedInput(original: nil, answers: merged)
        #expect(updated["answers"]?["Which database?"]?.stringValue == "Neon")
    }
}
