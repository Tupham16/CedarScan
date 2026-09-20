import StripePaymentSheet
import SwiftUI
import UIKit

/// In-app card payment for ONE unpaid order (Stripe PaymentSheet). It runs NEXT TO the browser pay
/// page (`paymentUrl`), never instead of it. Server side: order-webapp `src/lib/stripe-payments.ts`.
///
/// Money rules — read before changing anything here:
///  1. The app sends no amount and holds no key. `payment-sheet` returns the PaymentIntent, the
///     customer's ephemeral key and the publishable key (test accounts get Stripe TEST keys on prod).
///  2. Anything but a 200 from `payment-sheet` means "pay in the browser, as before". The only
///     exception is `already_paid`.
///  3. Every sheet that goes up leaves a MARKER on disk until the server has said what became of
///     it. `payment-confirm` is one of three things that settle a charge on the server (webhook ·
///     this call · hourly sweep); the app calls it when the sheet closes — whatever the sheet
///     reported — and again on launch / foreground / Orders refresh while a marker is left.
///  4. "Paid" is shown only after the sheet reported `.completed` or the server said paid.
///  5. The browser is never opened for an order whose sheet completed.
@MainActor
final class PaymentFlow: ObservableObject {
    static let shared = PaymentFlow()

    enum Outcome {
        case paid
        /// Nothing happened: the customer closed the sheet, or the screen that asked went away.
        case canceled
        /// In-app payment is not available for this order right now: open `paymentUrl`.
        case useBrowser
    }

    /// The order whose sheet is being prepared. One at a time; Pay Now is disabled meanwhile.
    /// Cleared BEFORE the sheet goes up, so a sheet that never reports back cannot lock Pay Now.
    @Published private(set) var loadingOrderId: String?
    /// Orders whose sheet has closed and whose fate is being asked of the server. EVERY Pay Now waits
    /// (as for `loadingOrderId`), so a late "use the browser" can never land on top of another
    /// attempt — of this order or of any other. Bounded by the request timeout, unlike a sheet.
    @Published private(set) var settlingOrderIds: Set<String> = []
    /// Orders paid here during this run, plus the completed-but-unconfirmed ones from disk.
    @Published private(set) var paidOrderIds: Set<String> = []

    /// The tab `RootView` is showing, which only `RootView` writes. The sheet must come up on the
    /// tab that asked for it: every tab lives in ONE `UIHostingController`, so `topViewController()`
    /// returns the same object after a tab switch and cannot see it on its own (measured on device
    /// 20/09: Pay Now in Orders, switch tab at once, and the sheet rose over the new tab).
    /// It is compared as a SNAPSHOT (value when asked == value now), so `nil` is safe only while it
    /// STAYS `nil`: today nothing ever writes `nil` back, and at cold launch `RootView.onAppear`
    /// runs before any Pay Now can exist. ✗ add a `nil` reset (an `.onDisappear` companion, a
    /// per-scene rewrite for iPad windows) — a request in flight would then be cancelled for a
    /// change that never happened.
    static var visibleTab: RootTab?

    private struct Marker: Codable {
        let orderId: String
        /// The account that paid: the server answers 404 for anybody else's order.
        let customerId: String?
        let at: Date
        /// true = the sheet reported `.completed`: shown as "Paid", kept until the server agrees.
        /// false = the sheet went up and the outcome is not known for sure (app killed during 3-D
        /// Secure, answer lost on the way back): asked about, NEVER shown as paid.
        let completed: Bool
    }

    private var markers: [Marker]
    /// The order whose sheet is on screen: "unpaid" says nothing about it yet.
    private var presentingOrderId: String?
    private static let storeKey = "paymentFlow.markers.v1"
    /// Past these ages a marker is dropped: the server's hourly sweep settles what the app could not.
    private static let keepCompleted: TimeInterval = 30 * 86_400
    private static let keepOpened: TimeInterval = 86_400
    /// "Unpaid" is no proof for a sheet that was just closed: a 3-D Secure approval may still land.
    private static let openedGrace: TimeInterval = 3_600

    private init() {
        let saved = UserDefaults.standard.data(forKey: Self.storeKey)
            .flatMap { try? JSONDecoder().decode([Marker].self, from: $0) } ?? []
        let now = Date()
        markers = saved.filter {
            now.timeIntervalSince($0.at) < ($0.completed ? Self.keepCompleted : Self.keepOpened)
        }
        paidOrderIds = Set(markers.filter { $0.completed }.map { $0.orderId })
    }

