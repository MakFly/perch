import AppKit
import PerchKit
import SwiftUI

/// The `rank` tab.
///
/// Two states, and the first one is the important one: not joined. Nothing has been sent,
/// and the tab says exactly what would be if you joined — counters, by day and model — so
/// the decision is made with the facts rather than after them.
struct RankView: View {
    let model: AppModel

    private var leaderboard: LeaderboardModel { model.leaderboard }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if leaderboard.isJoined {
                joined
            } else {
                JoinForm(model: model)
            }

            Spacer(minLength: 0)
        }
        .task {
            // After the panel has finished growing, not while it is.
            //
            // `Motion.morph` runs for 0.38s, and starting a network round trip on the
            // frame the spring starts means the response lands mid-animation and relays
            // the whole tab out under it. Waiting costs nothing anyone can perceive — the
            // board is a week old — and buys a clean opening.
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            await leaderboard.refresh()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(t("Leaderboard"))
                .font(Theme.label(13, .semibold))
                .foregroundStyle(Theme.primary)

            if let board = leaderboard.board {
                Text(board.period.label)
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.tertiary)

                if board.isDemo {
                    // The server is generating its numbers. Saying so is not optional: a
                    // ranking that is not of anyone is not a ranking.
                    Text(t("demo data"))
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.warning)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4).fill(Theme.warning.opacity(0.12)))
                }
            }

            Spacer()

            if leaderboard.isLoading || leaderboard.isPublishing {
                Text(leaderboard.isPublishing ? t("publishing…") : t("loading…"))
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.tertiary)
            }

            if leaderboard.board != nil {
                StepButton(symbol: "chevron.left", help: t("Previous week")) {
                    leaderboard.offset += 1
                }
                StepButton(symbol: "chevron.right", help: t("Next week")) {
                    leaderboard.offset = max(0, leaderboard.offset - 1)
                }
                .opacity(leaderboard.offset == 0 ? 0.3 : 1)
            }
        }
    }

    // MARK: - Joined

    @ViewBuilder
    private var joined: some View {
        if let error = leaderboard.error {
            Text(error)
                .font(Theme.mono(9))
                .foregroundStyle(Theme.warning)
                .lineLimit(2)
        }

        if let board = leaderboard.board {
            if board.rows.isEmpty {
                Text(t("Nobody published this week. Yours will be the first."))
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.tertiary)
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(board.rows.prefix(12)) { row in
                            RankRow(row: row, isYou: row.handle == leaderboard.identity?.handle)
                        }

                        // Your row, kept visible even when it is past the twelfth: the one
                        // rank someone opens this tab for is their own.
                        if let you = board.you, you.rank > 12 {
                            Text("⋯")
                                .font(Theme.mono(9))
                                .foregroundStyle(Theme.tertiary)
                            RankRow(row: you, isYou: true)
                        }
                    }
                }
                .frame(maxHeight: 210)
            }
        } else if leaderboard.error == nil {
            Text(t("Reading the board…"))
                .font(Theme.mono(10))
                .foregroundStyle(Theme.tertiary)
        }

        footer
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                Task { await leaderboard.publish(usage: model.usage) }
            } label: {
                Label(t("Publish now"), systemImage: "arrow.up.circle")
                    .font(Theme.label(10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.info)
            .disabled(leaderboard.isPublishing)

            if let url = leaderboard.profileURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(t("My profile"), systemImage: "arrow.up.right.square")
                        .font(Theme.label(10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.tertiary)
            }

            Spacer()

            if let published = leaderboard.lastPublished {
                Text(t("published %@", published.shortAge))
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }
}

// MARK: - Row

private struct RankRow: View {
    let row: Leaderboard.Row
    let isYou: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(medal ?? "#\(row.rank)")
                .font(Theme.mono(10))
                .foregroundStyle(medal == nil ? Theme.tertiary : Theme.primary)
                .frame(width: 26, alignment: .leading)

            Text(row.displayName)
                .font(Theme.label(11))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)

            if let team = row.team, !team.isEmpty {
                Text(team)
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.hairline))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(row.costUsd.compactCost)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.claude)
                .frame(width: 54, alignment: .trailing)

            Text(row.outputTokens.compactTokens)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.primary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isYou ? Theme.claude.opacity(0.10) : Theme.raised)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isYou ? Theme.claude.opacity(0.35) : .clear, lineWidth: 1)))
    }

    private var medal: String? {
        switch row.rank {
        case 1: return "🥇"
        case 2: return "🥈"
        case 3: return "🥉"
        default: return nil
        }
    }
}

// MARK: - Joining

private struct JoinForm: View {
    let model: AppModel

    @State private var handle = ""
    @State private var team = ""
    @State private var visibility = Leaderboard.Visibility.public

    private var leaderboard: LeaderboardModel { model.leaderboard }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("Compare your output with other developers. Counters only — never a prompt, a path or a project name."))
                .font(Theme.mono(10))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Field(placeholder: t("handle"), text: $handle)
                Field(placeholder: t("team (optional)"), text: $team)
            }

            HStack(spacing: 8) {
                Picker("", selection: $visibility) {
                    Text(t("Public")).tag(Leaderboard.Visibility.public)
                    Text(t("Unlisted")).tag(Leaderboard.Visibility.private)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)

                Button {
                    Task {
                        await leaderboard.join(
                            handle: handle, displayName: handle,
                            team: team.isEmpty ? nil : team,
                            visibility: visibility, usage: model.usage)
                    }
                } label: {
                    Text(leaderboard.isPublishing ? t("Joining…") : t("Join"))
                        .font(Theme.label(10, .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hairlineStrong))
                }
                .buttonStyle(.plain)
                .disabled(handle.isEmpty || leaderboard.isPublishing)

                Spacer()
            }

            if let error = leaderboard.error {
                Text(error)
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.warning)
                    .lineLimit(2)
            }

            // Shown before joining, not after: the whole point is that the decision is
            // made knowing what leaves.
            if !handle.isEmpty {
                Text(t("You will publish as %@", Leaderboard.normalise(handle: handle)))
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }
}

private struct Field: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Theme.mono(10))
            .foregroundStyle(Theme.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.raised)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 1)))
    }
}

private struct StepButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.tertiary)
                .padding(4)
                .background(Circle().fill(Theme.hairline))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

extension Date {
    /// `4m ago`, `2h ago` — enough to know whether a publish is current.
    var shortAge: String {
        let seconds = Int(Date.now.timeIntervalSince(self))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86400)d ago"
        }
    }
}
