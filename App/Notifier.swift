import Foundation
import UIKit
import UserNotifications

/// Posts local notifications for events that arrive while the user is not
/// looking at the feed.
///
/// LOCAL only — no APNs. Remote push needs a paid Apple Developer team and an
/// `aps-environment` entitlement, and this app is deliberately signable by a
/// free personal team (see `bag.yaml`). The consequence is real and documented
/// in the README: these fire only while the app is running, because the poll
/// that finds new events is a foreground `Timer`.
///
/// Delivery is best-effort. If the user denies authorization every call quietly
/// no-ops rather than failing the refresh that triggered it.
@MainActor
final class Notifier: NSObject, ObservableObject {
    private var isAuthorized = false

    /// Set when the system tells us notifications are not permitted.
    ///
    /// Worth surfacing rather than swallowing. Authorization is granted per
    /// bundle identifier and can only be changed in Settings — so once denied,
    /// "events stopped notifying me" is otherwise unfindable from inside the
    /// app, which would go on looking exactly like a quiet feed.
    @Published private(set) var wasDenied = false

    /// The newest event already announced — the high-water mark that keeps a
    /// poll from re-announcing the whole first page every 12 seconds.
    private var lastNotifiedAt: Date?

    func requestAuthorization() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                self.isAuthorized = granted
                self.wasDenied = !granted
            }
        }
    }

    /// Ask the system what it currently thinks, so a denial made in Settings
    /// while the app was backgrounded is reflected when the user comes back.
    func refreshAuthorizationState() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        wasDenied = settings.authorizationStatus == .denied
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Announce whatever is new in this page, then remember how far we got.
    ///
    /// The mark advances even when nothing is posted, so an event the user
    /// watched arrive on screen is not announced after they background the app.
    func announce(page: [BarryEvent], isFeedOnScreen: Bool) {
        let decision = EventAnnouncement.decide(
            page: page,
            lastNotifiedAt: lastNotifiedAt,
            isFeedOnScreen: isFeedOnScreen
        )
        lastNotifiedAt = EventAnnouncement.advanceMark(lastNotifiedAt, over: page)

        guard isAuthorized, !decision.isEmpty else { return }

        for event in decision.banners {
            let content = UNMutableNotificationContent()
            content.title = event.type.label.capitalized
            content.body = event.summaryLine
            content.sound = event.severity == .error ? .defaultCritical : .default
            content.userInfo = [Notifier.eventIdKey: event.id]
            submit(content, id: event.id)
        }

        if let summary = decision.summaryBody {
            let content = UNMutableNotificationContent()
            content.title = "Barry"
            content.body = summary
            content.sound = .default
            submit(content, id: "overflow-\(decision.banners.first?.id ?? UUID().uuidString)")
        }
    }

    /// Which event a tapped notification was about, so the feed can open it.
    static let eventIdKey = "eventId"

    /// The event a notification tap asked to see, consumed by `RootView`.
    @Published var tappedEventId: String?

    private func submit(_ content: UNMutableNotificationContent, id: String) {
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil)
        )
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// Without a delegate saying otherwise, iOS silently drops notifications
    /// that arrive while the app is frontmost. We only post while the feed is
    /// off screen, so anything reaching here is worth showing — during the
    /// moments the app is running but not `.active`, iOS still counts the app
    /// as foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.content.userInfo[Notifier.eventIdKey] as? String
        Task { @MainActor in
            self.tappedEventId = id
            completionHandler()
        }
    }
}
