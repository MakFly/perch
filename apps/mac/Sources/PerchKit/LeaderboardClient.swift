import Foundation

/// Talks to the leaderboard API.
///
/// Requests are built here and executed by the caller's `URLSession`, which is what makes
/// the shapes testable without a server: `LeaderboardTests` asserts on the request and on
/// the decoding, and nothing in this file needs the network to be exercised.
public struct LeaderboardClient: Sendable {
    /// Where the API lives. Overridable so a development build can point at
    /// `http://localhost:8787` without a rebuild of anything else.
    ///
    /// The fallback is the **deployed** host, not a placeholder. It was one for a while,
    /// and the failure that produced was quiet and total: everything worked while the
    /// environment variable was being passed by hand, and the moment the app was launched
    /// the way anyone actually launches it — by double-clicking — the rank tab answered
    /// "the leaderboard answered 404" against a domain that had never existed. A default
    /// that only works for the person who wrote it is not a default.
    public static var defaultBaseURL: URL {
        if let override = ProcessInfo.processInfo.environment["PERCH_LEADERBOARD_URL"],
            let url = URL(string: override)
        {
            return url
        }
        return URL(string: "https://perch-api-gamma.vercel.app")!
    }

    /// Where the *site* lives — which is not always where the API lives.
    ///
    /// In production they are one origin: the site is served from the root and the API
    /// from `/v1` on the same domain, so one URL does for both. In development they are
    /// two processes on two ports, and deriving the profile link from the API base sends
    /// you to `localhost:8787/u/kevin`, which the API answers with `not found` because it
    /// serves nothing but `/v1`. Found by clicking the link.
    public static var defaultSiteURL: URL {
        if let override = ProcessInfo.processInfo.environment["PERCH_LEADERBOARD_SITE"],
            let url = URL(string: override)
        {
            return url
        }
        return URL(string: "https://perch-ten-phi.vercel.app")!
    }

    public var baseURL: URL
    public var siteURL: URL
    public var session: URLSession

    public init(
        baseURL: URL = defaultBaseURL,
        siteURL: URL = defaultSiteURL,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.siteURL = siteURL
        self.session = session
    }

    /// The public page for a handle, on the site rather than on the API.
    public func profileURL(handle: String) -> URL {
        siteURL.appendingPathComponent("/u/\(handle)")
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case http(status: Int, message: String)
        case unreadable

        public var errorDescription: String? {
            switch self {
            case .http(_, let message): return message
            case .unreadable: return "The leaderboard sent something unreadable."
            }
        }
    }

    // MARK: - Requests

    public func registerRequest(
        handle: String, displayName: String, team: String?, agent: String,
        visibility: Leaderboard.Visibility
    ) -> URLRequest {
        var request = post("/v1/builders")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "handle": handle,
            "displayName": displayName,
            "team": team as Any,
            "agent": agent,
            "visibility": visibility.rawValue,
        ].compactMapValues { $0 is NSNull ? nil : $0 })
        return request
    }

    public func publishRequest(token: String, payload: Leaderboard.PublishPayload) -> URLRequest {
        var request = post("/v1/publish")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(payload)
        return request
    }

    public func boardRequest(offset: Int, you: String?) -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/v1/leaderboard"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "board", value: "agents"),
            URLQueryItem(name: "offset", value: String(max(0, offset))),
        ]
        if let you { items.append(URLQueryItem(name: "you", value: you)) }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func post(_ path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - Calls

    public func register(
        handle: String, displayName: String, team: String?, agent: String,
        visibility: Leaderboard.Visibility
    ) async throws -> Leaderboard.Registration {
        let request = registerRequest(
            handle: handle, displayName: displayName, team: team, agent: agent,
            visibility: visibility)
        return try Self.decode(Leaderboard.Registration.self, from: try await run(request))
    }

    @discardableResult
    public func publish(token: String, payload: Leaderboard.PublishPayload) async throws -> Int {
        let data = try await run(publishRequest(token: token, payload: payload))
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (object?["accepted"] as? Int) ?? 0
    }

    public func board(offset: Int = 0, you: String? = nil) async throws -> Leaderboard.Board {
        try Self.decode(Leaderboard.Board.self, from: try await run(boardRequest(offset: offset, you: you)))
    }

    private func run(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.http(
                status: status,
                message: Self.message(from: data, status: status, host: request.url?.host))
        }
        return data
    }

    // MARK: - Decoding

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard let value = try? JSONDecoder().decode(type, from: data) else {
            throw Failure.unreadable
        }
        return value
    }

    /// The server's own words when it has some, because "HTTP 409" does not tell anyone
    /// that the handle they picked is taken.
    ///
    /// When it has none, the host is named. A bare "the leaderboard answered 404" is true
    /// of a broken deployment and of a client pointed at a domain that does not exist, and
    /// those have opposite fixes — naming the host is what tells them apart without a
    /// debugger.
    static func message(from data: Data, status: Int, host: String? = nil) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? String, !error.isEmpty
        {
            return error
        }
        guard let host else { return "The leaderboard answered \(status)." }
        return "\(host) answered \(status)."
    }
}
