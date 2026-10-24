import BackgroundTasks
import UIKit
import UserNotifications

/// Owns the long-lived AppModel and handles the system callbacks SwiftUI doesn't expose:
/// APNs registration, notification actions and BGTaskScheduler (which must be registered
/// before launch finishes).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let refreshTaskId = "com.berkgozek.AlphaBeta.refresh"

    @MainActor lazy var model = AppModel()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationCategories.register()
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskId, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Task { @MainActor in
                AppDelegate.scheduleRefresh()
                let work = Task { await self.model.backgroundRefresh() }
                task.expirationHandler = { work.cancel() }
                await work.value
                task.setTaskCompleted(success: !work.isCancelled)
            }
        }
        // Relaunched by significant-change location monitoring: the location manager delegate
        // receives the pending update once AlphaMonitor recreates it during bootstrap.
        return true
    }

    /// iOS decides when (and whether) this actually runs — typically every 15 min to hours.
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in await model.updatePushToken(token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in model.pushRegistrationFailed = true }
    }

    // Show alerts while the app is open, too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await MainActor.run { model.notificationArrived() }
        return [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        // Only string values are used (alphaId, alertId, type); copy them before crossing actors.
        let info = response.notification.request.content.userInfo.reduce(into: [String: String]()) { out, kv in
            if let k = kv.key as? String, let v = kv.value as? String { out[k] = v }
        }
        let action = response.actionIdentifier
        await MainActor.run { model.handleNotification(action: action, userInfo: info) }
    }
}

enum NotificationCategories {
    static let alphaAlert = "ALPHA_ALERT"
    static let acknowledge = "ACKNOWLEDGE"
    static let fallPrompt = "FALL_PROMPT"
    static let fallOk = "FALL_OK"
    static let fallHelp = "FALL_HELP"

    static func register() {
        let ack = UNNotificationAction(identifier: acknowledge, title: "Acknowledge", options: [.authenticationRequired])
        let ok = UNNotificationAction(identifier: fallOk, title: "I'm okay", options: [])
        let help = UNNotificationAction(identifier: fallHelp, title: "I need help", options: [.destructive, .foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: alphaAlert, actions: [ack], intentIdentifiers: []),
            UNNotificationCategory(identifier: fallPrompt, actions: [ok, help], intentIdentifiers: []),
        ])
    }
}
