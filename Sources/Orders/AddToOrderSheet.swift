import SwiftUI

/// What `OrderDetailView` opens "Add to this order" for — `.sheet(item:)` (trap #7): the order's
/// identity + plain display data captured at tap time.
struct AddToOrderTarget: Identifiable {
    let orderId: String
    let orderNumber: String
    let title: String
    /// The order's drawing is delivered: new items start once paid. Otherwise they also wait for
    /// that delivery (owner 25/09: colour / CAD / site plan need the drawing first).
    let delivered: Bool
    var id: String { orderId }
}

/// Orders v2 C — "Add to this order" (mockups 36/37, done screen mockup 40): buy catalog items the
/// order does not have yet, at the catalog price, for an order already paid. Server:
/// order-webapp `src/lib/order-extras.ts`. The purchase is its OWN order there (number
/// "<order>_A<n>"), paid like any order (`PayNowButton` on its id); the order detail lists it under
/// "Added to this order".
///
/// Money rules — read before changing anything here:
///  1. Prices come from the server (`GET orders/{id}/extras`). The button shows their sum and the
///     purchase sends that sum as `expectedTotal`: the server refuses any other price
///     (`price_changed`), so "Pay · $X" is the price asked.
///  2. ONE purchase per sheet. After it the choice is locked and the button pays THAT purchase. A
///     lost answer is safe: the server keeps one unpaid purchase per order and answers another try
///     with `extra_awaiting`; the order detail then shows the purchase with Pay Now / Cancel.
///  3. The payment starts by itself (card sheet, or the payment page) only when the server's EXACT
///     amount is the price the button showed. A customer coupon WordPress took off, or an amount the
///     server could not learn, is shown on the button first and waits for another tap.
///  4. ✗ edit `PaymentFlow.swift` from here: restyle at the call site, as the order detail does.
struct AddToOrderSheet: View {
    let target: AddToOrderTarget
    /// Reload the Orders list (the purchase shows inside the order). No default (trap #13).
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    /// Read only: the card sheet of the purchase being prepared / settled / paid.
    @ObservedObject private var flow = PaymentFlow.shared

    @State private var offer: ExtrasOffer?
    @State private var loadError: String?
    @State private var selectedPackages: Set<String> = []
    @State private var selectedAddons: Set<String> = []
    /// Add-on id → template id (colour / site plan), as in the order form.
    @State private var selectedTemplates: [String: String] = [:]
    /// The purchase request is out: no second tap, no closing (the answer carries the purchase).
    @State private var busy = false
    @State private var errorMessage: String?
    /// The purchase this sheet made — one at most (rule 2).
    @State private var created: AddExtrasResponse?
    /// The total the button showed at the tap, in dollars (rule 3).
    @State private var shownTotal = 0
    /// The server said the purchase is paid (a browser payment: `PaymentFlow` never hears of it).
    @State private var serverPaid = false
    /// A purchase whose answer was lost, found in the order afterwards (`failed`): the names of
    /// its items, for the done screen.
    @State private var addedUnanswered: [String]?
    @State private var showTerms = false

