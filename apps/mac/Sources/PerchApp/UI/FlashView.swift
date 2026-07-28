import PerchKit
import SwiftUI

/// One line of news, and how to feel about it.
///
/// Three things happen that are worth saying and not worth a panel: a turn ended, a
/// session ended badly, a quota window crossed the line. All three used to go one of two
/// ways — a sound nobody can attribute to a session, or a four-second peek, which is a
/// panel's worth of interruption for a sentence's worth of news.
struct NotchFlash: Equatable {
    var symbol: String
    /// Who it is about. A notice that does not name the session is a notice you have to
    /// go and investigate, which is the opposite of what it is for.
    var title: String
    var detail: String
    var tint: Color

    static func finished(project: String?, detail: String) -> NotchFlash {
        NotchFlash(
            symbol: "checkmark", title: project ?? t("Claude Code"),
            detail: detail.isEmpty ? t("turn ended") : detail, tint: Theme.active)
    }

    static func failed(project: String?, detail: String) -> NotchFlash {
        NotchFlash(
            symbol: "xmark", title: project ?? t("Claude Code"),
            detail: detail.isEmpty ? t("ended on a failure") : detail, tint: Theme.danger)
    }

    /// The one flash that is not about a session. It carries the number rather than a
    /// warning, because "5h 92%" is the whole message and "usage is high" is not.
    static func quota(window: String, resets: String?) -> NotchFlash {
        NotchFlash(
            symbol: "gauge.with.needle", title: window,
            detail: resets.map { t("resets in %@", $0) } ?? t("quota"), tint: Theme.warning)
    }
}

/// The flash, drawn in the band the cutout already owns.
///
/// Same composition as every other state: what belongs left of the hardware, and what
/// belongs right of it. Nothing hangs below the bezel, so a notice never covers the row
/// of whatever you were reading underneath.
struct FlashView: View {
    let notch: CGSize
    let notice: NotchFlash

    var body: some View {
        CutoutBand(notch: notch) {
            Image(systemName: notice.symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(notice.tint)
            Text(notice.title)
                .font(Theme.mono(10, .semibold))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
        } trailing: {
            Text(notice.detail)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Content laid out either side of the hardware, level with it.
///
/// Only the flash needs this. Every other panel hangs below the bezel, where the menu bar
/// is somebody else's — but a flash is two seconds of one line, and putting it under the
/// bezel would make a notice that has to be *noticed* the only thing on screen that moves
/// away from where you are looking.
struct CutoutBand<Leading: View, Trailing: View>: View {
    let notch: CGSize
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) { leading }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14)
                .padding(.trailing, 8)

            // Nothing is ever drawn here. It is a hole in the screen.
            Color.clear.frame(width: notch.width)

            HStack(spacing: 6) { trailing }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 8)
                .padding(.trailing, 14)
        }
        .frame(height: notch.height)
    }
}
