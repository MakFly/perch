import PerchKit
import SwiftUI

/// Subscription quota: how much of the plan is left, as opposed to what it cost.
///
/// This is the number people actually check, and it is the one Perch could not show until
/// the statusline bridge existed — so when it is missing, the view says how to get it
/// rather than rendering a plausible-looking zero.
struct UsageLimitsView: View {
    let reading: UsageLimitsReader.Reading?
    /// Remote hosts report their own quota. A build server signed in as another account
    /// has another budget, so they are listed apart rather than merged.
    var remote: [String: UsageLimitsReader.Reading] = [:]
    /// Spent, or left. The same number read two ways — and which one someone reads without
    /// having to think about it is a preference, not a default worth arguing over.
    var showsRemaining = false
    /// Nil where there is nothing to toggle from, such as the off-screen preview.
    var onToggle: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if let reading, !reading.limits.isEmpty {
                ForEach(reading.limits.windows) { window in
                    WindowBar(window: window, showsRemaining: showsRemaining)
                }
            } else if reading?.limits.available == false {
                Text(t("No plan limits on this account — API key, Bedrock or Vertex."))
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ConnectQuota()
            }

            ForEach(remote.keys.sorted(), id: \.self) { host in
                if let hostReading = remote[host], !hostReading.limits.isEmpty {
                    Text(host)
                        .font(Theme.mono(9, .medium))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.top, 2)
                    ForEach(hostReading.limits.windows) { window in
                        WindowBar(window: window, showsRemaining: showsRemaining)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(t("Plan"))
                .font(Theme.label(13, .semibold))
                .foregroundStyle(Theme.primary)

            // The word is the control. A settings trip to flip a number you are looking at
            // is a trip nobody makes, so the label says which reading you are on and
            // clicking it says the other one.
            if let onToggle {
                Button(action: onToggle) {
                    Text(showsRemaining ? t("left") : t("used"))
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)
                .help(t("Show what is used instead"))
            }

            Spacer()

            if let updated = reading?.updatedAt {
                Text(updated.formatted(.relative(presentation: .numeric)))
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

}

/// The quota's empty state, with the thing that fixes it attached.
///
/// It used to read "Run ./scripts/usage-bridge.sh, then restart your sessions" — a panel
/// hanging off the notch telling you to go and find a terminal. The bridge is one script
/// and the app can run it, so it offers to.
///
/// When the script cannot be reached — a copy dragged out of the DMG has no repository
/// next to it — the button becomes "copy the command" rather than one that quietly fails.
private struct ConnectQuota: View {
    @State private var isWorking = false
    @State private var outcome: String?

    private var script: URL? { RepoScripts.url(of: "usage-bridge.sh") }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(t("Not connected. Claude Code publishes your plan quota to its statusline, and the bridge reads it there."))
                .font(Theme.mono(9))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                if script != nil {
                    SmallButton(title: isWorking ? t("Connecting…") : t("Connect"), tint: Theme.info) {
                        connect()
                    }
                    .disabled(isWorking)
                } else {
                    SmallButton(title: t("Copy the command"), tint: Theme.info) {
                        RepoScripts.copyToPasteboard(RepoScripts.command(for: "usage-bridge.sh"))
                        outcome = t("Copied. Run it in the repository, then restart your sessions.")
                    }
                }
                Spacer(minLength: 0)
            }

            if let outcome {
                Text(outcome)
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func connect() {
        isWorking = true
        outcome = nil
        Task {
            let ok = RepoScripts.run("usage-bridge.sh")
            isWorking = false
            // The restart is the part everyone misses, so it is the sentence left on screen.
            outcome =
                ok
                ? t("Connected. Restart your open Claude Code sessions — the statusline is read when one starts.")
                : t("Could not run the bridge. See ./scripts/usage-bridge.sh --status.")
        }
    }
}

/// The same quota as one dense line, for the panel header: `5h 42% 5h · 7d 88% 4d`.
///
/// The full bars answer "how am I doing"; this answers "am I about to be cut off" without
/// spending a third of the panel on it.
struct UsageLimitsStrip: View {
    let reading: UsageLimitsReader.Reading?
    var showsRemaining = false
    /// Which slice of the windows to draw. The resting strip splits them across the cutout
    /// — the two everyone has on one side, anything per-model on the other — and the
    /// hardware in between means one view cannot draw them all.
    var dropFirst = 0
    var maximum = 2
    /// Whether to say when the window turns over.
    ///
    /// Off beside the cutout. `5h 2% 4h41m` is eleven characters of menu bar per window,
    /// and the countdown is the half nobody reads from across a room — where "am I about
    /// to be cut off" is answered by the number and its colour. It stays in the panel and
    /// under the cursor, which is where a delay is worth reading.
    var showsReset = true

    private var windows: [NamedWindow] {
        guard let reading else { return [] }
        return Array(reading.limits.windows.dropFirst(dropFirst).prefix(maximum))
    }

    var body: some View {
        if !windows.isEmpty {
            HStack(spacing: 8) {
                ForEach(windows) { window in
                    HStack(spacing: Self.spacing) {
                        Text(short(window.id))
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.tertiary)
                        // The colour always follows what is *spent*, whichever number is
                        // printed: red has one meaning here, and it is not "12". A stale
                        // window has no colour to earn — there is no number under it.
                        Text(percentage(window.window))
                            .font(Theme.mono(9, .semibold))
                            .foregroundStyle(
                                window.window.isStale()
                                    ? Theme.tertiary : tint(window.window.utilization ?? 0))
                            .monospacedDigit()
                        // A percentage on its own does not answer the question people
                        // actually have at 90%, which is "how long until it comes back".
                        if showsReset, let left = window.window.timeLeft() {
                            Text(left)
                                .font(Theme.mono(9))
                                .foregroundStyle(Theme.tertiary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func percentage(_ window: RateLimitWindow) -> String {
        Self.percentage(window, showsRemaining: showsRemaining)
    }

    private func short(_ id: String) -> String { Self.short(id) }

    /// A dash, not a number, once the window has reset: whatever the last render said is
    /// about the week that ended, and the next one is minutes away.
    static func percentage(_ window: RateLimitWindow, showsRemaining: Bool) -> String {
        guard !window.isStale() else { return "—" }
        let value = showsRemaining ? (window.remaining ?? 100) : (window.utilization ?? 0)
        return String(format: "%.0f%%", value)
    }

    /// The header has room for `5h`, not `5h session`.
    static func short(_ id: String) -> String {
        switch id {
        case "five_hour": return "5h"
        case "seven_day": return "7d"
        case "seven_day_opus": return "7d opus"
        case "seven_day_sonnet": return "7d sonnet"
        default: return id
        }
    }

    /// The chip's pieces, in the order they are drawn.
    static func pieces(
        for window: NamedWindow, showsRemaining: Bool = false, showsReset: Bool = true
    ) -> [String] {
        [short(window.id), percentage(window.window, showsRemaining: showsRemaining),
         showsReset ? window.window.timeLeft() : nil]
            .compactMap { $0 }
    }

    /// The chip as one string, for anything that wants to read it rather than lay it out.
    static func label(
        for window: NamedWindow, showsRemaining: Bool = false, showsReset: Bool = true
    ) -> String {
        pieces(for: window, showsRemaining: showsRemaining, showsReset: showsReset)
            .joined(separator: " ")
    }

    /// How wide that chip actually draws.
    ///
    /// Measured piece by piece with the gaps the `HStack` puts between them, rather than
    /// from the joined string: a space is not three points, and the strip beside the cutout
    /// is laid out in a window that was sized before it drew. Measuring the sentence
    /// instead of the layout is what wrapped `4h41m` onto a second line inside the menu
    /// bar.
    static func width(
        for window: NamedWindow, showsRemaining: Bool = false, showsReset: Bool = true
    ) -> CGFloat {
        let pieces = pieces(for: window, showsRemaining: showsRemaining, showsReset: showsReset)
        guard !pieces.isEmpty else { return 0 }
        let text = pieces.reduce(0) { $0 + Theme.monoWidth($1, size: 9) }
        return text + CGFloat(pieces.count - 1) * spacing
    }

    /// The gap between a chip's own pieces. One number, used by the layout and by the
    /// measurement, so the two cannot disagree.
    static let spacing: CGFloat = 3

    private func tint(_ used: Double) -> Color {
        switch used {
        case ..<75: return Theme.active
        case ..<95: return Theme.warning
        default: return Theme.danger
        }
    }
}

private struct WindowBar: View {
    let window: NamedWindow
    var showsRemaining = false

    private var used: Double { window.window.utilization ?? 0 }

    /// The window already reset, so the percentage describes the one that ended. The row
    /// stays — dropping it would empty the panel into "not connected", which is a different
    /// and wronger claim — but it says nothing it cannot back up until the next render.
    private var isStale: Bool { window.window.isStale() }

    /// Green until it matters, amber when the end is in sight, red once it is spent.
    private var tint: Color {
        if isStale { return Theme.tertiary }
        switch used {
        case ..<75: return Theme.active
        case ..<95: return Theme.warning
        default: return Theme.danger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(t(window.title))
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.secondary)

                Spacer()

                // The bar still fills with what is spent — a bar that empties as you use
                // it would say the opposite of the colour beside it.
                Text(isStale ? "—" : String(format: "%.0f%%", showsRemaining ? 100 - used : used))
                    .font(Theme.mono(10, .semibold))
                    .foregroundStyle(tint)

                // "6 minutes ago" beside a percentage reads as a live window that happens
                // to have just turned over; what it means is that the number is old.
                if isStale {
                    Text(t("waiting"))
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.tertiary)
                } else if let resets = window.window.resetsAt {
                    Text(resets.formatted(.relative(presentation: .numeric)))
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.tertiary)
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.hairline)
                    Capsule()
                        .fill(tint)
                        .frame(width: geometry.size.width * (isStale ? 0 : min(1, max(0, used / 100))))
                }
            }
            .frame(height: 4)
        }
    }
}
