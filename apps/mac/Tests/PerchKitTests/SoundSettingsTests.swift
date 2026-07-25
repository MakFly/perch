import Foundation
import Testing

@testable import PerchKit

/// The settings file stays readable and hand-editable, so the tagged-string encoding is
/// part of the contract rather than an implementation detail.
@Test func soundSourcesEncodeAsReadableStrings() throws {
    func encoded(_ source: SoundSource) throws -> String {
        String(data: try SoundSettings.encoder.encode(source), encoding: .utf8)!
    }

    #expect(try encoded(.off) == "\"off\"")
    #expect(try encoded(.system("Glass")) == "\"system:Glass\"")
    // Not `file:\/tmp\/ping.aiff`: a default JSONEncoder escapes every slash, which is
    // valid JSON and unreadable in a file meant to be edited by hand.
    #expect(try encoded(.file("/tmp/ping.aiff")) == "\"file:/tmp/ping.aiff\"")
}

@Test func theSavedFileIsReadableByAHuman() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("perch-sounds-\(UUID().uuidString).json")
    var settings = SoundSettings()
    settings.setSource(.file("/Users/you/ping.aiff"), for: .taskComplete)
    settings.save(to: url)

    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("file:/Users/you/ping.aiff"))
    #expect(!text.contains("\\/"))

    try? FileManager.default.removeItem(at: url)
}

@Test func soundSourcesRoundTrip() throws {
    for source in [SoundSource.off, .system("Glass"), .file("/tmp/a b.aiff")] {
        let data = try JSONEncoder().encode(source)
        #expect(try JSONDecoder().decode(SoundSource.self, from: data) == source)
    }
}

/// Anything unrecognised is silence, not a crash and not a guess.
@Test func anUnknownSourceDecodesToOff() throws {
    let data = "\"something-else\"".data(using: .utf8)!
    #expect(try JSONDecoder().decode(SoundSource.self, from: data) == .off)
}

/// A chime for every finished turn is how an app gets muted for good.
@Test func theNoisyEventsStartSilent() {
    let settings = SoundSettings()
    #expect(settings.source(for: .taskComplete) == .off)
    #expect(settings.source(for: .sessionStart) == .off)
    #expect(settings.source(for: .idleReminder) == .off)
    #expect(settings.source(for: .approvalNeeded) != .off)
    #expect(settings.source(for: .taskError) != .off)
}

@Test func everyEventHasASource() {
    let settings = SoundSettings()
    for kind in InterruptionKind.allCases {
        #expect(settings.sources[kind.rawValue] != nil, "\(kind.rawValue) has no default")
    }
}

/// A volume outside 0…1 is silently ignored by AppKit, which looks like sound is broken.
@Test func volumeIsClamped() {
    var settings = SoundSettings()
    settings.volume = 4
    #expect(settings.sanitised.volume == 1)
    settings.volume = -1
    #expect(settings.sanitised.volume == 0)
}

/// An event added by a later version must appear rather than being silently off.
@Test func loadingFillsInEventsAddedSinceTheFileWasWritten() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("perch-sounds-\(UUID().uuidString).json")
    let partial = SoundSettings(
        enabled: false, volume: 0.3,
        sources: [InterruptionKind.approvalNeeded.rawValue: .system("Ping")])
    partial.save(to: url)

    let loaded = SoundSettings.load(from: url)
    #expect(!loaded.enabled)
    #expect(loaded.volume == 0.3)
    #expect(loaded.source(for: .approvalNeeded) == .system("Ping"))
    #expect(loaded.source(for: .taskError) == SoundSettings.defaults["taskError"])

    try? FileManager.default.removeItem(at: url)
}

private func pack(_ manifest: String, files: [String]) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("perch-pack-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? manifest.write(
        to: dir.appendingPathComponent("pack.json"), atomically: true, encoding: .utf8)
    for file in files {
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent(file).path, contents: Data("x".utf8))
    }
    return dir
}

@Test func packsAreReadFromTheirManifest() throws {
    let dir = pack(
        #"{"name":"Arcade","author":"you","sounds":{"approvalNeeded":"coin.aiff"}}"#,
        files: ["coin.aiff"])
    let loaded = try #require(SoundPack.load(from: dir))

    #expect(loaded.name == "Arcade")
    #expect(loaded.author == "you")
    #expect(loaded.sounds == ["approvalNeeded": "coin.aiff"])
    try? FileManager.default.removeItem(at: dir)
}

/// A manifest may name a file that is not there. Those entries would become silent sources
/// that look configured, which is worse than not importing the pack.
@Test func entriesNamingAMissingFileAreDropped() throws {
    let dir = pack(
        #"{"name":"Half","sounds":{"approvalNeeded":"here.aiff","taskError":"gone.aiff"}}"#,
        files: ["here.aiff"])
    let loaded = try #require(SoundPack.load(from: dir))

    #expect(loaded.sounds == ["approvalNeeded": "here.aiff"])
    try? FileManager.default.removeItem(at: dir)
}

@Test func aFolderThatIsNotAPackIsRejected() {
    let empty = pack(#"{"name":"Empty","sounds":{}}"#, files: [])
    #expect(SoundPack.load(from: empty) == nil)

    let allMissing = pack(#"{"sounds":{"taskError":"gone.aiff"}}"#, files: [])
    #expect(SoundPack.load(from: allMissing) == nil)

    #expect(SoundPack.load(from: URL(fileURLWithPath: "/nonexistent")) == nil)
    try? FileManager.default.removeItem(at: empty)
    try? FileManager.default.removeItem(at: allMissing)
}

/// A pack that defines two sounds must not silence the other eight.
@Test func applyingAPackLeavesUncoveredEventsAlone() throws {
    let dir = pack(
        #"{"name":"Arcade","sounds":{"approvalNeeded":"coin.aiff","bogusEvent":"x.aiff"}}"#,
        files: ["coin.aiff", "x.aiff"])
    let loaded = try #require(SoundPack.load(from: dir))

    var settings = SoundSettings()
    let before = settings.source(for: .taskError)
    settings.apply(loaded)

    #expect(settings.source(for: .approvalNeeded) == .file(dir.appendingPathComponent("coin.aiff").path))
    #expect(settings.source(for: .taskError) == before)
    // An event name the manifest invented is ignored rather than stored.
    #expect(settings.sources["bogusEvent"] == nil)
    try? FileManager.default.removeItem(at: dir)
}

@Test func aMissingFileGivesTheDefaults() {
    let settings = SoundSettings.load(from: URL(fileURLWithPath: "/nonexistent/sounds.json"))
    #expect(settings.enabled)
    #expect(settings.source(for: .approvalNeeded) == .system("Submarine"))
}
