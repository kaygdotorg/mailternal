import AppKit
import UserNotifications
import MailternalSync

/// Local new-mail banners and the dock badge. `NSUserNotification` is dead.
final class LiveNotificationService: NSObject, UNUserNotificationCenterDelegate {
    private var requested = false
    private let enabled: Bool

    init(enabled: Bool) {
        self.enabled = enabled
        super.init()
        if enabled {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    /// Lazy permission prompt — first successful account activation.
    func requestAuthorizationIfNeeded() {
        guard enabled, !requested else { return }
        requested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    @MainActor
    func postNewMail(_ event: NewMailEvent, folderVisible: Bool) {
        guard enabled else { return }
        if NSApp.isActive && folderVisible { return }
        let content = UNMutableNotificationContent()
        content.title = event.from.isEmpty ? "New mail" : event.from
        content.body = event.subject
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "mailternal.new.\(event.messageID.rawValue)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func setBadge(_ unread: Int) {
        guard enabled else { return }
        let count = max(0, unread)
        UNUserNotificationCenter.current().setBadgeCount(count)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
