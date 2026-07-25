import AppKit
import Foundation
import Observation
import PerchKit

/// Holds the licence and talks to the vendor.
///
/// Nothing here is on the path between Claude Code and a permission prompt. That is the
/// point: a licence problem should cost you the leaderboard, never an approval.
@MainActor
@Observable
final class LicenseModel {
    private(set) var record = LicenseRecord.load()
    private(set) var isWorking = false
    private(set) var lastError: String?

    @ObservationIgnored private let vendor: any LicenseVendor

    init(vendor: any LicenseVendor = LemonSqueezyVendor()) {
        self.vendor = vendor
    }

    var state: LicenseState { License.state(for: record) }

    func allows(_ feature: License.Feature) -> Bool {
        License.allows(feature, state)
    }

    /// The name the seat is listed under in the vendor's dashboard. A hostname is what
    /// makes "deactivate the old laptop" a decision someone can actually make.
    private var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    func activate(key: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isWorking = true
        lastError = nil
        defer { isWorking = false }

        do {
            let activation = try await vendor.activate(key: trimmed, deviceName: deviceName)
            record.key = trimmed
            record.instanceId = activation.instanceId
            record.seats = activation.seats
            record.activatedAt = .now
            record.lastVerifiedAt = .now
            record.save()
        } catch {
            lastError = (error as? LicenseError)?.errorDescription ?? "\(error)"
        }
    }

    /// Re-checks quietly in the background. A failure here is not shown: the offline grace
    /// period exists precisely so a flaky network is not the user's problem.
    func refresh() async {
        guard let key = record.key, let instance = record.instanceId else { return }
        do {
            let activation = try await vendor.validate(key: key, instanceId: instance)
            record.seats = activation.seats
            record.lastVerifiedAt = .now
            record.save()
        } catch LicenseError.invalidKey {
            // A key that the vendor now rejects — refunded, revoked — is worth surfacing.
            lastError = LicenseError.invalidKey.errorDescription
            record.key = nil
            record.instanceId = nil
            record.activatedAt = nil
            record.save()
        } catch {
            // Network or server trouble: leave the record alone and let the grace run.
        }
    }

    /// Frees this Mac's seat so it can be used elsewhere.
    func deactivate() async {
        guard let key = record.key, let instance = record.instanceId else { return }
        isWorking = true
        defer { isWorking = false }

        // The local record is cleared even if the call fails: someone who asked to
        // deactivate should not be left looking activated on a machine they are leaving.
        try? await vendor.deactivate(key: key, instanceId: instance)
        record.key = nil
        record.instanceId = nil
        record.activatedAt = nil
        record.lastVerifiedAt = nil
        record.save()
    }
}
