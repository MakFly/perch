import AppKit
import Foundation
import PerchKit

/// Plays the sound configured for an event.
///
/// Perch ships no audio: macOS already has a set that matches the OS, and a file you chose
/// yourself beats anything shipped. So the settings name a system sound or a path, and
/// this resolves it.
@MainActor
enum SoundPlayer {
    /// `NSSound` instances are cached: constructing one per tool call reads the file from
    /// disk every time, and two approvals arriving together should sound like one
    /// notification rather than two overlapping ones.
    private static var cache: [String: NSSound] = [:]

    static func play(_ kind: InterruptionKind, settings: SoundSettings) {
        guard settings.enabled else { return }

        let source = settings.source(for: kind)
        guard let sound = resolve(source) else { return }

        sound.volume = Float(min(max(settings.volume, 0), 1))
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    /// Also used by the preview button in Settings, so what you hear there is exactly what
    /// you will hear later.
    static func preview(_ source: SoundSource, volume: Double) {
        guard let sound = resolve(source) else { return }
        sound.volume = Float(min(max(volume, 0), 1))
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    private static func resolve(_ source: SoundSource) -> NSSound? {
        switch source {
        case .off:
            return nil
        case .system(let name):
            if let cached = cache["system:\(name)"] { return cached }
            guard let sound = NSSound(named: name) else { return nil }
            cache["system:\(name)"] = sound
            return sound
        case .file(let path):
            if let cached = cache["file:\(path)"] { return cached }
            // A file that has been moved or deleted must not throw: the sound is the least
            // important thing happening at that moment.
            guard FileManager.default.fileExists(atPath: path),
                let sound = NSSound(contentsOfFile: path, byReference: false)
            else { return nil }
            cache["file:\(path)"] = sound
            return sound
        }
    }
}
