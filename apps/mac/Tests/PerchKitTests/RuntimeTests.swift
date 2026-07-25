import Darwin
import Foundation
import Testing

@testable import PerchKit

@Test func tokensAreUniqueAndLongEnough() {
    let tokens = (0..<64).map { _ in RuntimeInfo.newToken() }
    #expect(Set(tokens).count == tokens.count)
    #expect(tokens.allSatisfy { $0.count == 64 })
}

/// A response without the right token must never be treated as a decision — that is
/// what stops another local process from approving tool calls.
@Test func responseCarriesTokenForAuthentication() throws {
    let response = PerchResponse(decision: .allow, reason: nil, token: "secret")
    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(PerchResponse.self, from: data)

    #expect(decoded.token == "secret")
    #expect(decoded.decision == .allow)

    let unsigned = try JSONDecoder().decode(
        PerchResponse.self, from: Data(#"{"decision":"allow"}"#.utf8))
    #expect(unsigned.token == nil)
}

/// A crash, a force-quit, or an update that swapped the bundle underneath it all leave a
/// handshake pointing at a port nobody is listening on. Dialling it and waiting out the
/// timeout is exactly the stall the handshake exists to avoid.
@Test func aHandshakeIsOnlyValidWhileItsProcessLives() {
    let mine = RuntimeInfo(port: 1234, token: "t", pid: ProcessInfo.processInfo.processIdentifier)
    #expect(mine.isAlive)

    // PID 1 is launchd: alive, and not ours, which must still count as alive.
    #expect(RuntimeInfo(port: 1, token: "t", pid: 1).isAlive)

    // A pid far above the wrap-around point is not going to exist.
    #expect(!RuntimeInfo(port: 1, token: "t", pid: 999_999).isAlive)
    #expect(!RuntimeInfo(port: 1, token: "t", pid: 0).isAlive)
    #expect(!RuntimeInfo(port: 1, token: "t", pid: -5).isAlive)
}
