import SwiftUI

/// Danh sách đơn đã đặt xử lý: trạng thái + file thành phẩm khi đã giao.
struct OrdersView: View {
    @EnvironmentObject private var account: AccountStore
    @State private var orders: [OrderDTO] = []
    /// Danh tính khách mà `orders` hiện thuộc về — để chỉ XOÁ cache khi tài khoản đổi THẬT, không
    /// xoá trên mỗi lần `.task` chạy lại (tránh chớp trắng + giữ được banner "dữ liệu cũ" của [17]).
    @State private var loadedCustomerId: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var revisionOrder: OrderDTO?
    @State private var tourOrder: OrderDTO? // mở màn thêm ảnh Virtual Tour
    @State private var filter: OrderFilter = .all

    var body: some View {
        NavigationStack {
            Group {
                if !account.isSignedIn {
                    signedOutState
                } else if orders.isEmpty && !isLoading {
                    emptyState
                } else {
                    ordersList
                }
            }
            .navigationTitle(L.t("Orders", "Đơn hàng"))
            // Khoá theo DANH TÍNH khách chứ không chỉ theo cờ `isSignedIn`: một máy có thể dùng
            // >1 tài khoản (A đăng xuất → B đăng nhập). Với `id: isSignedIn` thì cache `orders`
            // của A đứng nguyên suốt lúc B chờ mạng — B thấy đơn, tên bản quét, và bấm được
            // "Thanh toán ngay" trỏ vào link chưa-trả của A.
            //
            // XOÁ cache CHỈ khi danh tính đổi thật (so `loadedCustomerId`), KHÔNG xoá vô điều kiện
            // mỗi lần task chạy: nếu TabView cho `.task` chạy lại lúc quay về tab (hành vi tuỳ phiên
            // bản SwiftUI), `orders = []` vô điều kiện sẽ chớp trắng danh sách VÀ phá luôn banner
            // "đang xem dữ liệu cũ" của [17] khi refresh lỗi. `.task(id:)` luôn chạy lại khi id đổi
            // (A→B, đăng xuất→nil) nên nhánh này vẫn bắt được đổi tài khoản.
            .task(id: account.customer?.id) {
                let currentId = account.customer?.id
                if loadedCustomerId != currentId {
                    orders = []
                    errorMessage = nil
                    loadedCustomerId = currentId
                }
                if account.isSignedIn { await load() }
            }
            .refreshable {
                await load()
            }
            .sheet(item: $revisionOrder) { order in
                RevisionSheet(order: order) {
                    Task { await load() }
                }
            }
            .sheet(item: $tourOrder) { order in
                TourPhotosView(orderId: order.orderId)
                    .onDisappear { Task { await load() } }
            }
        }
    }

