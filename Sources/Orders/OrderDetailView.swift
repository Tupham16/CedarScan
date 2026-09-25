import SwiftUI

/// What the Orders list pushes: the order ID only (`OrderDTO` is not Hashable) + the tapped row's
/// title. The detail resolves the LIVE order on every render, so a reload after Pay Now, a revision
/// or tour photos shows at once — `ProjectView.OrderSheetTarget`: pin the identity, not the value.
struct OrderRoute: Hashable {
    let orderId: String
    /// Plain data for the navigation bar, captured at tap time (`ProjectView.projectName`).
    let title: String
    /// The account whose list it was tapped in.
    let customerId: String?
}

/// One order (mockups 32/33): summary + Pay Now, files, what was ordered, revision / add a scan.
/// Every visibility condition is the 2.45 Orders card's (`orderCard` helpers), copied verbatim;
/// only the layout changed. Downloads stay `Link`s to the browser (App Store rule: no in-app
/// viewer, no thumbnail of a deliverable).
/// Orders v2 C (mockups 36/37, 40): "Add to this order" at the end of "What you ordered", and each
/// purchase made that way as its own card under "Added to this order" (it is its own order on the
/// server: status, Pay Now / Cancel, files).
struct OrderDetailView: View {
    let route: OrderRoute
    /// `OrdersView.orders`, read only — a binding so this pushed screen follows every reload.
    @Binding var orders: [OrderDTO]
    /// `OrdersView.errorMessage`, read only: the last refresh failed.
    @Binding var errorMessage: String?
    /// 🔴 Passed by hand, ✗ `@EnvironmentObject`: this is a PUSHED screen (SIGTRAP history,
    /// `ProjectView.store`). Order → project on this device, for "Add a scan".
    @ObservedObject var store: ScanStore
    /// Passed by hand too. Only read to check the order still belongs to the signed-in account.
    @ObservedObject var account: AccountStore
    /// `OrdersView.load()`.
    let reload: () async -> Void
    /// Nhảy sang tab Home và mở dự án — `RootView.requestOpenProject`.
    let onOpenProject: (ScanProject) -> Void
    @State private var revisionOrder: OrderDTO?
    @State private var tourOrder: OrderDTO? // mở màn thêm ảnh Virtual Tour
    /// Orders v2 B: the "Cancel this order?" alert · why the last cancel was refused. A cancel in
    /// flight lives in `ScanStore.cancellingOrderIds` (app-wide: Back + reopen keeps it).
    @State private var confirmCancel = false
    @State private var cancelError: String?
    /// Orders v2 C: the "Add to this order" sheet · the added items whose Cancel is being confirmed.
    @State private var addTarget: AddToOrderTarget?
    @State private var confirmCancelExtra: OrderDTO?
    /// Read only: a card payment of this order being prepared / settled / just completed.
    @ObservedObject private var flow = PaymentFlow.shared
    @Environment(\.dynamicTypeSize) private var typeSize

    /// `nil` = gone from the list (a refresh) or not this account's (sign-out, account switch):
    /// `OrdersView` pops this screen. The account check is synchronous on purpose — the wipe in
    /// `OrdersView` runs only once the tab shows again, and its first frame must not draw the
    /// previous account's order, Pay Now link or property name.
    private var order: OrderDTO? {
        guard route.customerId == account.customer?.id else { return nil }
        return orders.first { $0.orderId == route.orderId }
    }

