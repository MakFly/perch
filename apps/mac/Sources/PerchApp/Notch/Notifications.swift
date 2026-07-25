import AppKit
import PerchKit
import UserNotifications

/// The signal for when the notch cannot be the signal.
///
/// Everything else Perch does assumes you can see the menu bar. Full screen in another
/// app, on another Space, on a second display, or with the laptop lid shut and the panel
/// pinned to the built-in screen — a finished turn produced a sound at most, and nothing
/// at all if sound was off. That is the case a notification is for, and the only one:
/// there is no notification for anything you could have seen.
///
/// Clicking one lands in the terminal that raised it, through the same jump plan a session
/// card uses. A notification that only says "something happened" makes you go looking,
/// which is the thing Perch exists to stop.
@MainActor
enum SessionNotifier {
    enum Kind {
        case finished
        case failed

        var title: String {
            switch self {
            case .finished: return t("Turn finished")
            case .failed: return t("Turn ended on a failure")
            }
        }
    }

    /// Asked for once, the first time one would actually be posted — rather than at
    /// launch, where a permission prompt for something that may never happen is exactly
    /// the kind of interruption this app is against.
    private static var hasRequested = false

    /// Where each notification should land, kept until it is answered. The payload cannot
    /// carry a `ClientInfo`, and putting a session id in it would only work while that
    /// session is still on screen.
    private static var destinations: [String: ClientInfo] = [:]

    static func post(_ kind: Kind, title: String, client: ClientInfo?) {
        let centre = UNUserNotificationCenter.current()

        request { granted in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = kind.title
            content.body = title
            // Silent by construction: Perch already owns the sound decision, and it has
            // quiet hours, quiet scenes and a per-event picker behind it. A second,
            // uncoordinated noise source is how an app gets muted at the OS level.
            content.sound = nil

            let id = UUID().uuidString
            if let client { destinations[id] = client }

            centre.add(
                UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    private static func request(_ then: @escaping @MainActor (Bool) -> Void) {
        let centre = UNUserNotificationCenter.current()
        guard !hasRequested else {
            centre.getNotificationSettings { settings in
                let granted = settings.authorizationStatus == .authorized
                Task { @MainActor in then(granted) }
            }
            return
        }
        hasRequested = true
        centre.requestAuthorization(options: [.alert]) { granted, _ in
            Task { @MainActor in then(granted) }
        }
    }

    /// Called by the delegate when one is clicked.
    static func handle(identifier: String) {
        guard let client = destinations.removeValue(forKey: identifier) else { return }
        TerminalJumper.jump(to: client)
    }
}

/// Routes clicks back into the jump. Separate from `AppDelegate` because
/// `UNUserNotificationCenterDelegate` is the only reason the app needs one at all.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        await MainActor.run { SessionNotifier.handle(identifier: identifier) }
    }
}
