import Foundation
import Observation
import PerchKit

/// The `rank` tab's state, and the only place that talks to the leaderboard.
///
/// Publishing is opt-in twice over: nothing is sent until a handle is chosen, and the
/// choice is a deliberate action in the panel rather than a default. Leaving takes the
/// identity file off the disk, which is the whole credential — after that this Mac cannot
/// publish again even if it wanted to.
@MainActor
@Observable
final class LeaderboardModel {
    private(set) var identity: Leaderboard.Identity?
    private(set) var board: Leaderboard.Board?
    private(set) var isLoading = false
    private(set) var isPublishing = false
    private(set) var error: String?
    private(set) var lastPublished: Date?

    /// Which week is on screen. 0 is the live one; the tab can walk back.
    var offset = 0 {
        didSet { Task { await refresh() } }
    }

    @ObservationIgnored private let client: LeaderboardClient
    @ObservationIgnored private var publishTask: Task<Void, Never>?

    /// Where the profile of a handle lives, for the "open my profile" link. The *site*,
    /// not the API — the two are one origin in production and two ports in development.
    var profileURL: URL? {
        guard let handle = identity?.handle else { return nil }
        return client.profileURL(handle: handle)
    }

    var isJoined: Bool { identity != nil }

    init(client: LeaderboardClient = LeaderboardClient()) {
        self.client = client
        self.identity = Leaderboard.Identity.load()
        self.lastPublished = identity?.lastPublishedAt
    }

    // MARK: - Reading

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            board = try await client.board(offset: offset, you: identity?.handle)
            error = nil
        } catch {
            // The board is a nicety; failing to reach it is not an incident. The last one
            // read stays on screen rather than being replaced by an error state.
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    // MARK: - Joining

    /// Registers a handle and immediately publishes, so the tab is never joined-but-empty.
    func join(
        handle rawHandle: String, displayName: String, team: String?,
        visibility: Leaderboard.Visibility, usage: UsageModel
    ) async {
        let handle = Leaderboard.normalise(handle: rawHandle)
        guard Leaderboard.isValid(handle: handle) else {
            error = "A handle is 2–31 letters, digits, - or _."
            return
        }

        isPublishing = true
        defer { isPublishing = false }

        do {
            let registration = try await client.register(
                handle: handle,
                displayName: displayName.isEmpty ? handle : displayName,
                team: team,
                agent: "claude",
                visibility: visibility)

            let identity = Leaderboard.Identity(
                handle: registration.handle,
                token: registration.token,
                displayName: displayName.isEmpty ? handle : displayName,
                team: team,
                visibility: visibility)
            identity.save()
            self.identity = identity
            error = nil

            await publish(usage: usage)
            await refresh()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Removes the identity. The counters already on the board stay there — this Mac just
    /// stops being able to change them, and the file that held the token is gone.
    func leave() {
        Leaderboard.Identity.remove()
        identity = nil
        board = nil
        lastPublished = nil
        error = nil
    }

    // MARK: - Publishing

    func publish(usage: UsageModel) async {
        guard var identity else { return }
        guard let payload = await usage.publishPayload(windowDays: Leaderboard.publishWindowDays)
        else {
            error = "The local token index is not readable, so there is nothing to publish."
            return
        }
        guard !payload.days.isEmpty else {
            error = "Nothing indexed yet — run an agent, then publish."
            return
        }

        isPublishing = true
        defer { isPublishing = false }

        do {
            _ = try await client.publish(token: identity.token, payload: payload)
            identity.lastPublishedAt = .now
            identity.save()
            self.identity = identity
            lastPublished = identity.lastPublishedAt
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Publishes at most once an hour, after a turn ends.
    ///
    /// Tied to the index rather than to a timer: a machine that is not running an agent
    /// has nothing new to say, and waking up to send the same numbers again is how a
    /// background app earns its reputation.
    func publishIfDue(usage: UsageModel, interval: TimeInterval = 3600) {
        guard isJoined, publishTask == nil else { return }
        if let last = lastPublished, Date.now.timeIntervalSince(last) < interval { return }

        publishTask = Task { [weak self] in
            await self?.publish(usage: usage)
            self?.publishTask = nil
        }
    }
}