    // MARK: Paying

    /// - Parameter tabWhenAsked: `PaymentFlow.visibleTab` as it was when the CUSTOMER asked. It is
    ///   passed in rather than read here so that the sheet and the browser are both judged against
    ///   the same moment — the tap — instead of against whenever this call happened to start.
    func pay(orderId: String, tabWhenAsked: RootTab?) async -> Outcome {
        guard loadingOrderId == nil, settlingOrderIds.isEmpty else { return .canceled }
        // A keyboard left up (the Orders search field) would cover the lower half of the sheet.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        // The screen that asks is the only one the sheet may appear on.
        guard let presenter = Self.topViewController() else { return .useBrowser }

        loadingOrderId = orderId
        let params: PaymentSheetParams
        do {
            params = try await APIClient.shared.paymentSheet(orderId: orderId)
            loadingOrderId = nil
        } catch {
            loadingOrderId = nil
            if (error as? APIError)?.code == "already_paid" {
                paidOrderIds.insert(orderId)
                return .paid
            }
            return Task.isCancelled ? .canceled : .useBrowser
        }
        // Gone, covered, on its way out, or navigated away from while the request was out. (A cover
        // still animating away is skipped by `topViewController()` but not by Stripe's own guard.)
        guard !Task.isCancelled,
              Self.visibleTab == tabWhenAsked,
              Self.topViewController() === presenter,
              presenter.presentedViewController == nil else { return .canceled }

        STPAPIClient.shared.publishableKey = params.publishableKey
        var configuration = PaymentSheet.Configuration()
        configuration.merchantDisplayName = params.merchantDisplayName ?? "Cedar247"
        configuration.customer = .init(id: params.customer, ephemeralKeySecret: params.ephemeralKey)
        // Cards only (the server creates the PaymentIntent that way): paid or declined on the spot.
        configuration.allowsDelayedPaymentMethods = false
        // Link off: no sign-up step, nothing but the card is collected. If it is ever turned on,
        // call `PaymentSheet.resetCustomer()` on sign-out.
        configuration.link = .init(display: .never)
        let sheet = PaymentSheet(paymentIntentClientSecret: params.paymentIntent, configuration: configuration)

        mark(orderId, completed: false)
        presentingOrderId = orderId
        let result: PaymentSheetResult = await withCheckedContinuation { continuation in
            sheet.present(from: presenter) { continuation.resume(returning: $0) }
        }
        presentingOrderId = nil
        // Stamped again at the close: the marker's age limits count from here.
        if case .completed = result {
            mark(orderId, completed: true)
        } else {
            mark(orderId, completed: false)
        }
        // Asked whatever the sheet said. "Canceled" is also what a charge looks like whose answer got
        // lost on the way back: the sheet shows an error, the customer closes it.
        // Its own task: the caller's task dies with its view, and would take this request along.
        settlingOrderIds.insert(orderId)
        let answer = await Task { await self.ask(orderId) }.value
        settlingOrderIds.remove(orderId)
        settle(orderId, answer)

        switch result {
        case .completed:
            return .paid
        case .canceled:
            return answer == .paid ? .paid : .canceled
        case .failed:
            // The sheet could not run at all (card errors are shown inside it and keep it open).
            switch answer {
            case .paid: return .paid
            case .processing: return .canceled
            case .unpaid, .unreachable: return .useBrowser
            }
        }
    }

    // MARK: Telling the server

    /// Ask the server about every marker of the signed-in account. Runs on launch, on return to the
    /// foreground and when the Orders list loads. No markers = no request.
    func confirmPending() async {
        guard !markers.isEmpty else { return }
        let me = AccountStore.savedCustomerId
        for marker in markers where marker.customerId == nil || marker.customerId == me {
            settle(marker.orderId, await ask(marker.orderId))
        }
    }

    private enum ServerAnswer { case paid, processing, unpaid, unreachable }

    /// Every failure is `.unreachable`, a 404 included (route not deployed, order deleted): the
    /// marker then simply lives until its age limit.
    private func ask(_ orderId: String) async -> ServerAnswer {
        guard let answer = try? await APIClient.shared.paymentConfirm(orderId: orderId) else {
            return .unreachable
        }
        if answer.paid { return .paid }
        return answer.processing == true ? .processing : .unpaid
    }

