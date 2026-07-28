import PerchKit
import SwiftUI

/// The Stats tab: where the tokens went, per minute / hour / day / month.
struct StatsView: View {
    let usage: UsageModel
    var showsRemaining = false
    var onToggleQuota: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Quota first: "how much is left" beats "what it cost" for a glance.
            UsageLimitsView(
                reading: usage.limits, remote: usage.remoteLimits,
                showsRemaining: showsRemaining, onToggle: onToggleQuota)
            header
            summary
            chart
            models
            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(t("Tokens"))
                .font(Theme.label(13, .semibold))
                .foregroundStyle(Theme.primary)

            if usage.isIndexing {
                Text(t("indexing…"))
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.tertiary)
            }

            Spacer()

            GranularityPicker(selection: usage.granularity) { usage.granularity = $0 }
        }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            StatTile(
                label: t("today"),
                value: usage.today.totalTokens.compactTokens,
                detail: usage.today.cost.compactCost,
                tint: Theme.active)
            StatTile(
                label: t("all time"),
                value: usage.allTime.totalTokens.compactTokens,
                detail: usage.allTime.cost.compactCost,
                tint: Theme.info)
            StatTile(
                label: t("cache read"),
                value: usage.today.cacheReadTokens.compactTokens,
                detail: "\(cacheShare)% of today",
                tint: Theme.warning)
        }
    }

    /// Cache reads dominate real usage, so showing their share explains an otherwise
    /// alarming token count.
    private var cacheShare: Int {
        let total = usage.today.totalTokens
        guard total > 0 else { return 0 }
        return Int((Double(usage.today.cacheReadTokens) / Double(total) * 100).rounded())
    }

    @ViewBuilder
    private var chart: some View {
        if usage.buckets.isEmpty {
            Text(usage.indexError ?? t("No usage indexed yet."))
                .font(Theme.mono(10))
                .foregroundStyle(Theme.tertiary)
                .frame(height: 72, alignment: .center)
        } else {
            TokenBars(buckets: usage.buckets)
                .frame(height: 72)
        }
    }

    @ViewBuilder
    private var models: some View {
        if !usage.byModel.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(t("by model, today"))
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.tertiary)

                ForEach(usage.byModel.prefix(4), id: \.model) { entry in
                    HStack(spacing: 8) {
                        Text(ModelName.display(entry.model))
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        // Both numeric columns are fixed width, so they line up row to
                        // row. With only the cost pinned, the token figures drifted with
                        // the length of the model name beside them — which is the one
                        // thing a column of numbers must not do.
                        Text(entry.tokens.compactTokens)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.primary)
                            .frame(width: 60, alignment: .trailing)
                        Text(entry.cost.compactCost)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.active)
                            .frame(width: 60, alignment: .trailing)
                    }
                    .monospacedDigit()
                }
            }
        }
    }

    /// `claude-opus-4-8` reads better as `opus-4-8` in a 680pt panel.
}

private struct GranularityPicker: View {
    let selection: UsageStore.Granularity
    let onSelect: (UsageStore.Granularity) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(UsageStore.Granularity.allCases, id: \.self) { granularity in
                Button {
                    onSelect(granularity)
                } label: {
                    Text(String(granularity.rawValue.prefix(3)))
                        .font(Theme.mono(9, .medium))
                        .foregroundStyle(granularity == selection ? Theme.primary : Theme.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(granularity == selection ? Theme.hairlineStrong : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.mono(9))
                .foregroundStyle(Theme.tertiary)
            Text(value)
                .font(Theme.mono(16, .semibold))
                .foregroundStyle(Theme.primary)
            Text(detail)
                .font(Theme.mono(9))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .fill(Theme.raised)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .stroke(Theme.hairline, lineWidth: 1))
        )
    }
}

/// Bar chart, drawn by hand rather than with Charts: a fixed bar width keeps the
/// silhouette stable as buckets scroll in, and it avoids pulling in the framework for
/// one 72-point graph.
private struct TokenBars: View {
    let buckets: [UsageStore.Bucket]

