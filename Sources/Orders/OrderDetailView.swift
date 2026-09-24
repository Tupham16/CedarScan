import SwiftUI

/// What the Orders list pushes: the order ID only (`OrderDTO` is not Hashable) + the tapped row's
/// title. The detail resolves the LIVE order on every render, so a reload after Pay Now, a revision
/// or tour photos shows at once — `ProjectView.OrderSheetTarget`: pin the identity, not the value.
struct OrderRoute: Hashable {
    let orderId: String
    /// Plain data for the navigation bar, captured at tap time (`ProjectView.projectName`).
    let title: String
}

/// One order (mockups 32/33): summary + Pay Now, files, what was ordered, revision / add a scan.
/// Every visibility condition is the 2.45 Orders card's (`orderCard` helpers), copied verbatim;
/// only the layout changed. Downloads stay `Link`s to the browser (App Store rule: no in-app
/// viewer, no thumbnail of a deliverable).
struct OrderDetailView: View {
    let route: OrderRoute
    /// `OrdersView.orders`, read only — a binding so this pushed screen follows every reload.
    @Binding var orders: [OrderDTO]
    /// `OrdersView.errorMessage`, read only: the last refresh failed.
    @Binding var errorMessage: String?
    /// 🔴 Passed by hand, ✗ `@EnvironmentObject`: this is a PUSHED screen (SIGTRAP history,
    /// `ProjectView.store`). Order → project on this device, for "Add a scan".
    @ObservedObject var store: ScanStore
    /// `OrdersView.load()`.
    let reload: () async -> Void
    /// Nhảy sang tab Home và mở dự án — `RootView.requestOpenProject`.
    let onOpenProject: (ScanProject) -> Void
    @State private var revisionOrder: OrderDTO?
    @State private var tourOrder: OrderDTO? // mở màn thêm ảnh Virtual Tour

    /// `nil` = gone from the list (refresh, account switch): `OrdersView` pops this screen.
    private var order: OrderDTO? {
        orders.first { $0.orderId == route.orderId }
    }

    var body: some View {
        ScrollView {
            if let order {
                content(order)
            }
        }
        .fogScreen()
        .refreshable {
            await reload()
        }
        .navigationTitle(route.title)
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
            followUps(order)
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
            HStack(spacing: 8) {
                StatusBadge(status: order.status)
                Spacer(minLength: 8)
                Text(order.orderNumber)
                    .font(.subheadline.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            summaryLine(order)
            payNow(order)
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 15, trailing: 16))
        .detailCard()
    }

    /// The 2.45 header's second line, conditions verbatim; the order number moved up to the badge.
    private func summaryLine(_ order: OrderDTO) -> some View {
        HStack(spacing: 5) {
            Text(OrdersView.formatDate(order.placedAt))
            if let total = order.total, total > 0 {
                Text("· $\(total)")
                if order.paid == true {
                    Text(verbatim: "·")
                    Label(String(localized: "Paid"), systemImage: "checkmark.circle")
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.Badge.ok.fg)
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    /// In-app card sheet when the server offers it, else the browser — see `PaymentFlow`.
    /// Restyled here at the call site only; ✗ edit `PaymentFlow.swift`.
    @ViewBuilder
    private func payNow(_ order: OrderDTO) -> some View {
        if order.paid != true, let payURL = httpsURL(order.paymentUrl) {
            PayNowButton(
                orderId: order.orderId,
                payURL: payURL,
                payInApp: order.payInApp == true,
                onPaid: { Task { await reload() } }
            ) {
                Label(String(localized: "Pay Now"), systemImage: "creditcard")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(FogPrimary(radius: 12))
            .tint(.white) // loading spinner on the blue fill
            .padding(.top, 6)
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
                Text(file.fileName)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let size = file.sizeLabel {
                    Text(size)
                        .foregroundStyle(.secondary)
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
                Image(systemName: "square.and.arrow.up")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
    /// or empty.
    @ViewBuilder
    private func orderedItems(_ order: OrderDTO) -> some View {
        if let items = order.items, !items.isEmpty {
            sectionHeader(String(localized: "What you ordered"))
            VStack(spacing: 0) {
                // Indices, ✗ `enumerated()` + `\.offset`: no key paths into tuples (trap #31).
                ForEach(items.indices, id: \.self) { index in
                    itemRow(items[index], ruled: index > 0)
                }
            }
            .detailCard()
        }
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
        if order.deliveredAt != nil || supplementProject(for: order) != nil {
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
                if let project = supplementProject(for: order) {
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
    private func supplementProject(for order: OrderDTO) -> ScanProject? {
        guard order.status != "refunded" else { return nil }
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
