import Foundation
import Testing

@testable import PerchKit

@Suite("Leaderboard")
struct LeaderboardTests {

    // MARK: - Handles

    @Test("a display name becomes a handle the server will accept")
    func normalisesHandles() {
        #expect(Leaderboard.normalise(handle: "Jean Dupont") == "jean-dupont")
        #expect(Leaderboard.normalise(handle: "Élodie") == "elodie")
        #expect(Leaderboard.normalise(handle: "  spaced  out  ") == "spaced-out")
        #expect(Leaderboard.normalise(handle: "a//b") == "a-b")
    }

    @Test("a handle that would change the meaning of a URL is refused")
    func rejectsPathTraversal() {
        #expect(!Leaderboard.isValid(handle: "../admin"))
        #expect(!Leaderboard.isValid(handle: "a/b"))
        #expect(!Leaderboard.isValid(handle: "x"))
        #expect(!Leaderboard.isValid(handle: "-leading"))
        #expect(Leaderboard.isValid(handle: "kevin_2"))
    }

    // MARK: - What gets published

    /// The property that keeps a total honest: a day's focus and its session count belong
    /// to the day, not to each model used in it.
    @Test("a day's focus and sessions are carried once, not once per model")
    func dayTotalsAreNotRepeatedPerModel() {
        let payload = Leaderboard.payload(
            models: [
                .init(
                    day: "2026-07-27", model: "Sonnet 5", inputTokens: 10, outputTokens: 100,
                    cacheReadTokens: 0, cacheWriteTokens: 0, cost: 1),
                .init(
                    day: "2026-07-27", model: "Opus 5", inputTokens: 20, outputTokens: 900,
                    cacheReadTokens: 0, cacheWriteTokens: 0, cost: 9),
            ],
            activity: [.init(day: "2026-07-27", focusSeconds: 3600, sessions: 2)])

        #expect(payload.days.count == 2)
        #expect(payload.days.map(\.focusSeconds).reduce(0, +) == 3600)
        #expect(payload.days.map(\.sessions).reduce(0, +) == 2)

        // …and they land on the model that produced most of the day's output.
        let carrier = payload.days.first { $0.focusSeconds > 0 }
        #expect(carrier?.model == "Opus 5")
    }

    @Test("a day with no recorded activity still publishes its model counters")
    func missingActivityIsZeroNotDropped() {
        let payload = Leaderboard.payload(
            models: [
                .init(
                    day: "2026-07-27", model: "Opus 5", inputTokens: 1, outputTokens: 2,
                    cacheReadTokens: 3, cacheWriteTokens: 4, cost: 0.5)
            ],
            activity: [])

        #expect(payload.days.count == 1)
        #expect(payload.days[0].outputTokens == 2)
        #expect(payload.days[0].focusSeconds == 0)
    }

    @Test("days come out in order, so a truncated publish drops the oldest")
    func daysAreOrdered() {
        let payload = Leaderboard.payload(
            models: [
                .init(
                    day: "2026-07-29", model: "Opus 5", inputTokens: 0, outputTokens: 1,
                    cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0),
                .init(
                    day: "2026-07-27", model: "Opus 5", inputTokens: 0, outputTokens: 1,
                    cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0),
            ],
            activity: [])
        #expect(payload.days.map(\.day) == ["2026-07-27", "2026-07-29"])
    }

