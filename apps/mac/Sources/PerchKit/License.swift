import Foundation

/// Licensing.
///
/// One rule governs everything here: **a licence must never be able to stop you approving
/// a permission.** Perch sits between Claude Code and its prompt; a expired trial, a
/// failed network call or a corrupt file that blocked that path would be worse than
/// shipping no licensing at all. So the state below gates *features* — the leaderboard,
/// remote hosts, the switcher — and never the hook.
public enum LicenseState: Sendable, Equatable {
    case trial(daysLeft: Int)
    case trialExpired
    case licensed(seats: Int)
    /// Activated once, and the server has not been reachable since. Treated as licensed:
    /// someone who paid should not lose the app on a plane.
    case licensedOffline(since: Date)
    case invalid(reason: String)

    public var isEntitled: Bool {
        switch self {
        case .trial, .licensed, .licensedOffline: return true
        case .trialExpired, .invalid: return false
        }
    }

    public var label: String {
        switch self {
        case .trial(let days): return days == 1 ? "Trial · 1 day left" : "Trial · \(days) days left"
        case .trialExpired: return "Trial ended"
        case .licensed(let seats): return seats > 1 ? "Licensed · \(seats) Macs" : "Licensed"
        case .licensedOffline: return "Licensed · offline"
        case .invalid(let reason): return reason
        }
    }
}

/// What Perch remembers between launches.
public struct LicenseRecord: Codable, Sendable, Equatable {
    public var key: String?
    /// The vendor's handle for *this* Mac's activation, needed to release the seat later.
    public var instanceId: String?
    public var seats: Int
    public var activatedAt: Date?
    public var lastVerifiedAt: Date?
    public var trialStartedAt: Date

    public init(
        key: String? = nil,
        instanceId: String? = nil,
        seats: Int = 1,
        activatedAt: Date? = nil,
        lastVerifiedAt: Date? = nil,
        trialStartedAt: Date = .now
    ) {
        self.key = key
        self.instanceId = instanceId
        self.seats = seats
        self.activatedAt = activatedAt
        self.lastVerifiedAt = lastVerifiedAt
        self.trialStartedAt = trialStartedAt
    }
}

public enum License {
    /// Long enough to have used it on a real workday, short enough to be a trial.
    public static let trialDays = 7
    /// How long an activated copy keeps working without reaching the vendor. Generous on
    /// purpose: the alternative is punishing a paying user for their own network.
    public static let offlineGraceDays = 30

    public static func state(
        for record: LicenseRecord,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> LicenseState {
        if record.key != nil, record.activatedAt != nil {
            guard let verified = record.lastVerifiedAt else {
                return .licensed(seats: record.seats)
            }
            let days = calendar.dateComponents([.day], from: verified, to: now).day ?? 0
            if days <= 1 { return .licensed(seats: record.seats) }
            if days <= offlineGraceDays { return .licensedOffline(since: verified) }
            return .invalid(reason: "Licence could not be verified in \(offlineGraceDays) days")
        }

        let elapsed = calendar.dateComponents(
            [.day], from: record.trialStartedAt, to: now).day ?? 0
        let left = trialDays - elapsed
        return left > 0 ? .trial(daysLeft: left) : .trialExpired
    }

    /// Features a licence unlocks. Approving, denying, answering questions and seeing
    /// activity are **not** on this list, and must never be.
    public enum Feature: String, Sendable, CaseIterable {
        case leaderboard
        case remoteHosts
        case switcher
        case soundPacks
    }

    public static func allows(_ feature: Feature, _ state: LicenseState) -> Bool {
        state.isEntitled
    }
}

extension LicenseRecord {
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".perch/license.json")
    }

    /// A corrupt or missing file starts a fresh trial rather than locking the app: the
    /// failure mode of licensing should always be "too generous".
    public static func load(from url: URL = defaultURL) -> LicenseRecord {
        guard let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(LicenseRecord.self, from: data)
        else {
            let fresh = LicenseRecord()
            fresh.save(to: url)
            return fresh
        }
        return decoded
    }

    public func save(to url: URL = defaultURL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
        } catch {
            NSLog("perch: could not save the licence record: \(error)")
        }
    }
}
