import Foundation
import PerchKit

/// `Perch --rank …` — the leaderboard from the command line.
///
/// Standalone on purpose: unlike `--decide` or `--answer`, which speak to the running
/// instance because they answer something it is holding, this reads the same two files the
/// app does (`~/.perch/leaderboard.json` and the usage index) and talks to the API
/// directly. That makes the whole publish path exercisable without a click, which is how
/// it is tested end to end — and it works while the app is closed.
enum LeaderboardCLI {

    static func run(_ arguments: [String]) -> Int32 {
        let client = LeaderboardClient()

        switch arguments.first {
        case "join":
            guard let handle = arguments.dropFirst().first else {
                print("usage: Perch --rank join <handle> [team]")
                return 2
            }
            return join(handle: handle, team: arguments.dropFirst(2).first, client: client)

        case "publish":
            return publish(client: client)

        case "status", nil:
            return status(client: client)

        case "leave":
            Leaderboard.Identity.remove()
            print("left the leaderboard — the token on this Mac is gone")
            print("counters already published stay on the board; this Mac can no longer change them")
            return 0

        default:
            print("usage: Perch --rank [status | join <handle> [team] | publish | leave]")
            return 2
        }
    }

    // MARK: - Commands

    private static func join(handle: String, team: String?, client: LeaderboardClient) -> Int32 {
        if let existing = Leaderboard.Identity.load() {
            print("already publishing as @\(existing.handle) — `Perch --rank leave` first")
            return 1
        }

        let normalised = Leaderboard.normalise(handle: handle)
        guard Leaderboard.isValid(handle: normalised) else {
            print("`\(handle)` is not a usable handle (2–31 of a–z, 0–9, - or _)")
            return 2
        }

        return blocking { () -> Int32 in
            do {
                let registration = try await client.register(
                    handle: normalised, displayName: handle, team: team, agent: "claude",
                    visibility: .public)
                let identity = Leaderboard.Identity(
                    handle: registration.handle, token: registration.token,
                    displayName: handle, team: team)
                identity.save()
                print("joined as @\(registration.handle)")
                print("  token stored in \(Leaderboard.Identity.defaultURL.path) (mode 600)")
                return await send(identity: identity, client: client)
            } catch {
                print("could not join: \(describe(error))")
                return 1
            }
        }
    }

    private static func publish(client: LeaderboardClient) -> Int32 {
        guard let identity = Leaderboard.Identity.load() else {
            print("not on the leaderboard — `Perch --rank join <handle>`")
            return 1
        }
        return blocking { await send(identity: identity, client: client) }
    }

    private static func status(client: LeaderboardClient) -> Int32 {
        guard let identity = Leaderboard.Identity.load() else {
            print("not on the leaderboard")
            print("  join with: Perch --rank join <handle>")
            print("  nothing has been published from this Mac")
            return 0
        }

        print("publishing as @\(identity.handle)\(identity.team.map { " · \($0)" } ?? "")")
        print("  visibility   \(identity.visibility.rawValue)")
        print(
            "  last publish \(identity.lastPublishedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never")")
        print("  api          \(client.baseURL.absoluteString)")
        print("  site         \(client.siteURL.absoluteString)")

        return blocking { () -> Int32 in
            do {
                let board = try await client.board(offset: 0, you: identity.handle)
                print("  week         \(board.period.label)\(board.isDemo ? "  (demo data)" : "")")
                if let you = board.you {
                    print(
                        "  your rank    #\(you.rank) of \(board.rows.count) · "
                            + "\(you.outputTokens) output tokens · \(you.model)")
                } else {
                    print("  your rank    not on this week's board yet")
                }
                return 0
            } catch {
                print("  board        unreachable — \(describe(error))")
                return 1
            }
        }
    }

    // MARK: - Publishing

    private static func send(identity: Leaderboard.Identity, client: LeaderboardClient) async
        -> Int32
    {
        guard let store = try? UsageStore(path: UsageStore.defaultURL.path) else {
            print("the usage index is not readable — run `Perch --index` first")
            return 1
        }

        let since = Calendar.current.date(
            byAdding: .day, value: -Leaderboard.publishWindowDays, to: .now)
        guard let models = try? store.dailyByModel(since: since),
            let activity = try? store.dailyActivity(since: since)
        else {
            print("could not read the usage index")
            return 1
        }

        let payload = Leaderboard.payload(models: models, activity: activity)
        guard !payload.days.isEmpty else {
            print("nothing indexed in the last \(Leaderboard.publishWindowDays) days")
            return 1
        }

        do {
            let accepted = try await client.publish(token: identity.token, payload: payload)
            var updated = identity
            updated.lastPublishedAt = .now
            updated.save()
            print("published \(accepted) day/model rows")
            print("  \(client.profileURL(handle: identity.handle).absoluteString)")
            return 0
        } catch {
            print("could not publish: \(describe(error))")
            return 1
        }
    }

    // MARK: - Plumbing

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    /// `main.swift` runs before the run loop, so async work needs somewhere to land.
    ///
    /// The exit code travels through a box rather than a captured `var`: the task writes
    /// it on another thread and the semaphore is what orders that write against this
    /// read, which is a guarantee a local variable cannot make on its own.
    private static func blocking(_ work: @escaping @Sendable () async -> Int32) -> Int32 {
        final class Box: @unchecked Sendable { var code: Int32 = 1 }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            box.code = await work()
            semaphore.signal()
        }
        semaphore.wait()
        return box.code
    }
}