    /// The privacy claim in the README, held up by the type system rather than by care:
    /// encode a payload and there is nothing in the bytes that could identify a project.
    @Test("nothing but counters is encoded")
    func payloadCarriesNoIdentifyingFields() throws {
        let payload = Leaderboard.payload(
            models: [
                .init(
                    day: "2026-07-27", model: "Opus 5", inputTokens: 1, outputTokens: 2,
                    cacheReadTokens: 3, cacheWriteTokens: 4, cost: 0.5)
            ],
            activity: [.init(day: "2026-07-27", focusSeconds: 60, sessions: 1)])

        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(payload)) as? [String: Any]
        let day = (json?["days"] as? [[String: Any]])?.first
        #expect(
            Set((day ?? [:]).keys) == [
                "day", "model", "inputTokens", "outputTokens", "cacheReadTokens",
                "cacheWriteTokens", "costUsd", "focusSeconds", "sessions",
            ])
    }

    // MARK: - Requests

    @Test("the board request asks for the agents view and names the reader")
    func boardRequestIsShaped() throws {
        let client = LeaderboardClient(baseURL: URL(string: "https://example.test")!)
        let url = try #require(client.boardRequest(offset: 2, you: "kevin").url)
        #expect(url.path == "/v1/leaderboard")
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "board", value: "agents")))
        #expect(query.contains(URLQueryItem(name: "offset", value: "2")))
        #expect(query.contains(URLQueryItem(name: "you", value: "kevin")))
    }

    @Test("publishing carries the token as a bearer and nothing else")
    func publishRequestIsAuthorised() {
        let client = LeaderboardClient(baseURL: URL(string: "https://example.test")!)
        let request = client.publishRequest(
            token: "perch_abc", payload: Leaderboard.PublishPayload(days: []))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer perch_abc")
    }

    @Test("the server's own words survive a failure, because a status code explains nothing")
    func failureMessageComesFromTheServer() {
        let body = Data(#"{"error":"handle \"kevin\" is already taken"}"#.utf8)
        #expect(LeaderboardClient.message(from: body, status: 409).contains("already taken"))
        #expect(LeaderboardClient.message(from: Data(), status: 500) == "The leaderboard answered 500.")
        // With a host, the message says which one — a 404 from a broken deployment and a
        // 404 from a client pointed at a domain that never existed read identically
        // otherwise, and their fixes are opposite.
        #expect(
            LeaderboardClient.message(from: Data(), status: 404, host: "example.test")
                == "example.test answered 404.")
    }

    /// The default has to be the deployed host, not a placeholder.
    ///
    /// It was a placeholder for a while and the failure was silent: everything worked while
    /// the environment variable was passed by hand, and launching the app the way anyone
    /// actually launches it answered 404 against a domain that had never existed.
    @Test("the client points somewhere real without being told where")
    func defaultsAreDeployedHosts() {
        for url in [LeaderboardClient.defaultBaseURL, LeaderboardClient.defaultSiteURL] {
            #expect(url.scheme == "https")
            let host = url.host ?? ""
            #expect(!host.isEmpty)
            #expect(host != "perch-leaderboard.vercel.app", "still the invented placeholder")
        }
    }

    // MARK: - Decoding

    @Test("a board decodes, and says when its numbers are generated")
    func decodesBoard() throws {
        let json = """
            {
              "mode": "demo",
              "board": "agents",
              "period": {"kind":"week","start":"2026-07-27","end":"2026-08-02",
                         "label":"27 juil. – 2 août","offset":0},
              "rows": [{"rank":1,"handle":"vega","displayName":"Vega","team":"Nimbus",
                        "agent":"claude","model":"Opus 5","outputTokens":8400000,
                        "totalTokens":90000000,"costUsd":211.4,"focusSeconds":39600,
                        "sessions":2}],
              "guilds": [],
              "you": null,
              "totals": {"builders":1,"outputTokens":8400000,"costUsd":211.4}
            }
            """
        let board = try LeaderboardClient.decode(Leaderboard.Board.self, from: Data(json.utf8))
        #expect(board.isDemo)
        #expect(board.period.label == "27 juil. – 2 août")
        #expect(board.rows.first?.handle == "vega")
        #expect(board.you == nil)
    }

    // MARK: - Identity on disk

    @Test("the identity file is written where only its owner can read it")
    func identityIsPrivate() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("perch-leaderboard-\(UUID().uuidString).json")
        defer { Leaderboard.Identity.remove(at: url) }

        let identity = Leaderboard.Identity(
            handle: "kevin", token: "perch_secret", displayName: "Kevin", team: "Nimbus")
        identity.save(to: url)

        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        #expect(mode as? NSNumber == 0o600)
        #expect(Leaderboard.Identity.load(from: url) == identity)
    }

    @Test("a missing identity is nil rather than a default one that could publish")
    func missingIdentityIsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("perch-absent-\(UUID().uuidString).json")
        #expect(Leaderboard.Identity.load(from: url) == nil)
    }
}

