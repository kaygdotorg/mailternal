#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
import UserNotifications
import MailternalSync

/// Local new-mail banners and the app badge. `NSUserNotification` is dead.
/// The notification service is shared by the macOS and iOS live facades; only
/// the frontmost-app check differs because iOS has no `NSApplication`.
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
        #if os(macOS)
        let applicationIsActive = NSApp.isActive
        #elseif os(iOS)
        let applicationIsActive = UIApplication.shared.applicationState == .active
        #else
        let applicationIsActive = false
        #endif
        if applicationIsActive && folderVisible { return }
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

