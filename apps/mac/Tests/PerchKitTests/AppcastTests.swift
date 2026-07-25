import CryptoKit
import Foundation
import Testing

@testable import PerchKit

/// Exactly what `release.sh` writes, so the producer and the consumer are pinned to the
/// same shape rather than to two people's memories of it.
private let feed = """
    <rss><channel>
    <item>
      <title>0.2.0</title>
      <sparkle:version>0.2.0</sparkle:version>
      <enclosure url="https://dl.example.com/Perch-0.2.0.dmg"
                 length="1577687"
                 type="application/octet-stream"
                 sparkle:edSignature="AAAA" />
    </item>
    <item>
      <title>0.1.0</title>
      <sparkle:version>0.1.0</sparkle:version>
      <enclosure url="https://dl.example.com/Perch-0.1.0.dmg"
                 length="100" type="application/octet-stream" sparkle:edSignature="BBBB" />
    </item>
    </channel></rss>
    """

@Test func parsesTheFeedReleaseScriptProduces() throws {
    let items = Appcast.parse(feed)

    #expect(items.count == 2)
    #expect(items[0].version == "0.2.0")
    #expect(items[0].url.absoluteString == "https://dl.example.com/Perch-0.2.0.dmg")
    #expect(items[0].length == 1_577_687)
    #expect(items[0].signature == "AAAA")
}

/// A string comparison gets this backwards, and shipping 0.9.0 over 0.10.0 is the kind of
/// bug that only appears once you have shipped ten times.
@Test func versionsAreComparedNumerically() {
    #expect(Appcast.isNewer("0.10.0", than: "0.9.0"))
    #expect(!Appcast.isNewer("0.9.0", than: "0.10.0"))
    #expect(Appcast.isNewer("1.0.0", than: "0.99.99"))
    #expect(!Appcast.isNewer("0.1.0", than: "0.1.0"))
    // Shorter versions are padded, not treated as different.
    #expect(!Appcast.isNewer("1.0", than: "1.0.0"))
    #expect(Appcast.isNewer("1.0.1", than: "1.0"))
}

@Test func theNewestItemWins() throws {
    let items = Appcast.parse(feed)
    #expect(Appcast.update(in: items, current: "0.1.0")?.version == "0.2.0")
    #expect(Appcast.update(in: items, current: "0.2.0") == nil)
    #expect(Appcast.update(in: items, current: "1.0.0") == nil)
}

/// Whoever can answer the update feed can run code on every machine that installed you.
/// There is no "probably fine" branch here.
@Test func signaturesAreVerifiedAgainstTheBundledKey() throws {
    let priv = Curve25519.Signing.PrivateKey()
    let publicKey = priv.publicKey.rawRepresentation.base64EncodedString()
    let payload = Data("pretend this is a DMG".utf8)
    let signature = try priv.signature(for: payload).base64EncodedString()

    #expect(Appcast.verify(data: payload, signature: signature, publicKey: publicKey))

    // A different build, signed with the right key, must not pass for this one.
    #expect(
        !Appcast.verify(
            data: Data("a different DMG".utf8), signature: signature, publicKey: publicKey))

    // Someone else's key must not pass either.
    let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        .base64EncodedString()
    #expect(!Appcast.verify(data: payload, signature: signature, publicKey: other))
}

/// Malformed input is rejected, not tolerated.
@Test func garbageNeverVerifies() {
    #expect(!Appcast.verify(data: Data(), signature: "not base64!", publicKey: "also not"))
    #expect(!Appcast.verify(data: Data(), signature: "AAAA", publicKey: "AAAA"))
    #expect(Appcast.parse("<rss></rss>").isEmpty)
    // An item missing its signature is dropped rather than treated as unsigned-but-fine.
    #expect(Appcast.parse("<item><enclosure url=\"https://x/y.dmg\" /></item>").isEmpty)
}
