import Foundation
import PerchKit
import Security

/// Reads the plan quota from Anthropic directly, using the credential Claude Code already
/// holds in the login Keychain.
///
/// Three rules, because this is the one place Perch touches a secret:
///
/// - **Nothing is stored.** The token is read, used for one request, and dropped. It is
///   never written to `~/.perch`, never logged, and never included in a diagnostic report.
/// - **Nothing is sent anywhere else.** The only destination is `api.anthropic.com`, over
///   the URL compiled into `QuotaEndpoint`.
/// - **It never happens by itself.** The setting is off until switched on, and macOS asks
///   before the first read regardless — which is the right number of parties consenting.
enum DirectQuota {
    struct Outcome {
        var limits: RateLimits?
        /// One line for the CLI, the settings pane and the diagnostic report. Never
        /// carries anything from the credential.
        var summary: String
    }

    /// The service name Claude Code stores its OAuth credential under.
    static let keychainService = "Claude Code-credentials"

    static func fetch() async -> Outcome {
        // The Keychain call blocks while macOS asks the user, so it stays off the main
        // actor — a permission dialog should not also freeze the notch.
        let credential = await Task.detached(priority: .userInitiated) { readCredential() }.value

        switch credential {
        case .problem(let reason):
            return Outcome(limits: nil, summary: reason)
        case .token(let token):
            return await request(token: token)
        }
    }

    private static func request(token: String) async -> Outcome {
        let request = QuotaEndpoint.request(token: token)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return Outcome(limits: nil, summary: "could not reach api.anthropic.com")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // 401 is the interesting one: the credential is there but the endpoint refused
            // it, which is a different problem from not having one.
            let detail = status == 401 ? " — the credential was refused" : ""
            return Outcome(limits: nil, summary: "HTTP \(status)\(detail)")
        }

        guard let limits = QuotaEndpoint.parse(data) else {
            // The shape changed, or something in the middle answered instead. Saying what
            // came back is the difference between a bug report and a shrug.
            return Outcome(
                limits: nil,
                summary: "unreadable response: \(QuotaEndpoint.describe(unreadable: data))")
        }

        let count = limits.windows.count
        return Outcome(
            limits: limits,
            summary: limits.available == false
                ? "no plan limits on this account" : "\(count) window(s) read")
    }

    // MARK: - Keychain

    /// Not a `Result`: every failure here is a sentence for the user rather than an error
    /// to propagate, and wrapping a string in an `Error` to satisfy a generic is ceremony.
    private enum Credential {
        case token(String)
        case problem(String)
    }

    private static func readCredential() -> Credential {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return .problem("no Claude Code credential in the Keychain — sign in to Claude Code")
        case errSecUserCanceled:
            return .problem("Keychain access was declined")
        default:
            return .problem("Keychain returned \(status)")
        }

        guard let data = item as? Data else {
            return .problem("the Keychain item was not readable")
        }

        return token(from: data)
    }

    /// The item is a JSON blob, not a bare token. Only the access token and its expiry are
    /// read out of it; the refresh token is deliberately left alone, because Perch has no
    /// business being able to mint new credentials.
    private static func token(from data: Data) -> Credential {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .problem("the credential was not JSON")
        }

        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return .problem("the credential had no access token")
        }

        // Milliseconds, as JavaScript writes them. An expired token would come back as a
        // 401, but saying so plainly beats making someone read an HTTP status.
        if let expiresAt = oauth["expiresAt"] as? Double {
            let expiry = Date(timeIntervalSince1970: expiresAt / 1_000)
            if expiry < .now {
                return .problem("the Claude Code credential expired — open Claude Code once")
            }
        }

        return .token(token)
    }
}