    /// Which bar the cursor is on. The readout replaces the axis line rather than floating
    /// over the bars: a tooltip that covers the chart it describes makes you move the mouse
    /// to read it, and at 72pt tall there is nowhere for it to go.
    @State private var hovered: UsageStore.Bucket.ID?

    private var peak: Int { max(buckets.map(\.tokens).max() ?? 1, 1) }

    /// What the bars are actually drawn against.
    ///
    /// Not the peak. The newest bucket is the one still growing, so it becomes the peak
    /// every few seconds — and scaling against it made *every other bar* shrink on every
    /// refresh. The chart looked alive and said nothing. Rounding up to the next 1 / 2 / 5
    /// × 10ⁿ gives a ceiling that only moves when the data crosses a magnitude step, so
    /// the silhouette holds still between one turn and the next.
    private var ceiling: Int {
        let magnitude = pow(10, floor(log10(Double(peak))))
        for step in [1.0, 2.0, 5.0, 10.0] where Double(peak) <= step * magnitude {
            return Int(step * magnitude)
        }
        return peak
    }

    /// The bucket that is still being written to — the last one, by construction.
    private var current: UsageStore.Bucket.ID? { buckets.last?.id }

    /// Which column a horizontal position falls in. Clamped rather than optional: the
    /// cursor is inside the chart or the phase is `.ended`, and a nil in between would
    /// blink the readout off at the edges.
    private func bucket(at x: CGFloat, across width: CGFloat) -> UsageStore.Bucket.ID? {
        guard !buckets.isEmpty, width > 0 else { return nil }
        let index = Int(x / (width / CGFloat(buckets.count)))
        return buckets[min(max(index, 0), buckets.count - 1)].id
    }

    private var focused: UsageStore.Bucket? {
        hovered.flatMap { id in buckets.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(buckets) { bucket in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(fill(for: bucket))
                            .frame(height: height(for: bucket, in: proxy.size.height))
                            .frame(maxWidth: .infinity)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                // One hover region for the whole chart, not one per bar.
                //
                // `onHover` on each bar meant up to sixty NSTrackingAreas, torn down and
                // reinstalled on every layout pass — and the panel spends 0.38s laying
                // itself out on a spring every time it opens. That is what made the
                // opening stutter. The column under the cursor is arithmetic, so one
                // region does the same job for a sixtieth of the cost, and it also fixes
                // moving fast between bars: the old pairwise enter/exit could leave the
                // highlight on a bar the cursor had already left.
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let location):
                        hovered = bucket(at: location.x, across: proxy.size.width)
                    case .ended:
                        hovered = nil
                    }
                }
            }

            HStack {
                if let focused {
                    // One line, three facts, in the order you read them: when, how much,
                    // what it cost.
                    Text(focused.label)
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    Text(focused.tokens.compactTokens)
                        .foregroundStyle(Theme.primary)
                    Text(focused.cost.compactCost)
                        .foregroundStyle(Theme.active)
                } else {
                    Text(buckets.first?.label ?? "")
                    Spacer()
                    Text("peak \(peak.compactTokens)")
                        .foregroundStyle(Theme.active)
                    Spacer()
                    Text(buckets.last?.label ?? "")
                }
            }
            .font(Theme.mono(8))
            .foregroundStyle(Theme.tertiary)
            .monospacedDigit()
            // Fixed height so swapping the two lines cannot nudge the chart above it.
            .frame(height: 10)
        }
    }

    /// Green marks *now*, not the maximum.
    ///
    /// Colouring the tallest bar meant the highlight hopped to a different bucket whenever
    /// the ranking changed, which is movement that carries no news. The live bucket never
    /// moves — it is always the one on the right — and it is the one you are looking for.
    private func fill(for bucket: UsageStore.Bucket) -> Color {
        if bucket.id == hovered { return Theme.primary }
        return bucket.id == current ? Theme.active : Theme.info.opacity(0.55)
    }

    /// Bars keep a 2pt floor so an active-but-quiet bucket is still visible.
    private func height(for bucket: UsageStore.Bucket, in available: CGFloat) -> CGFloat {
        let ratio = Double(bucket.tokens) / Double(ceiling)
        return max(2, available * ratio)
    }
}
