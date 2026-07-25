import Foundation

/// Which sound plays for which event.
///
/// Perch ships no audio of its own. macOS already has a set that matches the OS, and a
/// file you chose yourself beats anything shipped — so a source is either off, a system
/// sound by name, or a path.
public enum SoundSource: Codable, Sendable, Hashable {
    case off
    case system(String)
    case file(String)

    public var label: String {
        switch self {
        case .off: return "Off"
        case .system(let name): return name
        case .file(let path): return URL(fileURLWithPath: path).lastPathComponent
        }
    }

    // Encoded as a tagged string rather than a keyed object, so the settings file stays
    // readable and hand-editable: `"system:Glass"`, `"file:/Users/…/ping.aiff"`, `"off"`.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "off" {
            self = .off
        } else if raw.hasPrefix("system:") {
            self = .system(String(raw.dropFirst("system:".count)))
        } else if raw.hasPrefix("file:") {
            self = .file(String(raw.dropFirst("file:".count)))
        } else {
            self = .off
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .off: try container.encode("off")
        case .system(let name): try container.encode("system:\(name)")
        case .file(let path): try container.encode("file:\(path)")
        }
    }
}

public struct SoundSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var volume: Double
    public var sources: [String: SoundSource]

    /// Mute is a one-click thing from the panel, so it is a value rather than a mutation
    /// the view has to spell out.
    public var toggledEnabled: SoundSettings {
        var copy = self
        copy.enabled.toggle()
        return copy
    }

    public init(
        enabled: Bool = true,
        volume: Double = 0.6,
        sources: [String: SoundSource] = SoundSettings.defaults
    ) {
        self.enabled = enabled
        self.volume = volume
        self.sources = sources
    }

    /// Restrained on purpose: three that mean "you are needed", one that means "something
    /// broke", silence elsewhere. A chime per finished turn is how an app gets muted for
    /// good, so the noisy events start at `off` rather than at a tasteful default.
    public static let defaults: [String: SoundSource] = [
        InterruptionKind.approvalNeeded.rawValue: .system("Submarine"),
        InterruptionKind.questionAsked.rawValue: .system("Submarine"),
        InterruptionKind.taskError.rawValue: .system("Basso"),
        InterruptionKind.contextLimit.rawValue: .system("Funk"),
        InterruptionKind.usageWarning.rawValue: .system("Funk"),
        InterruptionKind.taskComplete.rawValue: .off,
        InterruptionKind.sessionStart.rawValue: .off,
        InterruptionKind.taskAcknowledge.rawValue: .off,
        InterruptionKind.idleReminder.rawValue: .off,
        InterruptionKind.usageReset.rawValue: .off,
    ]

    public func source(for kind: InterruptionKind) -> SoundSource {
        sources[kind.rawValue] ?? .off
    }

    public mutating func setSource(_ source: SoundSource, for kind: InterruptionKind) {
        sources[kind.rawValue] = source
    }

    /// Clamped, because a volume outside 0…1 is silently ignored by AppKit and looks like
    /// sound is broken.
    public var sanitised: SoundSettings {
        var copy = self
        copy.volume = min(max(volume, 0), 1)
        return copy
    }

    /// The system sounds worth offering. macOS ships more; these are the ones that read as
    /// a notification rather than as an error dialog.
    public static let systemNames = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse",
        "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]
}

/// A folder of audio files with a manifest naming which file plays for which event.
///
/// Deliberately a plain directory rather than an archive format: you can look inside one,
/// swap a file, and see the result — and Perch never has to unpack anything it was handed.
///
/// ```json
/// { "name": "Arcade", "author": "you",
///   "sounds": { "approvalNeeded": "coin.aiff", "taskError": "gameover.aiff" } }
/// ```
public struct SoundPack: Sendable, Equatable {
    public var name: String
    public var author: String?
    public var directory: URL
    /// Event key → file name inside the pack.
    public var sounds: [String: String]

    public var url: URL { directory }

    /// Nil when the folder has no manifest, or one that names nothing — importing an empty
    /// pack would silently turn sounds off.
    public static func load(from directory: URL) -> SoundPack? {
        let manifest = directory.appendingPathComponent("pack.json")
        guard let data = try? Data(contentsOf: manifest),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sounds = root["sounds"] as? [String: String],
            !sounds.isEmpty
        else { return nil }

        // A manifest may name a file that is not there; those entries are dropped rather
        // than becoming silent sources that look configured.
        let present = sounds.filter { _, file in
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(file).path)
        }
        guard !present.isEmpty else { return nil }

        return SoundPack(
            name: root["name"] as? String ?? directory.lastPathComponent,
            author: root["author"] as? String,
            directory: directory,
            sounds: present)
    }

    /// Where packs live once installed.
    public static var installedDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".perch/sound-packs")
    }

    public static func installed() -> [SoundPack] {
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: installedDirectory, includingPropertiesForKeys: nil)) ?? []
        return contents.compactMap(SoundPack.load(from:)).sorted { $0.name < $1.name }
    }
}

extension SoundSettings {
    /// Points every event the pack covers at its file, and leaves the rest alone — a pack
    /// that only defines two sounds should not silence the other eight.
    public mutating func apply(_ pack: SoundPack) {
        for (key, file) in pack.sounds {
            guard InterruptionKind(rawValue: key) != nil else { continue }
            sources[key] = .file(pack.directory.appendingPathComponent(file).path)
        }
    }
}

extension SoundSettings {
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".perch/sounds.json")
    }

    public static func load(from url: URL = defaultURL) -> SoundSettings {
        guard let data = try? Data(contentsOf: url),
            var decoded = try? JSONDecoder().decode(SoundSettings.self, from: data)
        else { return SoundSettings() }

        // Events added by a later version must appear rather than being silently off.
        for (key, value) in SoundSettings.defaults where decoded.sources[key] == nil {
            decoded.sources[key] = value
        }
        return decoded.sanitised
    }

    /// The encoder is configured, not default: `JSONEncoder` escapes every `/`, which
    /// turns `file:/Users/you/ping.aiff` into `file:\/Users\/you\/ping.aiff` — valid JSON,
    /// and unreadable in a file whose whole point is that you can edit it by hand.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .prettyPrinted, .sortedKeys]
        return encoder
    }

    public func save(to url: URL = defaultURL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(sanitised).write(to: url, options: .atomic)
        } catch {
            NSLog("perch: could not save sound settings: \(error)")
        }
    }
}
