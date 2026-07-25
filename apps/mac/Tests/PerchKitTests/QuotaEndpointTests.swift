import Foundation
import Testing

@testable import PerchKit

@Test func theRequestCarriesTheOauthCredentialAndNothingElse() throws {
    let request = QuotaEndpoint.request(token: "oat-secret")
    let headers = try #require(request.allHTTPHeaderFields)

    #expect(request.url == QuotaEndpoint.url)
    #expect(request.httpMethod == "GET")
    #expect(headers["Authorization"] == "Bearer oat-secret")
    // Without this the endpoint has no reason to read the bearer as an OAuth credential
    // rather than an API key.
    #expect(headers["anthropic-beta"] == "oauth-2025-04-20")
    #expect(request.httpBody == nil)
}

@Test func theEndpointReadsIntoTheSameShapeAsTheBridge() throws {
    let body = """
        {"five_hour": {"utilization": 42, "resets_at": 1700003600},
         "seven_day": {"utilization": 88, "resets_at": 1700600000}}
        """
    let limits = try #require(QuotaEndpoint.parse(Data(body.utf8)))

    #expect(limits.windows.count == 2)
    #expect(limits.fiveHour?.utilization == 42)
    #expect(limits.tightest?.id == "seven_day")
}

/// An account with no plan windows is an answer, not a failure — and it has to survive the
/// "nothing recognisable" check below, or the panel would keep offering to connect.
@Test func anAccountWithoutPlanLimitsIsStillAReading() throws {
    let limits = try #require(QuotaEndpoint.parse(Data(#"{"rate_limits_available": false}"#.utf8)))
    #expect(limits.available == false)
    #expect(limits.isEmpty)
}

/// A body that parses as JSON but says nothing is a miss, so the bridge's reading is kept
/// rather than replaced by an empty one.
@Test func anEmptyOrUnreadableBodyIsAMiss() {
    #expect(QuotaEndpoint.parse(Data("{}".utf8)) == nil)
    #expect(QuotaEndpoint.parse(Data("<html>nope</html>".utf8)) == nil)
}

/// What a failed read reports ends up in a diagnostic report people paste in public.
@Test func theDescriptionOfAnUnreadableBodyDropsAnythingTokenShaped() {
    let body = Data(
        #"{"error":"bad token sk-ant-oat01-AAAABBBBCCCCDDDDEEEEFFFF","hint":"sign in"}"#.utf8)
    let description = QuotaEndpoint.describe(unreadable: body)

    #expect(!description.contains("sk-ant"))
    #expect(!description.contains("AAAABBBB"))
    // …while the part that says what went wrong survives, which is the whole point of
    // printing anything at all.
    #expect(description.contains("sign in"))
    #expect(description.contains("error"))
}

/// Anything long and opaque goes, token-shaped or not: a bearer that changes prefix one
/// day should not become the first thing pasted into a public bug report.
@Test func longOpaqueRunsAreDroppedEvenWithoutAKnownPrefix() {
    let body = Data(#"{"credential":"QQQQWWWWEEEERRRRTTTTYYYYUUUUIIIIOOOOPPPPAAAA"}"#.utf8)
    let description = QuotaEndpoint.describe(unreadable: body)

    #expect(!description.contains("QQQQWWWW"))
    #expect(description.contains("credential"))
}

@Test func theDescriptionIsBounded() {
    let body = Data(String(repeating: "a b ", count: 5_000).utf8)
    #expect(QuotaEndpoint.describe(unreadable: body).count <= 200)
}
