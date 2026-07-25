import CryptoKit
import Foundation

/// Update checking.
///
/// An update feed is the most dangerous thing an app fetches: whoever can answer it can
/// run code on every machine that installed you. So the version is compared *after* the
/// enclosure's Ed25519 signature is verified against a key baked into the bundle — an
/// unsigned or wrongly-signed item is not "an update we could not verify", it is not an
/// update at all.
///
/// Same signing scheme as Sparkle, so a feed produced for one works with the other.
public struct AppcastItem: Sendable, Equatable {
    public var version: String
    public var url: URL
    public var length: Int
    public var signature: String
    public var title: String?

    public init(
        version: String, url: URL, length: Int, signature: String, title: String? = nil
    ) {
        self.version = version
        self.url = url
        self.length = length
        self.signature = signature
        self.title = title
    }
}

public enum Appcast {
    /// Parses the subset of the Sparkle feed that matters. A hand-rolled scan rather than
    /// an XML parser: the shape is fixed, and nothing here is trusted before its signature
    /// is checked anyway.
    public static func parse(_ xml: String) -> [AppcastItem] {
        var items: [AppcastItem] = []

        for chunk in xml.components(separatedBy: "<item>").dropFirst() {
            let body = chunk.components(separatedBy: "</item>").first ?? chunk
            guard let url = attribute("url", in: body),
                let target = URL(string: url),
                let signature = attribute("sparkle:edSignature", in: body),
                let version = attribute("sparkle:version", in: body)
                    ?? element("sparkle:version", in: body)
            else { continue }

            items.append(
                AppcastItem(
                    version: version,
                    url: target,
                    length: attribute("length", in: body).flatMap(Int.init) ?? 0,
                    signature: signature,
                    title: element("title", in: body)))
        }
        return items
    }

    static func attribute(_ name: String, in text: String) -> String? {
        guard let range = text.range(of: "\(name)=\"") else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    static func element(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
            let close = text.range(of: "</\(name)>"),
            open.upperBound <= close.lowerBound
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Verifies an enclosure against the public key from the bundle.
    ///
    /// Returns false on anything unexpected — a malformed key, a malformed signature, the
    /// wrong length. There is no "probably fine" branch.
    public static func verify(data: Data, signature: String, publicKey: String) -> Bool {
        guard let keyBytes = Data(base64Encoded: publicKey),
            let signatureBytes = Data(base64Encoded: signature),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
        else { return false }
        return key.isValidSignature(signatureBytes, for: data)
    }

    /// Compares dotted version strings numerically: `0.10.0` is newer than `0.9.0`, which
    /// a string comparison gets backwards.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let right = current.split(separator: ".").map { Int($0) ?? 0 }

        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// The newest item in the feed that is actually newer than what is running.
    public static func update(in items: [AppcastItem], current: String) -> AppcastItem? {
        items
            .filter { isNewer($0.version, than: current) }
            .max { isNewer($1.version, than: $0.version) }
    }
}
