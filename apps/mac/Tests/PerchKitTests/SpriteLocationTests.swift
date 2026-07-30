import Foundation
import Testing

@testable import PerchKit

private func makeDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("perch-sprites-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A sheet someone put in `~/.perch/sprites` is a decision; one that shipped in the bundle
/// is a default. So the installed one wins.
@Test func anInstalledSheetWinsOverTheBundledOne() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let installed = directory.appendingPathComponent("agent-claude.png")
    try Data("not really a png".utf8).write(to: installed)
    let bundled = URL(fileURLWithPath: "/Applications/Perch.app/Sprites/agent-claude.png")

    #expect(
        SpriteLocation.sheetURL(named: "agent-claude", bundled: bundled, in: directory)
            == installed)
}

/// The whole reason this exists: the DMG carries no sprites, and an update replaces the
/// bundle wholesale — so with nothing installed, whatever shipped is still used, and with
/// nothing anywhere the app draws its own pixel art.
@Test func nothingInstalledFallsBackToTheBundleAndThenToNothing() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let bundled = URL(fileURLWithPath: "/Applications/Perch.app/Sprites/agent-codex.png")
    #expect(
        SpriteLocation.sheetURL(named: "agent-codex", bundled: bundled, in: directory) == bundled)
    #expect(SpriteLocation.sheetURL(named: "agent-codex", bundled: nil, in: directory) == nil)
}

/// A directory that was never created is the normal case, not an error.
@Test func aMissingSpritesDirectoryIsNotAFailure() {
    let absent = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("perch-absent-\(UUID().uuidString)")
    #expect(SpriteLocation.sheetURL(named: "agent-gemini", bundled: nil, in: absent) == nil)
}