    var body: some View {
        ScrollView {
            if let order {
                content(order)
            }
        }
        .fogScreen()
        // Its own task: SwiftUI cancels a refresh whose view goes away (Back), and a cancelled
        // load reads as a failure — a false "Couldn't refresh" on the list.
        .refreshable {
            await Task { await reload() }.value
        }
        .navigationTitle(order == nil ? "" : route.title)
        .navigationBarTitleDisplayMode(.inline)
        // A pushed screen hides the system tab bar itself, as `ProjectView` / `ScanDetailView` do.
        .toolbar(.hidden, for: .tabBar)
        .sheet(item: $revisionOrder) { order in
            RevisionSheet(order: order) {
                Task { await reload() }
            }
        }
        .sheet(item: $tourOrder) { order in
            TourPhotosView(orderId: order.orderId)
                .onDisappear { Task { await reload() } }
        }
        .sheet(item: $addTarget) { target in
            AddToOrderSheet(target: target) {
                Task { await reload() }
            }
        }
        .alert(String(localized: "Cancel these items?"), isPresented: confirmCancelExtraShown, presenting: confirmCancelExtra) { extra in
            Button(String(localized: "Cancel items"), role: .destructive) {
                // The LIVE purchase: a reload while the alert was up may have made it paid.
                if let live = liveOrder(extra.orderId), canCancel(live) { cancelOrder(live, isExtra: true) }
            }
            Button(String(localized: "Keep them"), role: .cancel) {}
        } message: { _ in
            Text(String(localized: "They have not been paid, so nothing is charged."))
        }
        .alert(String(localized: "Cancel this order?"), isPresented: $confirmCancel) {
            Button(String(localized: "Cancel order"), role: .destructive) {
                // The LIVE order: a reload while the alert was up may have made it paid.
                if let order, canCancel(order) { cancelOrder(order, isExtra: false) }
            }
            Button(String(localized: "Keep order"), role: .cancel) {}
        } message: {
            Text(String(localized: "It has not been paid, so nothing is charged. Its scans go back to \"New\", ready to order again."))
        }
        .alert(String(localized: "Order not cancelled"), isPresented: cancelErrorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cancelError ?? "")
        }
    }

    private var cancelErrorShown: Binding<Bool> {
        Binding(get: { cancelError != nil }, set: { if !$0 { cancelError = nil } })
    }

    private var confirmCancelExtraShown: Binding<Bool> {
        Binding(get: { confirmCancelExtra != nil }, set: { if !$0 { confirmCancelExtra = nil } })
    }

    /// An order of this list by id: a listed order, or a purchase added to one (Orders v2 C).
    private func liveOrder(_ orderId: String) -> OrderDTO? {
        for listed in orders {
            if listed.orderId == orderId { return listed }
            if let extra = listed.extras?.first(where: { $0.orderId == orderId }) { return extra }
        }
        return nil
    }

    private func content(_ order: OrderDTO) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if errorMessage != nil {
                RefreshFailedNote { Task { await reload() } }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .detailCard()
                    .padding(.bottom, 12)
            }
            summary(order)
            files(order)
            orderedItems(order)
            addedItems(order)
            followUps(order)
            cancelRow(order)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        // 🔴 Room for `CedarTabBar`: the TabView's inset does not reach a pushed screen
        // (`CedarTabBar.reservedHeight`). Padding, ✗ a second `.safeAreaInset` — same choice as
        // `OrderFAQContent.bottomSpacer`.
        .padding(.bottom, CedarTabBar.reservedHeight + 16)
    }

    // MARK: Summary

    /// Status, number, date · total · Paid, and Pay Now while unpaid.
    private func summary(_ order: OrderDTO) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Accessibility sizes stack both rows: side by side the number gets cut and "Paid"
            // breaks mid-word (simulator renders, AX3).
            if typeSize.isAccessibilitySize {
                StatusBadge(status: order.status)
                orderNumber(order)
            } else {
                // Side by side while both fit at full size; else stacked. "Zahlung ausstehend" at
                // German xxxL left the number cut to "#LS-MS5M494…" (Orders v2 B renders).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        StatusBadge(status: order.status)
                        Spacer(minLength: 8)
                        orderNumber(order)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        StatusBadge(status: order.status)
                        orderNumber(order)
                    }
                }
            }
            summaryLine(order)
            stateNote(order)
            payNow(order)
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 15, trailing: 16))
        .detailCard()
    }

    /// Orders v2 B (mockup 34/35): why an awaiting order is not being drawn, and what a cancelled
    /// one means. `WrappedText`: a sentence the customer must read whole (trap #44).
    @ViewBuilder
    private func stateNote(_ order: OrderDTO) -> some View {
        if showsUnpaidState(order) {
            WrappedText(PayFirstCopy.notPlaced(expires: order.payBy != nil), style: .subheadline)
                .padding(.top, 2)
        } else if order.status == "cancelled" || store.cancelledOrderIds.contains(order.orderId) {
            // `paid` on a cancelled order = money that arrived after the cancel (staff are alerted
            // and refund it — server "TRẢ SAU KHI HUỶ"); once refunded it reads "refunded".
            WrappedText(
                order.paid == true
                    ? String(localized: "This order was cancelled, but a payment reached us afterwards. Our team will refund it.")
                    : String(localized: "Cancelled before it was paid — nothing was charged. Its scans were released, so they can be ordered again."),
                style: .subheadline
            )
            .padding(.top, 2)
        }
    }

    /// Awaiting payment, not just paid in the card sheet (`PaymentFlow` knows before the list) and
    /// not just cancelled here (a 200 whose reload has not landed, or failed).
    private func showsUnpaidState(_ order: OrderDTO) -> Bool {
        order.isAwaitingPayment && !flow.paidOrderIds.contains(order.orderId)
            && !store.cancelledOrderIds.contains(order.orderId)
    }

    /// A Cancel request for this order is in flight (from this screen or an earlier copy of it).
    private func cancelling(_ order: OrderDTO) -> Bool {
        store.cancellingOrderIds.contains(order.orderId)
    }

    /// A card payment of THIS order is being prepared or settled.
    private func paymentBusy(_ order: OrderDTO) -> Bool {
        flow.loadingOrderId == order.orderId || flow.settlingOrderIds.contains(order.orderId)
    }

    private func orderNumber(_ order: OrderDTO) -> some View {
        Text(order.orderNumber)
            .font(.subheadline.monospaced().weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    /// The 2.45 header's second line, conditions verbatim; the order number moved up to the badge.
    @ViewBuilder
    private func summaryLine(_ order: OrderDTO) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                summaryParts(order, dots: false)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 5) {
                summaryParts(order, dots: true)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func summaryParts(_ order: OrderDTO, dots: Bool) -> some View {
        Text(OrdersView.formatDate(order.placedAt))
        if let total = order.total, total > 0 {
            Text(verbatim: dots ? "· $\(total)" : "$\(total)")
            if order.paid == true {
                if dots {
                    Text(verbatim: "·")
                }
                Label(String(localized: "Paid"), systemImage: "checkmark.circle")
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.Badge.ok.fg)
            }
        }
    }

    /// In-app card sheet when the server offers it, else the browser — see `PaymentFlow`.
    /// Restyled here at the call site only; ✗ edit `PaymentFlow.swift`.
    @ViewBuilder
    private func payNow(_ order: OrderDTO) -> some View {
        // ✗ for an order cancelled here whose list entry is still the old "awaiting" one: its pay
        // page is closed (410) and the card sheet refused.
        if order.paid != true, !store.cancelledOrderIds.contains(order.orderId), httpsURL(order.paymentUrl) != nil {
            payNowButton(order)
                .padding(.top, 6)
        } else if showsUnpaidState(order) {
            // Awaiting payment but no pay link (WordPress failed at creation): staff send it by
            // hand — same sentence as the placed screen.
            Text(String(localized: "We will email you a payment link shortly."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    /// Pay Now of an order, or of a purchase added to it (Orders v2 C: same button, same rules).
    @ViewBuilder
    private func payNowButton(_ order: OrderDTO) -> some View {
        if order.paid != true, !store.cancelledOrderIds.contains(order.orderId), let payURL = httpsURL(order.paymentUrl) {
            PayNowButton(
                orderId: order.orderId,
                payURL: payURL,
                payInApp: order.payInApp == true,
                onPaid: { Task { await reload() } },
                // Cancelled (or being cancelled) meanwhile: show its state, ✗ the pay page.
                onOrderChanged: { Task { await reload() } }
            ) {
                Label(String(localized: "Pay Now"), systemImage: "creditcard")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            // `busy`: while THIS order's sheet is prepared / settled the button stays blue at 62%
            // with a white spinner (mockup 19); on the grey disabled fill a white spinner vanished.
            .buttonStyle(FogPrimary(radius: 12, busy: paymentBusy(order)))
            .tint(.white) // loading spinner on the blue fill
            // Not while a cancel runs: the sheet would be refused (`cancel_in_progress`) anyway.
            .disabled(cancelling(order))
        }
    }

    // MARK: Files

    /// "Files" = the 2.45 card's download button, file + tour rows and tour-photos button, each
    /// block with its own condition. This outer `if` is layout only (the union of the three), so an
    /// empty section never shows its title.
    @ViewBuilder
    private func files(_ order: OrderDTO) -> some View {
        let download = order.status == "delivered" && httpsURL(order.deliveredUrl) != nil
        let rows = hasFileRows(order) || (order.hasTour == true && httpsURL(order.tourUrl) != nil)
        let photos = order.hasTour == true && httpsURL(order.tourUrl) == nil && order.status != "refunded"
        if download || rows || photos {
            sectionHeader(String(localized: "Files"))
            VStack(alignment: .leading, spacing: 10) {
                deliverables(order)
                ruledRows(order)
                tourPhotos(order)
            }
            .padding(.horizontal, 16)
            // A ruled row carries its own height (34/40): no inset where one starts or ends the card.
            .padding(.top, download || !rows ? 12 : 0)
            .padding(.bottom, photos || !rows ? 12 : 2)
            .detailCard()
        }
    }

    // 🔴 KHỐI NÀY GÁC `status == "delivered"`, tức FILE THÀNH PHẨM — đúng, vì server
    // chỉ trả `deliveryFiles` khi `stage === "done"`. Nút "Yêu cầu sửa" thì TÁCH RA
    // khối riêng bên dưới: nó phải sống lâu hơn thế.
    // Downloads stay `Link`s to the browser (App Store rule: no in-app viewer).
    @ViewBuilder
    private func deliverables(_ order: OrderDTO) -> some View {
        if order.status == "delivered" {
            if let url = httpsURL(order.deliveredUrl) {
                Link(destination: url) {
                    Label(String(localized: "Download deliverables"), systemImage: "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(FogTint(radius: 12))
            }
        }
    }

    /// Delivered files + tour link as one ruled list (mockup). The outer `if` only skips an
    /// empty block (stray line and spacing); each row keeps its pre-Fog condition.
    /// (2.45 closed the block with a bottom line; inside the card its edge does that.)
    @ViewBuilder
    private func ruledRows(_ order: OrderDTO) -> some View {
        if hasFileRows(order) || (order.hasTour == true && httpsURL(order.tourUrl) != nil) {
            VStack(spacing: 0) {
                if order.status == "delivered" {
                    ForEach(order.files, id: \.self) { file in
                        if let url = httpsURL(file.url) {
                            fileLink(file, url: url)
                        }
                    }
                }
                // Virtual Tour: trước khi giao = thêm ảnh phòng; sau khi giao = link tour chia sẻ được
                if order.hasTour == true, let tourURL = httpsURL(order.tourUrl) {
                    tourLink(tourURL)
                }
            }
        }
    }

    private func hasFileRows(_ order: OrderDTO) -> Bool {
        order.status == "delivered" && order.files.contains { httpsURL($0.url) != nil }
    }

    private func fileLink(_ file: DeliveryFileDTO, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 8) {
                Image(systemName: "doc")
                    .foregroundStyle(Theme.inactive)
                // Concrete colours: `.primary` / `.secondary` inside a Link label render the tint
                // (trap #45) — the mockup shows plain text.
                Text(file.fileName)
                    .lineLimit(1)
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 8)
                if let size = file.sizeLabel {
                    Text(size)
                        .foregroundStyle(Color.secondary)
                }
            }
            .font(.footnote)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .overlay(alignment: .top) { Self.hairline }
    }

    private func tourLink(_ tourURL: URL) -> some View {
        HStack(spacing: 12) {
            Link(destination: tourURL) {
                Label(String(localized: "View Virtual Tour"), systemImage: "house")
                    .font(.subheadline.weight(.semibold))
            }
            Spacer()
            ShareLink(item: tourURL) {
                // Concrete colour, as the file rows (trap #45): the mockup draws this icon grey.
                Image(systemName: "square.and.arrow.up")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }
        }
        .buttonStyle(.borderless)
        .frame(minHeight: 40)
        .overlay(alignment: .top) { Self.hairline }
    }

    /// The pre-Fog `else if` branch of the tour block: tour ordered, no tour link yet.
    @ViewBuilder
    private func tourPhotos(_ order: OrderDTO) -> some View {
        if order.hasTour == true, httpsURL(order.tourUrl) == nil {
            if order.status != "refunded" {
                Button {
                    tourOrder = order
                } label: {
                    Label(
                        (order.tourPhotoCount ?? 0) > 0
                            ? String(localized: "Tour photos: \(order.tourPhotoCount ?? 0) — add more")
                            : String(localized: "Add tour photos"),
                        systemImage: "photo.on.rectangle.angled"
                    )
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(FogTint(radius: 12))
            }
        }
    }

    // MARK: What you ordered

    /// The server's display names (`items`). No section when the list is absent (older server)
    /// or empty — unless "Add to this order" is open (Orders v2 C: its row ends this card).
    private func orderedItems(_ order: OrderDTO) -> some View {
        orderedItemsCard(order, items: order.items ?? [], canAdd: canAddItems(order))
    }

    /// The state as parameters: a local `let` inside a ViewBuilder is where this CI has died of
    /// "type-check timeout" (`ScanAddressView`).
    @ViewBuilder
    private func orderedItemsCard(_ order: OrderDTO, items: [String], canAdd: Bool) -> some View {
        if !items.isEmpty || canAdd {
            sectionHeader(String(localized: "What you ordered"))
            VStack(spacing: 0) {
                // Indices, ✗ `enumerated()` + `\.offset`: no key paths into tuples (trap #31).
                ForEach(items.indices, id: \.self) { index in
                    itemRow(items[index], ruled: index > 0)
                }
                if canAdd {
                    addRow(order, ruled: !items.isEmpty)
                }
            }
            .detailCard()
        }
    }

    /// Orders v2 C: the server allows it (paid, not refunded or closed, nothing added still awaiting
    /// payment, something left to add) and this device is not cancelling the order.
    private func canAddItems(_ order: OrderDTO) -> Bool {
        order.canAddItems == true && !order.isCancelled && !cancelling(order)
            && !store.cancelledOrderIds.contains(order.orderId)
    }

    /// "Add to this order" (mockups 32, 36): opens `AddToOrderSheet`.
    private func addRow(_ order: OrderDTO, ruled: Bool) -> some View {
        Button {
            addTarget = AddToOrderTarget(
                orderId: order.orderId,
                orderNumber: order.orderNumber,
                title: route.title,
                delivered: order.deliveredAt != nil
            )
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle")
                Text(String(localized: "Add to this order"))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            // Concrete colour (trap #45): the mockup draws the row in the accent text colour.
            .foregroundStyle(Theme.accentText)
            .frame(minHeight: 46)
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if ruled {
                Self.hairline.padding(.leading, 44)
            }
        }
    }

    // MARK: Added to this order (Orders v2 C)

    /// Each purchase added to the order, oldest first, as its own card (mockup 40). Cancelled
    /// unpaid ones never come from the server (one paid late does: it gets refunded); one this
    /// device just cancelled is hidden until the reload lands.
    private func addedItems(_ order: OrderDTO) -> some View {
        addedItemsList((order.extras ?? []).filter { !store.cancelledOrderIds.contains($0.orderId) })
    }

    @ViewBuilder
    private func addedItemsList(_ extras: [OrderDTO]) -> some View {
        if !extras.isEmpty {
            sectionHeader(String(localized: "Added to this order"))
            VStack(spacing: 12) {
                ForEach(extras) { extra in
                    extraCard(extra)
                }
            }
        }
    }

    private func extraCard(_ extra: OrderDTO) -> some View {
        let items = extra.items ?? []
        return VStack(alignment: .leading, spacing: 0) {
            extraHeader(extra)
                .padding(EdgeInsets(top: 14, leading: 16, bottom: 4, trailing: 16))
            ForEach(items.indices, id: \.self) { index in
                itemRow(items[index], ruled: index > 0)
            }
            extraState(extra)
        }
        .detailCard()
    }

    /// Status badge + date · total (· Paid), as the summary card; stacked when it does not fit.
    @ViewBuilder
    private func extraHeader(_ extra: OrderDTO) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                StatusBadge(status: extra.status)
                VStack(alignment: .leading, spacing: 4) {
                    summaryParts(extra, dots: false)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    StatusBadge(status: extra.status)
                    Spacer(minLength: 8)
                    extraLine(extra)
                }
                VStack(alignment: .leading, spacing: 6) {
                    StatusBadge(status: extra.status)
                    extraLine(extra)
                }
            }
        }
    }

    private func extraLine(_ extra: OrderDTO) -> some View {
        HStack(spacing: 5) {
            summaryParts(extra, dots: true)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    /// What the purchase asks of the customer, or gives them: Pay / Cancel while it awaits payment,
    /// the files once delivered, the refund note for one paid after it was cancelled.
    @ViewBuilder
    private func extraState(_ extra: OrderDTO) -> some View {
        if showsUnpaidState(extra) {
            VStack(alignment: .leading, spacing: 10) {
                WrappedText(Self.extraNotStarted(expires: extra.payBy != nil), style: .footnote)
                payNowButton(extra)
                Button {
                    confirmCancelExtra = extra
                } label: {
                    if cancelling(extra) {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(String(localized: "Cancelling…"))
                        }
                        .font(.footnote.weight(.semibold))
                        .padding(8)
                        .frame(maxWidth: .infinity, minHeight: 36)
                    } else {
                        ghostLabel(String(localized: "Cancel items"), systemImage: "xmark.circle")
                    }
                }
                .buttonStyle(FogGhost())
                // No second tap while one runs, and not while its card payment is prepared / settled.
                .disabled(cancelling(extra) || paymentBusy(extra))
            }
            .padding(EdgeInsets(top: 6, leading: 16, bottom: 14, trailing: 16))
        } else if extra.isCancelled {
            // Listed only when money reached it after the cancel (server): staff refund it.
            WrappedText(String(localized: "This order was cancelled, but a payment reached us afterwards. Our team will refund it."), style: .footnote)
                .padding(EdgeInsets(top: 6, leading: 16, bottom: 14, trailing: 16))
        } else if extra.status == "delivered" && (httpsURL(extra.deliveredUrl) != nil || hasFileRows(extra)) {
            VStack(alignment: .leading, spacing: 10) {
                deliverables(extra)
                ruledRows(extra)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            // A ruled row carries its own height; the download button alone needs an inset.
            .padding(.bottom, hasFileRows(extra) ? 2 : 14)
        } else {
            Color.clear.frame(height: 6)
        }
    }

    /// Mockup 40. The 7-day sentence only with a `payBy` (a test account's never expire).
    static func extraNotStarted(expires: Bool) -> String {
        let first = String(localized: "Not started yet — we start as soon as it is paid.")
        guard expires else { return first }
        return first + " " + String(localized: "Unpaid additions are cancelled after 7 days.")
    }

    private func itemRow(_ item: String, ruled: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(Theme.Badge.ok.fg)
            Text(Self.itemText(item))
                .font(.subheadline)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 16)
        // Separator from the text on (16 + icon + 10), as in the mockup.
        .overlay(alignment: .top) {
            if ruled {
                Self.hairline.padding(.leading, 44)
            }
        }
    }

    /// "Color floor plan · Classic": the picked template in grey (the server joins it with " · ").
    private static func itemText(_ item: String) -> AttributedString {
        guard let dot = item.range(of: " · ") else { return AttributedString(item) }
        var grey = AttributeContainer()
        // Keyed by type: `.foregroundColor` alone can be ambiguous (SwiftUI vs UIKit scope).
        grey[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = Color.secondary
        var text = AttributedString(String(item[..<dot.lowerBound]))
        text.append(AttributedString(String(item[dot.lowerBound...]), attributes: grey))
        return text
    }

    // MARK: Revision / add a scan

    /// "Request a revision" + "Add a scan", side by side when both show. The outer `if` only
    /// avoids an empty row (stray spacing); each button keeps its own condition.
    @ViewBuilder
    private func followUps(_ order: OrderDTO) -> some View {
        if order.deliveredAt != nil || supplementTarget(for: order) != nil {
            HStack(spacing: 8) {
                // 🔴 "YÊU CẦU SỬA" GÁC THEO `deliveredAt`, ✗ theo `status == "delivered"` —
                // sửa 19/08, vòng soi đối kháng bắt.
                //
                // Từ 19/08, gửi bổ sung vào một đơn ĐÃ GIAO kéo thẻ `done → fix`, tức `status` đổi
                // thành `in_production`. Gác theo `status` là nút "Yêu cầu sửa" **BIẾN MẤT IM LẶNG**
                // ngay sau khi khách gửi bổ sung — trong khi mục Hỏi đáp vừa hứa với họ HAI đường
                // song song trong cửa sổ 90 ngày ("bản vẽ sai → Yêu cầu sửa" / "quét sót → Gửi bổ
                // sung"). Khách phát hiện thêm một lỗi vẽ sẽ không còn nút nào để báo.
                //
                // `deliveredAt != null` là "đơn này đã từng được giao", và nó KHÔNG bị cú kéo cột
                // xoá đi (`refundOrder`/`holdOrder`/`supplement-scan` đều không đụng trường đó) —
                // đúng thứ cần gác. Server vẫn tự lo phần còn lại: `revision/route.ts` nhận cả khi
                // thẻ đang ở "fix" (nay ghi được cả `feedback`, sửa cùng lượt).
                if order.deliveredAt != nil {
                    Button {
                        revisionOrder = order
                    } label: {
                        ghostLabel(String(localized: "Request a revision"), systemImage: "pencil.and.outline")
                    }
                    .buttonStyle(FogGhost())
                }
                // 🆕 "THÊM BẢN QUÉT" — chủ app đặt 19/08: *"thêm nút thêm bản quét, khi kích vào
                // đó nó nhảy qua dự án đó"*. Nó chữa một lỗ THẬT: khách nhận bản vẽ, thấy thiếu
                // một khu, và không có đường nào từ đơn hàng ngược về căn nhà để quét thêm — họ
                // phải tự đoán là mình cần sang tab Home tìm đúng dự án.
                //
                // 🔴 CHỈ ĐIỀU HƯỚNG, ✗ gửi gì cả. Việc gửi vẫn là `SupplementSheet` ở trang dự án
                // — LỐI VÀO DUY NHẤT, ✗ nhân bản luồng gửi ở tab này (thứ trôi được giữa hai bản
                // sao là cú ĐÓNG DẤU số đơn, mà thiếu dấu = khách TRẢ TIỀN HAI LẦN).
                if let project = supplementTarget(for: order) {
                    Button {
                        onOpenProject(project)
                    } label: {
                        ghostLabel(String(localized: "Add a scan"), systemImage: "plus.viewfinder")
                    }
                    .buttonStyle(FogGhost())
                }
            }
            .padding(.top, 12)
        }
    }

    // MARK: Cancel (Orders v2 B)

    /// "Cancel order" ghost (mockup 34/35), only while the order awaits payment: an older-rule
    /// unpaid order has no Cancel (the server answers `not_cancellable`), a paid one never.
    @ViewBuilder
    private func cancelRow(_ order: OrderDTO) -> some View {
        if showsUnpaidState(order) {
            Button {
                confirmCancel = true
            } label: {
                if cancelling(order) {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(String(localized: "Cancelling…"))
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(8)
                    .frame(maxWidth: .infinity, minHeight: 36)
                } else {
                    ghostLabel(String(localized: "Cancel order"), systemImage: "xmark.circle")
                }
            }
            .buttonStyle(FogGhost())
            // No second tap while one runs (the server would only wait for the first), and not
            // while this order's card payment is being prepared or settled.
            .disabled(cancelling(order) || paymentBusy(order))
            .padding(.top, 12)
        }
    }

    private func canCancel(_ order: OrderDTO) -> Bool {
        showsUnpaidState(order) && !cancelling(order) && !paymentBusy(order)
    }

    /// `POST orders/{id}/cancel` (up to ~45 s). Its own task, ✗ tied to this screen: Back during
    /// the wait must not cancel it half way — the stamps must be released when it answers.
    /// `isExtra`: a purchase added to the order (Orders v2 C) — same route, no scans of its own.
    private func cancelOrder(_ order: OrderDTO, isExtra: Bool) {
        guard !cancelling(order) else { return }
        let orderId = order.orderId
        let number = order.orderNumber
        store.beginCancel(orderId: orderId)
        Task { @MainActor in
            var failure: String?
            var cancelled = false
            var transport = false
            do {
                let reply = try await APIClient.shared.cancelOrder(orderId: orderId)
                // Its scans are "New" again on this device (only those still stamped with it).
                if !isExtra {
                    store.releaseCancelledOrder(orderNumber: reply.orderNumber ?? number, scanIds: reply.scanIds ?? [])
                }
                cancelled = true
            } catch {
                failure = Self.cancelFailure(error)
                transport = !(error is APIError)
            }
            store.endCancel(orderId: orderId, cancelled: cancelled)
            // Whatever happened: a refusal means "paid" or "try later", a lost answer may hide a
            // cancel that went through — the list says which (and releases stamps for a cancel it
            // shows). So it is read BEFORE a lost answer may be called a failure.
            await reload()
            // A purchase added to the order that is gone from the list was cancelled (the server lists
            // cancelled ones only when money reached them).
            if transport, liveOrder(orderId).map({ !$0.isAwaitingPayment }) ?? isExtra {
                failure = nil
            }
            cancelError = failure
        }
    }

    /// The refusal in the customer's words (server codes, PLAN-DON-HANG-V2.md §4a). nil = nothing
    /// to say: the request was dropped, or the order is gone (the reload pops this screen).
    private static func cancelFailure(_ error: Error) -> String? {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return nil }
        let api = error as? APIError
        switch api?.code {
        case "already_paid":
            return String(localized: "This order has already been paid.")
        case "payment_processing":
            return String(localized: "A payment for this order is still being processed. Please check again in a few minutes.")
        case "not_cancellable":
            return String(localized: "This order can't be cancelled in the app. Please contact our team.")
        default:
            if api?.statusCode == 404 { return nil }
            return String(localized: "We couldn't cancel this order right now. Please try again in a few minutes.")
        }
    }

    /// `supplementProject`, and not while this device cancels the order (or just did): a scan sent
    /// then would join an order about to be cancelled (Orders v2 B).
    private func supplementTarget(for order: OrderDTO) -> ScanProject? {
        guard !cancelling(order), !store.cancelledOrderIds.contains(order.orderId) else { return nil }
        return supplementProject(for: order)
    }

    /// Dự án TRÊN MÁY NÀY của đơn — `nil` thì KHÔNG hiện nút "Thêm bản quét".
    ///
    /// Hai ca trả nil, cả hai là hành vi ĐÚNG chứ ✗ lỗi:
    ///  · **Đơn đã hoàn tiền** — `supplement-scan` từ chối bằng `order_closed`, nên hiện nút là
    ///    dẫn khách đi quét 10–30 phút rồi tải 40–200MB lên để nhận một lời từ chối. Chặn ở đây,
    ///    chỗ RẺ NHẤT. (Đơn ĐÃ GIAO thì KHÔNG chặn: server nhận nó từ 19/08 — xem
    ///    `supplement-scan/route.ts`, chủ app chốt "đã đặt hay đã giao đều không tính phí".)
    ///  · **Máy này không giữ dự án đó** — khách xoá rồi, hoặc đang dùng máy khác. Không có bản
    ///    quét gốc trên máy thì cũng chẳng có gì để quét bổ sung vào.
    ///  · **Dự án đó nay thuộc về một số đơn KHÁC** — xem khối 🔴 ngay dưới.
    ///  · **Đơn đã huỷ khi chưa trả (Orders v2 B)** — cùng lý do với đơn hoàn tiền: server từ
    ///    chối (`order_closed`), và bản quét của nó đã về "New" để đặt đơn mới.
    private func supplementProject(for order: OrderDTO) -> ScanProject? {
        guard order.status != "refunded", !order.isCancelled else { return nil }
        guard let project = store.project(withOrderNumber: order.orderNumber) else { return nil }
        // 🔴 CHỐT CHỐNG GỬI NHẦM ĐƠN. Nút này chỉ ĐIỀU HƯỚNG; việc gửi ở trang dự án lại hỏi
        // `ScanStore.orderNumber(ofProject:)`, hàm đó lấy số đơn của bản quét MỚI NHẤT. Một dự án
        // ôm HAI số đơn là chuyện tới được trong app hôm nay (kéo một bản quét đã đặt lẻ vào một
        // dự án đã có đơn — `moveScan`), và khi đó bấm nút ở đơn CŨ sẽ đưa khách tới trang dự án
        // rồi gửi bản quét vào đơn MỚI. Sai đơn = đội vẽ nhận file cho một căn nhà khác.
        // ⇒ Chỉ hiện nút khi hai chiều đồng ý với nhau. Lệch thì ẨN — khách vẫn còn đường vào từ
        // tab Home, và ẩn một nút còn hơn gửi nhầm không ai biết.
        guard store.orderNumber(ofProject: project.id) == order.orderNumber else { return nil }
        return project
    }

    private func ghostLabel(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
            .font(.footnote.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 36)
    }

    // MARK: Look

    /// Fog section title: 13pt semibold grey, as `HomeView.sectionHeader`.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 18)
            .padding(.bottom, 8)
    }

    /// 1px divider inside a card.
    private static var hairline: some View {
        Theme.hairline.frame(height: 1)
    }
}

/// Orders v2 B wording shared by the order detail and the placed screen (`OrderSheet`).
enum PayFirstCopy {
    /// Mockup 34/35. The 7-day sentence only when the server gave a `payBy`: a test account's
    /// order never expires (the App Review demo order), and there the sentence would be false.
    static func notPlaced(expires: Bool) -> String {
        let first = String(localized: "Not placed yet — we start drawing as soon as it is paid.")
        guard expires else { return first }
        return first + " " + String(localized: "Unpaid orders are cancelled after 7 days.")
    }
}

private extension View {
    /// Fog card outside a List: radius 16 + hairline border (`fogCardRow` draws the same in a List).
    func detailCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return self
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Theme.card))
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
    }
}
