import PerchKit
import SwiftUI

/// The permission prompt, in the notch.
///
/// A Claude Code session is blocked while this is on screen, so it has to answer three
/// questions at a glance: which tool, doing what, in which project.
struct PermissionAlertView: View {
    let pending: PendingPermission
    let waitingCount: Int
    let decide: (PermissionDecision, Bool) -> Void
    var decideAll: ((PermissionDecision) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            command
            buttons
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)

            Text(pending.tool)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)

            if let project = pending.projectName {
                Text(project)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if waitingCount > 1 {
                Text("+\(waitingCount - 1) waiting")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.1)))
            }
        }
    }

    private var command: some View {
        Text(pending.detail)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(3)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.07)))
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            AlertButton(title: "Allow", tint: .green, shortcut: "⌥↵") {
                decide(.allow, false)
            }

            // Only offered when we can express a rule the user can read and audit.
            if let rule = PermissionRule.rule(for: pending.request) {
                AlertButton(title: "Always", tint: .green.opacity(0.6), shortcut: nil) {
                    decide(.allow, true)
                }
                .help("Adds \(rule) to this project's .claude/settings.local.json")
            }

            AlertButton(title: "Deny", tint: .red, shortcut: "⌥⌫") {
                decide(.deny, false)
            }

            Spacer(minLength: 0)

            // Only when there is a queue, and only allow/deny: writing an "Always" rule
            // for requests you have not read is how a permission system stops meaning
            // anything.
            if waitingCount > 1, let decideAll {
                Button(t("Allow all %lld", waitingCount)) { decideAll(.allow) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.active.opacity(0.8))
                Button(t("Deny all")) { decideAll(.deny) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.danger.opacity(0.8))
            }

            Button(t("Ask in terminal")) { decide(.ask, false) }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}

private struct AlertButton: View {
    let title: String
    let tint: Color
    let shortcut: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(tint.opacity(isHovering ? 0.45 : 0.25))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
