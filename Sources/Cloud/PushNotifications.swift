import UIKit
import UserNotifications

/// Push notifications about the customer's orders (owner 26/09, `PLAN-THONG-BAO-DAY.md`). Server:
/// order-webapp `src/lib/push-events.ts` + `api/app/v1/push/{register,unregister}`.
///
/// · Permission is asked only after an order is placed (`OrderSheet` closing) or when the Orders
///   list shows ≥1 order — only while `.notDetermined`, ✗ at first launch.
/// · Allowed + signed in ⇒ `registerForRemoteNotifications()` at launch / sign-in / foreground; the
///   token reaches the server from `didRegister` (`AppDelegate`).
/// · Sign-out (`AccountStore.signOut`, the one choke point) ⇒ unregister; offline ⇒ kept in
///   `pendingUnregisterKey` and retried until 2xx or until the same token registers again.
/// · 🔴 AltStore builds (build.yml, unsigned, no `aps-environment`) always fail to register: log
///   only, once per launch, ✗ UI, ✗ retry loop.
/// · Tap ⇒ `tapped` ⇒ `RootView` (Orders tab) ⇒ `openOrder` ⇒ `OrdersView` pushes the order.
@MainActor
final class PushNotifications: ObservableObject {
    static let shared = PushNotifications()

    /// A tapped notification's order: `orderId` = ROOT order id of GET orders (an added item's push
    /// carries its parent's). `seq`: the same order tapped twice must still fire `onChange`.
    struct OrderRequest: Equatable {
        let seq: Int
        let orderId: String
    }

    /// Set by a tap (cold start included: stays until `RootView` reads it). Only `RootView` consumes.
    @Published var tapped: OrderRequest?
    /// Handed from `RootView` to `OrdersView` once the tab switch is allowed. Only `OrdersView` clears.
    @Published var openOrder: OrderRequest?
    /// Bumped when a notification arrives while the app is on screen: the Orders list reloads.
    @Published private(set) var arrivals = 0

    private var seq = 0
    /// This launch's device token (hex). nil until iOS answers `registerForRemoteNotifications`.
    private var token: String?
    /// "<customerId> <token>" the server last accepted, this launch. Skips repeat registers.
    private var registeredKey: String?
    /// The same key while its register is queued / out: ✗ send it twice.
    private var inFlightKey: String?
    /// iOS refused a token this launch (AltStore build, no network to Apple…): ✗ ask again until relaunch.
    private var registrationFailed = false
    /// All network calls in order: a sign-out's unregister must not overtake an earlier register,
    /// nor a later sign-in's register overtake the unregister.
    private var chain: Task<Void, Never>?

    /// The last token iOS gave (any launch): sign-out unregisters it even before this launch's arrives.
    private static let tokenKey = "push.token"
    /// A token whose unregister has not reached the server yet (plan §1).
    private static let pendingUnregisterKey = "push.pendingUnregister"

    private init() {}

    private var center: UNUserNotificationCenter { .current() }
    private var isSignedIn: Bool { APIClient.shared.token != nil }

    // MARK: Launch / sign-in / foreground

