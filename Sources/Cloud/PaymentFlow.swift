import StripePaymentSheet
import UIKit

/// In-app card payment (Stripe PaymentSheet). SKELETON — this commit only proves that the Stripe
/// package resolves, builds and links on CI; the flow itself comes in the next commit.
@MainActor
enum PaymentFlow {
    static func makeSheet(
        clientSecret: String,
        publishableKey: String,
        customerId: String,
        ephemeralKey: String
    ) -> PaymentSheet {
        var configuration = PaymentSheet.Configuration()
        configuration.apiClient = STPAPIClient(publishableKey: publishableKey)
        configuration.merchantDisplayName = "Cedar247"
        configuration.customer = .init(id: customerId, ephemeralKeySecret: ephemeralKey)
        configuration.allowsDelayedPaymentMethods = false
        configuration.link = .init(display: .never)
        return PaymentSheet(paymentIntentClientSecret: clientSecret, configuration: configuration)
    }
}
