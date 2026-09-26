import UIKit

/// The app's only UIApplicationDelegate (SwiftUI adaptor in `CedarScanApp`). 🔴 ONE adaptor per
/// app: new UIKit callbacks (APNs, …) go into THIS class, ✗ a second `@UIApplicationDelegateAdaptor`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Recreate the background upload session at once: completions queued while the app was
        // dead are delivered only to a session with the same identifier (→ `UploadJournal`).
        BackgroundUploads.shared.reconnect()
        return true
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