    /// Launch, sign-in/out (`RootView.task(id: isSignedIn)`) and every return to the foreground:
    /// retries a pending unregister, then asks iOS for the token when allowed + signed in. Cheap:
    /// a request only when something is owed.
    func refresh() {
        retryPendingUnregister()
        guard isSignedIn else { return }
        if let token {
            // Token known (earlier this launch): make sure the server has it for THIS account.
            send(register: token)
            return
        }
        guard !registrationFailed else { return }
        Task {
            let status = await center.notificationSettings().authorizationStatus
            guard Self.allowed(status), isSignedIn, token == nil, !registrationFailed else { return }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// The moment to ask (plan §2.4): an order was just placed, or the Orders list has orders.
    /// Only while iOS has never asked; granted ⇒ register at once.
    func askIfUndetermined() {
        guard isSignedIn else { return }
        Task {
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            guard granted, isSignedIn, !registrationFailed else { return }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    private static func allowed(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }

    // MARK: AppDelegate callbacks

    func didRegister(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        token = hex
        UserDefaults.standard.set(hex, forKey: Self.tokenKey)
        guard isSignedIn else { return }
        send(register: hex)
    }

    func didFailToRegister(_ error: Error) {
        registrationFailed = true
        print("[push] no device token:", error.localizedDescription)
    }

    /// A notification arrived while the app is on screen.
    func noteArrival() {
        arrivals += 1
    }

    func didTap(orderId: String) {
        seq += 1
        tapped = OrderRequest(seq: seq, orderId: orderId)
    }

    // MARK: Sign-out

    /// Called by `AccountStore.signOut` BEFORE the session is dropped (also account deletion and a
    /// 401 sign-out). No auth needed server-side. Fire and forget; kept for a retry until 2xx.
    func signingOut() {
        registeredKey = nil
        openOrder = nil
        tapped = nil
        guard let hex = token ?? UserDefaults.standard.string(forKey: Self.tokenKey) else { return }
        UserDefaults.standard.set(hex, forKey: Self.pendingUnregisterKey)
        retryPendingUnregister()
    }

    // MARK: Network (serialised)

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    private func send(register hex: String) {
        guard let customerId = AccountStore.savedCustomerId else { return }
        let key = "\(customerId) \(hex)"
        guard registeredKey != key, inFlightKey != key else { return }
        inFlightKey = key
        enqueue { [weak self] in
            guard let self else { return }
            defer { if self.inFlightKey == key { self.inFlightKey = nil } }
            // Signed out / switched account while queued: the next refresh registers for the new one.
            guard self.isSignedIn, AccountStore.savedCustomerId == customerId else { return }
            do {
                try await APIClient.shared.registerPushToken(hex, environment: Self.environment)
                self.registeredKey = key
                // The same token registered again = the phone is signed in, the old unregister is moot.
                if UserDefaults.standard.string(forKey: Self.pendingUnregisterKey) == hex {
                    UserDefaults.standard.removeObject(forKey: Self.pendingUnregisterKey)
                }
            } catch {
                // 400 / 401 / 429 / offline: nothing shown; next launch or foreground tries again.
                print("[push] register failed:", error.localizedDescription)
            }
        }
    }

    private func retryPendingUnregister() {
        guard let hex = UserDefaults.standard.string(forKey: Self.pendingUnregisterKey) else { return }
        enqueue {
            // Already sent (an earlier queued retry), or re-registered since.
            guard UserDefaults.standard.string(forKey: Self.pendingUnregisterKey) == hex else { return }
            do {
                try await APIClient.shared.unregisterPushToken(hex)
                Self.clearPending(hex)
            } catch let error as APIError where error.statusCode == 400 {
                // The server will never accept this token: stop retrying.
                Self.clearPending(hex)
            } catch {
                print("[push] unregister failed:", error.localizedDescription)
            }
        }
    }

    private static func clearPending(_ hex: String) {
        if UserDefaults.standard.string(forKey: pendingUnregisterKey) == hex {
            UserDefaults.standard.removeObject(forKey: pendingUnregisterKey)
        }
    }

    /// Both CI workflows build Release; TestFlight / App Store = production APNs.
    private static var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    // MARK: Navigation guard

    /// A tap may switch tab and push an order only over a plain screen: ✗ over the scan cover (a
    /// scan in progress), a sheet, the card sheet or an alert — the request is dropped then.
    static var somethingOnTop: Bool {
        let cover = ScanCoverModel.shared
        if cover.content != nil || cover.blocksInput { return true }
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let root = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController else {
            return false
        }
        return root.presentedViewController != nil
    }
}

/// The server's `loc-key`s (`push-events.ts`): iOS itself looks them up in Localizable.strings to
/// show a push in the phone's language; `%@` = the house name or the order number (`loc-args`).
/// Listed here only so the keys are visibly in use; never resolved in the app (✗ `String(localized:)`
/// on them: a `%@` without an argument). 🔴 Each key byte-identical to the server's; a changed
/// sentence = a new key on BOTH sides + `Localization/translations.json`.
enum PushText {
    static let keys: [LocalizedStringResource] = [
        "Your order for %@ is ready.",
        "Your added items for %@ are ready.",
        "The revised files for %@ are ready.",
        "We sent you a message about your order for %@. Please check your email.",
        "Your order for %@ is awaiting payment. It will be cancelled within 24 hours if unpaid.",
        "Your added items for %@ are awaiting payment. They will be cancelled within 24 hours if unpaid.",
        "Your order for %@ was cancelled because it was not paid within 7 days.",
        "Your added items for %@ were cancelled because they were not paid within 7 days.",
    ]
}
