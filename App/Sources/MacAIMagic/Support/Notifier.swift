import AppKit
import UserNotifications

/// macOS notifications: a task is done, needs approval, or went wrong. A click opens its conversation.
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    /// The conversation a click on a notification asks to open.
    @Published var openRequest: UUID?
    private var asked = false

    /// Only in the app itself: the test runner has no bundle that macOS can give notifications to.
    private var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func setUp() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func post(title: String, body: String, conversation: UUID?, id: String = UUID().uuidString) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        let send = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = String(body.prefix(240))
            content.sound = .default
            if let conversation { content.userInfo = ["conversation": conversation.uuidString] }
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
        if asked { send(); return }
        asked = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { send() }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["conversation"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            for w in NSApp.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil) }
            if let id { self.openRequest = id }
        }
        done()
    }

    /// Also while the app is in front: a task finishing in the background is worth seeing.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}