    var body: some View {
        NavigationStack {
            Group {
                if let created, isDone(created) {
                    doneView(amount: created.free == true ? nil : amountText(created), items: created.items)
                } else if let addedUnanswered {
                    doneView(amount: nil, items: addedUnanswered)
                } else if let offer {
                    form(offer)
                } else if let loadError {
                    VStack(spacing: 12) {
                        Text(loadError)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(String(localized: "Retry")) {
                            self.loadError = nil
                            Task { await load() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(24)
                } else {
                    ProgressView(String(localized: "Loading options…"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(String(localized: "Add to this order"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // The done screen closes with its own Done button (mockup 40).
                    if !showsDone {
                        Button(created == nil ? String(localized: "Cancel") : String(localized: "Close")) {
                            dismiss()
                        }
                        .disabled(busy)
                    }
                }
            }
            .task {
                await load()
            }
        }
        // A purchase in flight is not something a swipe can take back (its answer holds the order).
        .interactiveDismissDisabled(busy)
        // Whatever happened to the purchase, the order detail must show it.
        .onDisappear {
            if created != nil { onChanged() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { recheckPaid() }
        }
    }

    // MARK: State

    /// Paid in the card sheet, paid per the server (browser), or free by a coupon (placed at once).
    private func isDone(_ purchase: AddExtrasResponse) -> Bool {
        purchase.free == true || purchase.status == "received"
            || flow.paidOrderIds.contains(purchase.orderId) || serverPaid
    }

    private var showsDone: Bool {
        (created.map { isDone($0) } ?? false) || addedUnanswered != nil
    }

    /// The price the button showed is the exact amount the server will charge (rule 3).
    private func exactAsShown(_ purchase: AddExtrasResponse) -> Bool {
        purchase.amountCents == shownTotal * 100
    }

    /// A card payment of the purchase is being prepared or settled.
    private func paymentBusy(_ orderId: String) -> Bool {
        flow.loadingOrderId == orderId || flow.settlingOrderIds.contains(orderId)
    }

    /// Sum of the chosen items not yet in the order, at the offer's prices.
    private var total: Int {
        guard let offer else { return 0 }
        let packages = offer.packages.filter { !$0.included && selectedPackages.contains($0.id) }
        let addons = offer.addons.filter { !$0.included && selectedAddons.contains($0.id) }
        return (packages + addons).reduce(0) { $0 + $1.price }
    }

    /// After the purchase nothing can be changed any more (rule 2).
    private var locked: Bool { busy || created != nil }

    private func load() async {
        do {
            let fresh = try await APIClient.shared.extrasOffer(orderId: target.orderId)
            apply(fresh)
            // The order detail offered "Add" but a purchase still awaits payment: its list is stale
            // (a lost answer, another device). Read it again so that purchase shows there with Pay /
            // Cancel — the message below sends the customer to it.
            if fresh.code == "extra_awaiting" { onChanged() }
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// A fresh offer: the customer's picks that are still for sale stay picked.
    private func apply(_ fresh: ExtrasOffer) {
        offer = fresh
        let packages = Set(fresh.packages.filter { !$0.included }.map { $0.id })
        let addons = Set(fresh.addons.filter { !$0.included }.map { $0.id })
        selectedPackages.formIntersection(packages)
        selectedAddons.formIntersection(addons)
        selectedTemplates = selectedTemplates.filter { addons.contains($0.key) && selectedAddons.contains($0.key) }
    }

    /// "$42", or "$37.80" when a coupon left cents. The app writes amounts as "$" + number everywhere.
    static func dollars(cents: Int) -> String {
        cents % 100 == 0 ? "$\(cents / 100)" : String(format: "$%.2f", Double(cents) / 100)
    }

    private func amountText(_ purchase: AddExtrasResponse) -> String? {
        if let cents = purchase.amountCents { return Self.dollars(cents: cents) }
        return nil
    }

    // MARK: Buying

    private func submit() {
        guard let offer, created == nil, !busy else { return }
        // Everything that decides the price, taken at the tap (trap #22).
        let packageIds = offer.packages.filter { !$0.included && selectedPackages.contains($0.id) }.map { $0.id }
        let addonIds = offer.addons.filter { !$0.included && selectedAddons.contains($0.id) }.map { $0.id }
        let templates = selectedTemplates.filter { addonIds.contains($0.key) }
        let expected = total
        let names = (offer.packages + offer.addons).filter { (packageIds + addonIds).contains($0.id) }.map { $0.name }
        guard !(packageIds.isEmpty && addonIds.isEmpty), expected > 0 else { return }
        busy = true
        errorMessage = nil
        Task { @MainActor in
            do {
                let purchase = try await APIClient.shared.addExtras(
                    orderId: target.orderId,
                    packageIds: packageIds,
                    addonIds: addonIds,
                    templates: templates,
                    expectedTotal: expected
                )
                shownTotal = expected
                created = purchase
                onChanged()
                // Rule 3. The card sheet opens from `PayNowButton(opensOnAppear:)`; the payment page
                // opens here — the customer just tapped "Pay", and this sheet could not be closed
                // meanwhile.
                if !isDone(purchase), exactAsShown(purchase), purchase.payInApp != true,
                   let url = httpsURL(purchase.paymentUrl) {
                    openURL(url)
                }
            } catch {
                await failed(error, sentIds: packageIds + addonIds, names: names)
            }
            busy = false
        }
    }

    /// The purchase was refused or its answer lost. The offer is read again: it tells a lost answer
    /// that DID buy from a refusal, and brings the current prices. A purchase to pay reads
    /// `extra_awaiting`; one a coupon made free reads as its items now `included`.
    private func failed(_ error: Error, sentIds: [String], names: [String]) async {
        // Whatever happened, the order detail reads its list again: a lost answer may have bought.
        defer { onChanged() }
        let code = (error as? APIError)?.code
        if let fresh = try? await APIClient.shared.extrasOffer(orderId: target.orderId) {
            apply(fresh)
            if fresh.code == "extra_awaiting" {
                errorMessage = nil
                return
            }
            // Only an unknown outcome (no answer, a gateway error, an answer that could not be
            // read): a refusal (4xx) bought nothing, even when something else put these items in
            // the order meanwhile.
            let refused = (error as? APIError).map { (400..<500).contains($0.statusCode) } ?? false
            if !refused, Self.allIncluded(sentIds, in: fresh) {
                errorMessage = nil
                addedUnanswered = names
                return
            }
        }
        switch code {
        case "price_changed", "already_included", "item_unavailable":
            errorMessage = String(localized: "Prices or items have changed. Please check your choice and the total.")
        default:
            errorMessage = error.localizedDescription
        }
    }

    /// Every id sent is now in the order.
    static func allIncluded(_ ids: [String], in offer: ExtrasOffer) -> Bool {
        let included = Set((offer.packages + offer.addons).filter { $0.included }.map { $0.id })
        return !ids.isEmpty && ids.allSatisfy { included.contains($0) }
    }

    /// Back from the payment page: ask the server, so this sheet says "Added" to someone who paid.
    /// Only a positive "paid" counts. WordPress reports a browser payment a moment later: asked once
    /// more after a few seconds (as the "Order placed" screen does).
    private func recheckPaid() {
        guard let purchase = created, !isDone(purchase) else { return }
        Task {
            for attempt in 0..<2 {
                if attempt > 0 { try? await Task.sleep(nanoseconds: 5_000_000_000) }
                if let list = try? await APIClient.shared.listOrders(),
                   let parent = list.orders.first(where: { $0.orderId == target.orderId }),
                   let live = parent.extras?.first(where: { $0.orderId == purchase.orderId }),
                   live.paid == true, !live.isCancelled {
                    serverPaid = true
                    onChanged()
                    return
                }
            }
        }
    }

    // MARK: Form

    /// Fog form, as the order form (`OrderSheet`): one function per Section (CI type-check timeouts).
    private func form(_ offer: ExtrasOffer) -> some View {
        Form {
            if offer.canAdd || created != nil {
                packagesSection(offer)
                addonsSection(offer)
                paySection
            } else {
                blockedSection(offer)
            }
        }
        .fogScreen()
    }

    /// Section title: 13pt semibold, concrete `Color.secondary` (trap #47a).
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.secondary)
            .textCase(nil)
    }

    /// Nothing can be added right now: say why, in the customer's words.
    private func blockedSection(_ offer: ExtrasOffer) -> some View {
        Section {
            WrappedText(Self.blockedText(offer.code), style: .subheadline)
                .padding(.vertical, 4)
                .listRowBackground(Theme.card)
        } header: {
            contextHeader
        }
    }

    static func blockedText(_ code: String?) -> String {
        switch code {
        case "extra_awaiting":
            return String(localized: "You added items to this order that are waiting for payment. Pay for them or cancel them in the order first.")
        case "nothing_to_add":
            return String(localized: "Everything we offer is already in this order.")
        default:
            return String(localized: "Items can't be added to this order right now.")
        }
    }

    /// "48 Harbor View · #10391" (mockup 36).
    private var contextHeader: some View {
        Text(verbatim: "\(target.title) · \(target.orderNumber)")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.primary)
            .textCase(nil)
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private func packagesSection(_ offer: ExtrasOffer) -> some View {
        Section {
            Group {
                ForEach(offer.packages) { item in
                    packageRow(item)
                }
            }
            .listRowBackground(Theme.card)
        } header: {
            VStack(alignment: .leading, spacing: 10) {
                contextHeader
                sectionHeader(String(localized: "Packages"))
            }
        }
    }

    @ViewBuilder
    private func packageRow(_ item: ExtrasOfferItem) -> some View {
        if item.included {
            includedRow(item.name, check: true)
        } else {
            Button {
                if selectedPackages.contains(item.id) {
                    selectedPackages.remove(item.id)
                } else {
                    selectedPackages.insert(item.id)
                }
            } label: {
                HStack {
                    Image(systemName: selectedPackages.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(.tint)
                    // Concrete colours in a Button label (trap #45).
                    Text(item.name)
                        .foregroundStyle(Color.primary)
                    Spacer()
                    Text(verbatim: "$\(item.price)")
                        .foregroundStyle(Color.secondary)
                }
            }
            .disabled(locked)
        }
    }

    /// Already in the order: grey, "Included" (mockup 36).
    private func includedRow(_ name: String, check: Bool) -> some View {
        HStack {
            if check {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.inactive)
            }
            Text(name)
                .foregroundStyle(Color.secondary)
            Spacer()
            Text(String(localized: "Included"))
                .foregroundStyle(Color.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func addonsSection(_ offer: ExtrasOffer) -> some View {
        if !offer.addons.isEmpty {
            Section {
                Group {
                    ForEach(offer.addons) { item in
                        addonRow(item)
                    }
                }
                .listRowBackground(Theme.card)
            } header: {
                sectionHeader(String(localized: "Add-ons"))
            } footer: {
                Text(target.delivered
                     ? String(localized: "We start on the new items as soon as they are paid. Their files arrive in this order.")
                     : String(localized: "We start on the new items once they are paid and your current drawing is delivered. Their files arrive in this order."))
            }
        }
    }

    @ViewBuilder
    private func addonRow(_ item: ExtrasOfferItem) -> some View {
        if item.included {
            includedRow(item.name, check: false)
        } else {
            Toggle(isOn: addonBinding(item)) {
                HStack {
                    Text(item.name)
                    Spacer()
                    Text(verbatim: "+$\(item.price)")
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(locked)
            // An add-on with styles (colour, site plan) + switched on → its picker, as in the order form.
            if selectedAddons.contains(item.id), let templates = item.templates, !templates.isEmpty {
                TemplatePicker(templates: templates, selection: templateBinding(item.id))
                    .disabled(locked)
            }
        }
    }

    /// Switching on an add-on with styles picks its first style (the server records "no template
    /// chosen" otherwise) — as `OrderSheet.addonBinding`.
    private func addonBinding(_ item: ExtrasOfferItem) -> Binding<Bool> {
        Binding(
            get: { selectedAddons.contains(item.id) },
            set: { on in
                if on {
                    selectedAddons.insert(item.id)
                    if selectedTemplates[item.id] == nil, let first = item.templates?.first?.id {
                        selectedTemplates[item.id] = first
                    }
                } else {
                    selectedAddons.remove(item.id)
                    selectedTemplates.removeValue(forKey: item.id)
                }
            }
        )
    }

    private func templateBinding(_ addonId: String) -> Binding<String?> {
        Binding(
            get: { selectedTemplates[addonId] },
            set: { selectedTemplates[addonId] = $0 }
        )
    }

    // MARK: Pay

    private var paySection: some View {
        Section {
            Group {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if let created {
                    purchaseNote(created)
                }
            }
            .listRowBackground(Theme.card)
            payButton
                // Stands alone on the screen background, as "Place order" (trap #47b: clear row).
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        } footer: {
            // The contract point shows the terms right here (as the order form, 2.35).
            Button {
                showTerms = true
            } label: {
                Text(String(localized: "By paying you agree to the Terms and Conditions."))
                    .font(.footnote)
                    .foregroundStyle(Theme.accentText)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .sheet(isPresented: $showTerms) {
                NavigationStack { LegalDocumentView(doc: .terms) }
            }
        }
    }

    /// After the purchase: why the button's amount moved (a coupon), or that it waits for payment.
    @ViewBuilder
    private func purchaseNote(_ purchase: AddExtrasResponse) -> some View {
        if let discount = purchase.discount, discount > 0 {
            Text(String(localized: "Coupon applied: −$\(String(format: "%.2f", discount))"))
                .font(.footnote)
                .foregroundStyle(Theme.Badge.ok.fg)
        }
        // The purchase exists now (awaiting payment): closing this sheet leaves it in the order.
        Text(String(localized: "You can also pay later in the Orders tab."))
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var payButton: some View {
        if let created, let payURL = httpsURL(created.paymentUrl) {
            PayNowButton(
                orderId: created.orderId,
                payURL: payURL,
                payInApp: created.payInApp == true,
                // Rule 3: by itself only at the price the customer tapped.
                opensOnAppear: exactAsShown(created),
                onPaid: { onChanged() },
                // Cancelled meanwhile (another device, or it expired): the order shows its state.
                onOrderChanged: {
                    onChanged()
                    dismiss()
                }
            ) {
                payLabel(amountText(created))
            }
            // `busy`: blue at 62% with a white spinner while its card sheet is prepared (mockup 19).
            .buttonStyle(FogPrimary(busy: paymentBusy(created.orderId)))
            .tint(.white)
        } else if created != nil {
            // Awaiting payment with no pay link: cannot happen today (the server always gives one).
            Text(String(localized: "We will email you a payment link shortly."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        } else {
            Button {
                submit()
            } label: {
                if busy {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                } else {
                    payLabel(total > 0 ? "$\(total)" : nil)
                }
            }
            .buttonStyle(FogPrimary(busy: busy))
            .disabled(busy || total == 0)
        }
    }

    /// "Pay · $42" (✗ "Pay %@": that key is Stripe's own, trap #42) or "Pay" when unknown.
    private func payLabel(_ amount: String?) -> some View {
        Text(amount.map { String(localized: "Pay") + " · " + $0 } ?? String(localized: "Pay"))
            .font(.headline)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
    }

    // MARK: Done (mockup 40)

    /// Centred; scrolls only when it does not fit (large text), as the "Order placed" screen.
    /// `amount`: what was paid (nil when free, or unknown).
    private func doneView(amount: String?, items: [String]?) -> some View {
        GeometryReader { proxy in
            ScrollView {
                doneContent(amount: amount, items: items)
                    .padding(24)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func doneContent(amount: String?, items: [String]?) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.Badge.ok.fg)
                .frame(width: 76, height: 76)
                .background(Circle().fill(Theme.Badge.ok.bg))
            Text(String(localized: "Added to your order"))
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            if let amount {
                Text(verbatim: amount + " · " + String(localized: "Paid"))
                    .font(.headline)
            }
            if let names = Self.itemNames(items) {
                Text(verbatim: names)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Text(target.delivered
                 ? String(localized: "We start on it now. Its files arrive in this order in the Orders tab.")
                 : String(localized: "We start on it once your current drawing is delivered. Its files arrive in this order in the Orders tab."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                dismiss()
            } label: {
                Text(String(localized: "Done"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(FogPrimary())
            .padding(.top, 12)
        }
    }

    /// "3D Floor Plan · Site plan": the server's names without the picked style ("Site plan · Style 2").
    static func itemNames(_ items: [String]?) -> String? {
        let names = (items ?? []).compactMap { $0.components(separatedBy: " · ").first }.filter { !$0.isEmpty }
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }
}
