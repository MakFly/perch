import Foundation

/// Talking to whoever sells the licences.
///
/// Behind a protocol because the vendor is a business decision, not an architectural one:
/// LemonSqueezy is the default because it is what this category uses, and swapping it is
/// one conformance rather than a rewrite.
public protocol LicenseVendor: Sendable {
    func activate(key: String, deviceName: String) async throws -> LicenseActivation
    func validate(key: String, instanceId: String) async throws -> LicenseActivation
    func deactivate(key: String, instanceId: String) async throws
}

public struct LicenseActivation: Sendable, Equatable {
    public var instanceId: String
    public var seats: Int

    public init(instanceId: String, seats: Int) {
        self.instanceId = instanceId
        self.seats = seats
    }
}

public enum LicenseError: LocalizedError, Equatable {
    case invalidKey
    case seatsExhausted(used: Int, total: Int)
    case network
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .invalidKey: return "That licence key was not recognised"
        case .seatsExhausted(let used, let total):
            return "All \(used) of \(total) activations are in use — deactivate another Mac first"
        case .network: return "Could not reach the licence server"
        case .server(let message): return message
        }
    }
}

/// LemonSqueezy's licence API.
///
/// The endpoints are plain form posts and need no secret in the app — the key *is* the
/// credential. That matters: an API token shipped inside a Mac app is a token you have
/// published.
public struct LemonSqueezyVendor: LicenseVendor {
    public var storeURL: URL
    public var productId: String?
    public var session: URLSession

    public init(
        storeURL: URL = URL(string: "https://api.lemonsqueezy.com/v1/licenses")!,
        productId: String? = nil,
        session: URLSession = .shared
    ) {
        self.storeURL = storeURL
        self.productId = productId
        self.session = session
    }

    public func activate(key: String, deviceName: String) async throws -> LicenseActivation {
        let json = try await post(
            "activate", ["license_key": key, "instance_name": deviceName])
        guard let instance = json["instance"] as? [String: Any],
            let id = instance["id"] as? String
        else { throw LicenseError.server("Activation succeeded but returned no instance") }
        return LicenseActivation(instanceId: id, seats: seats(from: json))
    }

    public func validate(key: String, instanceId: String) async throws -> LicenseActivation {
        let json = try await post(
            "validate", ["license_key": key, "instance_id": instanceId])
        return LicenseActivation(instanceId: instanceId, seats: seats(from: json))
    }

    public func deactivate(key: String, instanceId: String) async throws {
        _ = try await post("deactivate", ["license_key": key, "instance_id": instanceId])
    }

    private func seats(from json: [String: Any]) -> Int {
        guard let meta = json["meta"] as? [String: Any] else { return 1 }
        return meta["activation_limit"] as? Int ?? 1
    }

    private func post(_ path: String, _ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: storeURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // A slow licence server must not hang the settings window.
        request.timeoutInterval = 15

        var body = fields
        if let productId { body["product_id"] = productId }
        request.httpBody =
            body
            .map { "\($0.key)=\(Self.escape($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw LicenseError.network
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LicenseError.server("The licence server sent something unreadable")
        }

        // LemonSqueezy answers 200 with `activated: false` and an error string rather than
        // a status code, so the body is what has to be read.
        if let error = json["error"] as? String {
            if error.localizedCaseInsensitiveContains("activation limit") {
                let meta = json["meta"] as? [String: Any]
                throw LicenseError.seatsExhausted(
                    used: meta?["activation_usage"] as? Int ?? 0,
                    total: meta?["activation_limit"] as? Int ?? 0)
            }
            if error.localizedCaseInsensitiveContains("not found")
                || error.localizedCaseInsensitiveContains("invalid")
            {
                throw LicenseError.invalidKey
            }
            throw LicenseError.server(error)
        }

        return json
    }

    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}