@Suite("Model names")
struct ModelNameTests {
    @Test(
        "an id becomes something a person reads",
        arguments: [
            ("claude-opus-5", "Opus 5"),
            ("claude-opus-4-8", "Opus 4.8"),
            ("claude-haiku-4-5-20251001", "Haiku 4.5"),
            ("claude-sonnet-5", "Sonnet 5"),
            ("claude-fable-5", "Fable 5"),
            // The older ordering, where the version came first.
            ("claude-3-5-sonnet-20241022", "Sonnet 3.5"),
            ("claude-sonnet-4-latest", "Sonnet 4"),
        ])
    func displaysKnownIds(pair: (String, String)) {
        #expect(ModelName.display(pair.0) == pair.1)
    }

    @Test("an id from somewhere else is left alone rather than mangled into a guess")
    func leavesForeignIdsIntact() {
        #expect(ModelName.display("gpt-5.1-codex") == "gpt-5.1-codex")
        #expect(ModelName.display("gemini-3-pro") == "gemini-3-pro")
        #expect(ModelName.display("") == "")
    }
}

@Suite("Publishing model names")
struct PublishModelNameTests {
    /// The server upserts on `(builder, day, model)`. Two ids that collapse onto one
    /// display name therefore have to be summed *before* they are sent — emitted as two
    /// rows, the second would replace the first and the day would lose half its tokens.
    @Test("ids that share a display name are merged, not sent twice")
    func mergesIdsThatShareADisplayName() {
        let payload = Leaderboard.payload(
            models: [
                .init(
                    day: "2026-07-27", model: "claude-haiku-4-5", inputTokens: 1,
                    outputTokens: 10, cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0.1),
                .init(
                    day: "2026-07-27", model: "claude-haiku-4-5-20251001", inputTokens: 2,
                    outputTokens: 20, cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0.2),
            ],
            activity: [.init(day: "2026-07-27", focusSeconds: 60, sessions: 1)])

        #expect(payload.days.count == 1)
        #expect(payload.days[0].model == "Haiku 4.5")
        #expect(payload.days[0].outputTokens == 30)
        #expect(payload.days[0].inputTokens == 3)
        #expect(abs(payload.days[0].costUsd - 0.3) < 0.0001)
    }

    @Test("the published model is the display name, not the raw id")
    func publishesDisplayNames() {
        let payload = Leaderboard.payload(
            models: [
                .init(
                    day: "2026-07-27", model: "claude-opus-5", inputTokens: 0,
                    outputTokens: 1, cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0)
            ],
            activity: [])
        #expect(payload.days[0].model == "Opus 5")
    }
}

@Suite("Empty rows")
struct EmptyRowTests {
    /// Claude Code records `<synthetic>` for a reply it produced without a model — an
    /// interrupt, a local error. Publishing it puts a model nobody ran on the board.
    @Test("a model row with no tokens and no cost is not published")
    func dropsEmptyModelRows() {
        let payload = Leaderboard.payload(
            models: [
                .init(
                    day: "2026-07-27", model: "<synthetic>", inputTokens: 0, outputTokens: 0,
                    cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0),
                .init(
                    day: "2026-07-27", model: "claude-opus-5", inputTokens: 0, outputTokens: 5,
                    cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0.1),
            ],
            activity: [.init(day: "2026-07-27", focusSeconds: 60, sessions: 1)])

        #expect(payload.days.map(\.model) == ["Opus 5"])
        // …and the day's focus still lands, rather than being attached to the row that was
        // dropped.
        #expect(payload.days[0].focusSeconds == 60)
    }
}
