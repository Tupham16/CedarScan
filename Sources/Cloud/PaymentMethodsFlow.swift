import StripePaymentSheet
import SwiftUI
import UIKit

/// Account → "Payment methods" (owner 28/09, like CubiCasa): Stripe's CustomerSheet lists, adds,
/// removes and picks the default saved card. No money moves here. Server: order-webapp
/// `openPaymentMethods` / `createSetupIntentFor` in `src/lib/stripe-payments.ts`.
///
/// Same Stripe customer and same ephemeral-key integration as `PaymentFlow`, so a card saved here
/// is offered by Pay Now, and the default picked here is the one Pay Now preselects (both read
/// Stripe's local "last selected" store for that customer id).
@MainActor
final class PaymentMethodsFlow: ObservableObject {
    static let shared = PaymentMethodsFlow()

    enum Outcome {
        case closed
        /// The server does not offer saved payment methods to this account (any more): hide the row.
        case unavailable
        case failed
    }

    @Published private(set) var isLoading = false

    private init() {}

    /// - Parameter tabWhenAsked: `PaymentFlow.visibleTab` at the tap — the sheet only comes up on
    ///   that tab (same rule as Pay Now).
    func open(tabWhenAsked: RootTab?) async -> Outcome {
        guard !isLoading, let presenter = PaymentFlow.topViewController() else { return .closed }
        isLoading = true
        let params: PaymentMethodsParams
        do {
            params = try await APIClient.shared.paymentMethods()
            isLoading = false
        } catch {
            isLoading = false
            if Task.isCancelled { return .closed }
            return (error as? APIError)?.code == "in_app_disabled" ? .unavailable : .failed
        }
        guard !Task.isCancelled,
              PaymentFlow.visibleTab == tabWhenAsked,
              PaymentFlow.topViewController() === presenter,
              presenter.presentedViewController == nil else { return .closed }

        STPAPIClient.shared.publishableKey = params.publishableKey
        var firstKey: PaymentMethodsParams? = params
        let adapter = StripeCustomerAdapter(
            customerEphemeralKeyProvider: {
                // The key fetched above first; a fresh one when the SDK's 30-min cache runs out.
                let p: PaymentMethodsParams
                if let cached = firstKey {
                    firstKey = nil
                    p = cached
                } else {
                    p = try await APIClient.shared.paymentMethods()
                }
                return CustomerEphemeralKey(customerId: p.customer, ephemeralKeySecret: p.ephemeralKey)
            },
            setupIntentClientSecretProvider: {
                try await APIClient.shared.paymentMethodsSetupIntent().setupIntent
            },
            // Cards only (the server's SetupIntent is card-only).
            paymentMethodTypes: ["card"]
        )
        var configuration = CustomerSheet.Configuration()
        configuration.merchantDisplayName = params.merchantDisplayName ?? "Cedar247"
        configuration.applePayEnabled = false
        let sheet = CustomerSheet(configuration: configuration, customer: adapter)
        let result = await sheet.present(from: presenter)
        if case .error = result { return .failed }
        return .closed
    }
}