    private func load() async {
        guard account.isSignedIn else { return }
        isLoading = true
        do {
            orders = try await APIClient.shared.listOrders().orders
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private var signedOutState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(L.t("Sign in to see your orders", "Đăng nhập để xem đơn hàng"))
                .font(.headline)
            Text(L.t("Go to the Account tab to sign in or create an account.",
                     "Vào mục Tài khoản để đăng nhập hoặc đăng ký."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if let errorMessage {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(L.t("Retry", "Thử lại")) { Task { await load() } }
                    .buttonStyle(.bordered)
            } else {
                Image(systemName: "shippingbox")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text(L.t("No orders yet", "Chưa có đơn nào"))
                    .font(.headline)
                Text(L.t(
                    "Open a scan and tap \"Order Floor Plan\" to have our team create professional drawings.",
                    "Mở một bản quét và bấm \"Đặt làm mặt bằng\" để đội ngũ Cedar247 vẽ bản chuyên nghiệp cho bạn."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        }
        .padding(32)
    }

    /// Đơn đang hiển thị theo bộ lọc trạng thái đang chọn.
    private var filteredOrders: [OrderDTO] {
        orders.filter { filter.matches($0.status) }
    }

    /// Hàng nút lọc theo trạng thái + số đếm. Cuộn ngang để không tràn trên máy nhỏ.
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(OrderFilter.allCases) { f in
                    let count = orders.filter { f.matches($0.status) }.count
                    Button {
                        filter = f
                    } label: {
                        Text("\(f.title) (\(count))")
                            .font(.subheadline.weight(filter == f ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                filter == f ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                                in: Capsule()
                            )
                            .foregroundStyle(filter == f ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private var ordersList: some View {
        VStack(spacing: 0) {
            filterBar
            List {
            // Đã có đơn rồi thì `emptyState` (nơi DUY NHẤT render `errorMessage` trước đây) không
            // bao giờ hiện nữa, nên mọi lần refresh lỗi (mất sóng, pull-to-refresh ở công trường)
            // đều im lặng: danh sách CŨ đứng như dữ liệu mới. Banner này báo "đang xem dữ liệu cũ"
            // + cho đường Thử lại chủ động, thay vì để khách tin trạng thái/link thanh toán lỗi thời.
            if let errorMessage {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.exclamationmark")
                            .foregroundStyle(.orange)
                        Text(L.t("Couldn't refresh — showing saved data.",
                                 "Không tải được dữ liệu mới — đang hiện dữ liệu cũ."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L.t("Retry", "Thử lại")) { Task { await load() } }
                            .font(.footnote.weight(.semibold))
                    }
                }
            }
            if filteredOrders.isEmpty {
                Text(L.t("No orders in this category.", "Không có đơn nào ở mục này."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(filteredOrders) { order in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(order.scanName ?? order.orderNumber)
                        .font(.headline)
                    Spacer()
                    StatusBadge(status: order.status)
                }
                HStack(spacing: 6) {
                    Text("\(order.orderNumber) · \(Self.formatDate(order.placedAt))")
                    if let total = order.total, total > 0 {
                        Text("· $\(total)")
                        if order.paid == true {
                            Label(L.t("Paid", "Đã trả"), systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if order.paid != true, let payString = order.paymentUrl, let payURL = URL(string: payString) {
                    Link(destination: payURL) {
                        Label(L.t("Pay Now", "Thanh toán ngay"), systemImage: "creditcard.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                }

                // Virtual Tour: trước khi giao = thêm ảnh phòng; sau khi giao = link tour chia sẻ được
                if order.hasTour == true {
                    if let tourString = order.tourUrl, let tourURL = URL(string: tourString) {
                        HStack(spacing: 12) {
                            Link(destination: tourURL) {
                                Label(L.t("View Virtual Tour", "Xem Virtual Tour"), systemImage: "house.fill")
                                    .font(.subheadline.weight(.semibold))
                            }
                            ShareLink(item: tourURL) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.subheadline)
                            }
                        }
                    } else if order.status != "refunded" {
                        Button {
                            tourOrder = order
                        } label: {
                            Label(
                                (order.tourPhotoCount ?? 0) > 0
                                    ? L.t("Tour photos: \(order.tourPhotoCount ?? 0) — add more",
                                          "Ảnh tour: \(order.tourPhotoCount ?? 0) — thêm ảnh")
                                    : L.t("Add tour photos", "Thêm ảnh cho tour"),
                                systemImage: "photo.on.rectangle.angled"
                            )
                            .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(.indigo)
                    }
                }

                if order.status == "delivered" {
                    if let deliveredUrl = order.deliveredUrl, let url = URL(string: deliveredUrl) {
                        Link(destination: url) {
                            Label(L.t("Download deliverables", "Tải file thành phẩm"), systemImage: "arrow.down.circle.fill")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    ForEach(order.deliveryFiles, id: \.self) { file in
                        if let url = URL(string: file.url) {
                            Link(destination: url) {
                                HStack {
                                    Image(systemName: "doc.fill")
                                    Text(file.fileName)
                                        .lineLimit(1)
                                    if let size = file.sizeLabel {
                                        Text(size)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .font(.caption)
                            }
                        }
                    }
                    Button {
                        revisionOrder = order
                    } label: {
                        Label(L.t("Request a revision", "Yêu cầu sửa"), systemImage: "pencil.and.outline")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)
            }
            }
        }
    }

    private static func formatDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return "" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// Form yêu cầu sửa: khách mô tả chỗ cần chỉnh → đơn quay lại hàng xử lý.
struct RevisionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let order: OrderDTO
    let onSent: () -> Void

    @State private var message = ""
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var sent = false

    var body: some View {
        NavigationStack {
            Form {
                if sent {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.green)
                            Text(L.t("Revision requested!", "Đã gửi yêu cầu sửa!"))
                                .font(.headline)
                            Text(L.t(
                                "Our team will update your floor plan and deliver a revised version.",
                                "Đội ngũ sẽ chỉnh sửa và giao lại bản cập nhật cho bạn."
                            ))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                } else {
                    Section {
                        TextField(
                            L.t("What should we change? (e.g. missing door on Floor 2, wrong room label…)",
                                "Cần sửa gì? (vd thiếu cửa ở Floor 2, sai tên phòng…)"),
                            text: $message,
                            axis: .vertical
                        )
                        .lineLimit(4...8)
                    } header: {
                        Text(order.orderNumber)
                    } footer: {
                        Text(L.t("Revisions for mistakes on our side are free.",
                                 "Sửa lỗi thuộc về chúng tôi là miễn phí."))
                    }
                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle(L.t("Request a revision", "Yêu cầu sửa"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(sent ? L.t("Close", "Đóng") : L.t("Cancel", "Hủy")) { dismiss() }
                }
                if !sent {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            submit()
                        } label: {
                            if isBusy {
                                ProgressView()
                            } else {
                                Text(L.t("Send", "Gửi")).bold()
                            }
                        }
                        .disabled(isBusy || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private func submit() {
        isBusy = true
        errorMessage = nil
        Task {
            do {
                _ = try await APIClient.shared.requestRevision(orderId: order.orderId, message: message)
                sent = true
                onSent()
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }
}

/// Bộ lọc trạng thái ở đầu tab Đơn hàng. "Đang xử lý" gộp mọi trạng thái chưa-giao-chưa-hoàn
/// (gồm cả "đã nhận" cũ — chủ app chốt bỏ nhãn "đã nhận" để khách bớt nôn nóng).
enum OrderFilter: String, CaseIterable, Identifiable {
    case all, processing, ready, refunded
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return L.t("All", "Tất cả")
        case .processing: return L.t("Processing", "Đang xử lý")
        case .ready: return L.t("Ready", "Đã giao")
        case .refunded: return L.t("Refunded", "Hoàn tiền")
        }
    }
    func matches(_ status: String) -> Bool {
        switch self {
        case .all: return true
        case .ready: return status == "delivered"
        case .refunded: return status == "refunded"
        // Mọi thứ chưa giao & chưa hoàn = đang xử lý (received/in_production/on_hold + trạng thái
        // mới trong tương lai) — future-proof, không cần liệt kê từng cái.
        case .processing: return status != "delivered" && status != "refunded"
        }
    }
}

struct StatusBadge: View {
    let status: String

    private var info: (String, Color) {
        switch status {
        case "delivered":
            return (L.t("Delivered", "Đã giao"), .green)
        case "on_hold":
            return (L.t("On hold", "Tạm giữ"), .orange)
        case "refunded":
            return (L.t("Refunded", "Hoàn tiền"), .red)
        // "in_production" VÀ "received"/mặc định đều hiện "Đang xử lý" — chủ app chốt bỏ nhãn
        // "Đã nhận" (khiến khách nôn nóng), gộp vào "đang xử lý".
        default:
            return (L.t("Processing", "Đang xử lý"), .blue)
        }
    }

    var body: some View {
        Text(info.0)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(info.1.opacity(0.15), in: Capsule())
            .foregroundStyle(info.1)
    }
}