    private func settle(_ orderId: String, _ answer: ServerAnswer) {
        guard let marker = markers.first(where: { $0.orderId == orderId }) else {
            if answer == .paid { paidOrderIds.insert(orderId) }
            return
        }
        switch answer {
        case .paid:
            // `paidOrderIds` keeps the id: the row stays "Paid" until the list reloads.
            paidOrderIds.insert(orderId)
            unmark(orderId)
        case .unpaid:
            // A completed sheet outweighs "unpaid" (the server raised its own alert): keep asking.
            if !marker.completed, orderId != presentingOrderId,
               Date().timeIntervalSince(marker.at) > Self.openedGrace {
                unmark(orderId)
            }
        case .processing, .unreachable:
            break
        }
    }

    private func mark(_ orderId: String, completed: Bool) {
        if completed { paidOrderIds.insert(orderId) }
        markers.removeAll { $0.orderId == orderId }
        markers.append(Marker(
            orderId: orderId,
            customerId: AccountStore.savedCustomerId,
            at: Date(),
            completed: completed
        ))
        save()
    }

    private func unmark(_ orderId: String) {
        markers.removeAll { $0.orderId == orderId }
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(markers), forKey: Self.storeKey)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var top = window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed {
            top = next
        }
        return top
    }
}

/// The one Pay Now control — Orders tab and the "Order placed" screen. It owns the ACTION only: the
/// caller passes the label and applies the button style, so restyling never touches the money path.
struct PayNowButton<Content: View>: View {
    private let orderId: String
    private let payURL: URL
    private let payInApp: Bool
    private let opensOnAppear: Bool
    private let onPaid: () -> Void
    private let label: () -> Content

    @Environment(\.openURL) private var openURL
    @ObservedObject private var flow = PaymentFlow.shared
    @State private var task: Task<Void, Never>?
    @State private var openedOnAppear = false
    /// In-app payment was refused for this order: later taps go straight to the browser.
    @State private var browserOnly = false

    /// - Parameters:
    ///   - payInApp: the server's hint. false = the browser pay page, exactly as before.
    ///   - opensOnAppear: open the sheet once, unasked, when the button appears (after Place order).
    init(
        orderId: String,
        payURL: URL,
        payInApp: Bool,
        opensOnAppear: Bool = false,
        onPaid: @escaping () -> Void = {},
        @ViewBuilder label: @escaping () -> Content
    ) {
        self.orderId = orderId
        self.payURL = payURL
        self.payInApp = payInApp
        self.opensOnAppear = opensOnAppear
        self.onPaid = onPaid
        self.label = label
    }

    private var isLoading: Bool {
        flow.loadingOrderId == orderId || flow.settlingOrderIds.contains(orderId)
    }

    var body: some View {
        if flow.paidOrderIds.contains(orderId) {
            Label(String(localized: "Paid"), systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
        } else {
            Button {
                start(tapped: true)
            } label: {
                label()
                    .opacity(isLoading ? 0 : 1)
                    .overlay { if isLoading { ProgressView() } }
            }
            .disabled(flow.loadingOrderId != nil || !flow.settlingOrderIds.isEmpty)
            .onAppear {
                guard opensOnAppear, !openedOnAppear else { return }
                openedOnAppear = true
                start(tapped: false)
            }
            // A sheet still being prepared must not pop up over another screen.
            .onDisappear { task?.cancel() }
        }
    }

    private func start(tapped: Bool) {
        // The tab this tap happened on. Nothing below may land on any other one: the same value
        // guards the sheet (passed into `pay`) and the browser (here). Both are needed — `pay`
        // answers "use the browser" from THREE places, two of which come back after a round trip.
        let tabWhenAsked = PaymentFlow.visibleTab
        guard payInApp, !browserOnly else {
            // Straight from the tap, no waiting in between: the tab cannot have changed yet.
            if tapped { openURL(payURL) }
            return
        }
        task = Task {
            switch await flow.pay(orderId: orderId, tabWhenAsked: tabWhenAsked) {
            case .paid:
                onPaid()
            case .canceled:
                break
            case .useBrowser:
                browserOnly = true
                // An unasked open stops here: the customer has not tapped anything yet. A customer
                // who left for another tab is not sent to Safari either — Pay Now still works, and
                // from here on it opens the browser straight away.
                if tapped, !Task.isCancelled, PaymentFlow.visibleTab == tabWhenAsked {
                    openURL(payURL)
                }
            }
        }
    }
}
