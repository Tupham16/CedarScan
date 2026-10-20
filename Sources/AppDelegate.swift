import UIKit
import UserNotifications

/// The app's only UIApplicationDelegate (SwiftUI adaptor in `CedarScanApp`). 🔴 ONE adaptor per
/// app: new UIKit callbacks (APNs, …) go into THIS class, ✗ a second `@UIApplicationDelegateAdaptor`.
/// Also the notification centre's delegate (push notifications, `PushNotifications`).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Recreate the background upload session at once: completions queued while the app was
        // dead are delivered only to a session with the same identifier (→ `UploadJournal`).
        BackgroundUploads.shared.reconnect()
        // Here, ✗ later: a tap that LAUNCHED the app is delivered only to a delegate set before
        // didFinishLaunching returns.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // MARK: Push notifications

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushNotifications.shared.didRegister(deviceToken: deviceToken)
    }

    /// Always the case for AltStore builds (unsigned, no `aps-environment`): log only.
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushNotifications.shared.didFailToRegister(error)
    }

    /// App on screen: show the banner too, and reload the Orders list. The local scan reminder (F2)
    /// only goes to Notification Center: no banner or sound over the app in use (a scan may be
    /// running), nothing to reload.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.identifier.hasPrefix(ScanReminder.idPrefix) {
            completionHandler([.list])
            return
        }
        completionHandler([.banner, .list, .sound])
        Task { @MainActor in PushNotifications.shared.noteArrival() }
    }

    /// Tapped (cold start included): open that order — or, for the local scan reminder (F2,
    /// `ScanReminder`), that scan.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let opened = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let orderId = opened ? userInfo["orderId"] as? String : nil
        let scanId = opened ? ScanReminder.recordId(in: userInfo) : nil
        let projectId = ScanReminder.projectId(in: userInfo)
        completionHandler()
        if let scanId {
            Task { @MainActor in PushNotifications.shared.didTapScan(recordId: scanId, projectId: projectId) }
            return
        }
        guard let orderId, !orderId.isEmpty else { return }
        Task { @MainActor in PushNotifications.shared.didTap(orderId: orderId) }
    }

    /// iOS woke/relaunched the app because scan uploads finished or failed in the background.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundUploads.sessionId else {
            completionHandler()
            return
        }
        BackgroundUploads.shared.setSystemCompletion(completionHandler)
    }
}
