import SwiftUI
import UniformTypeIdentifiers // UTType — suy ra MIME cho file đính kèm của "Yêu cầu sửa"

/// Danh sách đơn đã đặt xử lý: trạng thái + file thành phẩm khi đã giao.
struct OrdersView: View {
    @EnvironmentObject private var account: AccountStore
    /// 🔴 TRUYỀN TAY từ `RootView`, cùng khuôn `HomeView`. Tab này KHÔNG push màn nào nên
    /// `@EnvironmentObject` ở đây vốn an toàn — truyền tay để hai tab đọc store theo MỘT cách.
    /// Dùng cho ĐÚNG một việc: tra đơn → dự án trên máy, cho nút "Thêm bản quét".
    @ObservedObject var store: ScanStore
    /// Nhảy sang tab Home và mở dự án — `RootView.requestOpenProject`. Tab này ✗ tự đổi tab.
    let onOpenProject: (ScanProject) -> Void
    @State private var orders: [OrderDTO] = []
    /// Chữ trong ô tìm kiếm. Lọc theo SỐ ĐƠN và TÊN BẢN QUÉT — hai thứ duy nhất khách nhìn thấy
    /// trên mỗi dòng, nên cũng là hai thứ duy nhất họ gõ lại được.
    @State private var searchText = ""
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
            .navigationTitle(String(localized: "Orders"))
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
                    // Dọn CẢ ô tìm kiếm và bộ lọc, không chỉ `orders`: cả hai là `@State` của
                    // OrdersView nên chúng sống suốt vòng đời app, không chết theo tài khoản.
                    // A đăng xuất → B đăng nhập, B thấy ô tìm kiếm ĐÃ ĐIỀN SẴN số đơn của A (một
                    // mẩu dữ liệu của người khác) và danh sách rỗng kèm câu "không có đơn nào
                    // khớp" — B kết luận mình không có đơn nào.
                    searchText = ""
                    filter = .all
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
            Text(String(localized: "Sign in to see your orders"))
                .font(.headline)
            Text(String(localized: "Go to the Account tab to sign in or create an account."))
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
                Button(String(localized: "Retry")) { Task { await load() } }
                    .buttonStyle(.bordered)
            } else {
                Image(systemName: "shippingbox")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text(String(localized: "No orders yet"))
                    .font(.headline)
                Text(String(localized: "Open a scan and tap \"Order Floor Plan\" to have our team create professional drawings."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        }
        .padding(32)
    }

    /// Đơn khớp ô TÌM KIẾM (chưa áp bộ lọc trạng thái).
    ///
    /// Số đếm trên các nút lọc tính TRÊN TẬP NÀY, không phải trên toàn bộ `orders`: nút ghi "(3)"
    /// mà bấm vào chỉ ra 1 đơn — vì 2 đơn kia bị ô tìm kiếm loại — là con số nói dối.
    private var searchedOrders: [OrderDTO] {
        let key = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return orders }
        return orders.filter {
            TextMatch.contains($0.orderNumber, key) || TextMatch.contains($0.scanName ?? "", key)
        }
    }

    /// Đơn đang hiển thị: khớp cả ô tìm kiếm lẫn bộ lọc trạng thái đang chọn.
    /// Dự án TRÊN MÁY NÀY của đơn — `nil` thì KHÔNG hiện nút "Thêm bản quét".
    ///
    /// (Chú thích của `filteredOrders` nằm NGAY DƯỚI hàm này, ✗ trên nó — hàm này chen vào giữa
    /// 19/08. Đọc đúng khối cho đúng hàm.)
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

    private var filteredOrders: [OrderDTO] {
        searchedOrders.filter { filter.matches($0.status) }
    }

    /// Câu giải thích khi danh sách rỗng — phải nói đúng NGUYÊN NHÂN.
    ///
    /// Có đơn khớp từ khoá nhưng bị chip trạng thái chặn mà lại báo "không khớp từ khoá" thì khách
    /// đi sửa từ khoá, trong khi việc phải làm là bấm sang chip khác. (Con số trên chip vốn đã
    /// đúng — nó đếm trên `searchedOrders` — chỉ mỗi câu này từng chỉ sai hướng.)
    private var emptyListNote: String {
        // Đang tải LẦN ĐẦU (chưa có đơn nào trong tay) cũng rơi vào đây — `ordersList` được chọn
        // khi `orders.isEmpty && isLoading`. Không có nhánh này thì màn hình khẳng định "Không có
        // đơn nào" đúng lúc dữ liệu còn đang trên đường về.
        if isLoading && orders.isEmpty {
            return String(localized: "Loading your orders…")
        }
        let hasQuery = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasQuery && searchedOrders.isEmpty {
            return String(localized: "No orders match your search.")
        }
        if filter != .all {
            return String(localized: "No orders in this category — try another filter above.")
        }
        return String(localized: "No orders in this category.")
    }

    /// Các nút lọc thật sự hiện ra.
    ///
    /// "Tất cả" LUÔN hiện; trạng thái khác chỉ hiện khi có đơn — bày 5 nút mà 4 nút ghi (0) là màn
    /// hình bẩn với khách chỉ có một đơn. NHƯNG nút ĐANG CHỌN luôn được giữ lại kể cả khi về 0:
    /// nút biến mất ngay dưới ngón tay là danh sách rỗng mà không còn gì nói cho khách biết vì sao.
    private var visibleFilters: [OrderFilter] {
        OrderFilter.allCases.filter { f in
            f == .all || f == filter || searchedOrders.contains { f.matches($0.status) }
        }
    }

    /// Hàng nút lọc theo trạng thái + số đếm. Cuộn ngang để không tràn trên máy nhỏ.
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(visibleFilters) { f in
                    filterChip(f)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    /// Tách thành hàm riêng — CI của repo này từng chết vì "Swift type-check timeout" với biểu
    /// thức SwiftUI lớn, mà đây là chỗ có `let` cục bộ + nhiều modifier điều kiện.
    private func filterChip(_ f: OrderFilter) -> some View {
        let count = searchedOrders.filter { f.matches($0.status) }.count
        let isOn = filter == f
        return Button {
            filter = f
        } label: {
            Text("\(f.title) (\(count))")
                .font(.subheadline.weight(isOn ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isOn ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                    in: Capsule()
                )
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
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
                        Text(String(localized: "Couldn't refresh — showing saved data."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(String(localized: "Retry")) { Task { await load() } }
                            .font(.footnote.weight(.semibold))
                    }
                }
            }
            if filteredOrders.isEmpty {
                Text(emptyListNote)
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
                            Label(String(localized: "Paid"), systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if order.paid != true, let payURL = httpsURL(order.paymentUrl) {
                    Link(destination: payURL) {
                        Label(String(localized: "Pay Now"), systemImage: "creditcard.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                }

                // Virtual Tour: trước khi giao = thêm ảnh phòng; sau khi giao = link tour chia sẻ được
                if order.hasTour == true {
                    if let tourURL = httpsURL(order.tourUrl) {
                        HStack(spacing: 12) {
                            Link(destination: tourURL) {
                                Label(String(localized: "View Virtual Tour"), systemImage: "house.fill")
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
                                    ? String(localized: "Tour photos: \(order.tourPhotoCount ?? 0) — add more")
                                    : String(localized: "Add tour photos"),
                                systemImage: "photo.on.rectangle.angled"
                            )
                            .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(.indigo)
                    }
                }

                // 🔴 KHỐI NÀY GÁC `status == "delivered"`, tức FILE THÀNH PHẨM — đúng, vì server
                // chỉ trả `deliveryFiles` khi `stage === "done"`. Nút "Yêu cầu sửa" thì TÁCH RA
                // khối riêng bên dưới: nó phải sống lâu hơn thế.
                if order.status == "delivered" {
                    if let url = httpsURL(order.deliveredUrl) {
                        Link(destination: url) {
                            Label(String(localized: "Download deliverables"), systemImage: "arrow.down.circle.fill")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    ForEach(order.files, id: \.self) { file in
                        if let url = httpsURL(file.url) {
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
                }
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
                        Label(String(localized: "Request a revision"), systemImage: "pencil.and.outline")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
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
                        Label(String(localized: "Add a scan"), systemImage: "plus.viewfinder")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)
            }
            }
        }
        // Ô tìm kiếm nằm ở NHÁNH CÓ ĐƠN (`ordersList`), không gắn cho màn trống/chưa đăng nhập:
        // chưa có đơn nào mà vẫn bày ô tìm kiếm là mời khách đi tìm thứ không tồn tại.
        //
        // ⚠ CỐ Ý KHÁC `HomeView` — đừng "sửa cho nhất quán". Ở `HomeView`, `.searchable` đã phải
        // chuyển RA KHỎI nhánh điều kiện vì tab đó có `navigationDestination` và PUSH màn mới:
        // search controller bị tháo/cắm lại đúng lúc `UINavigationController` đang push là cách
        // làm UIKit mất đồng bộ (xem chú thích 🔴 ở `HomeView.body`). Tab này KHÔNG push gì cả —
        // mọi thứ mở bằng `.sheet` — nên cơ chế đó không với tới được, và đổi lại thì màn "Đăng
        // nhập để xem đơn hàng" sẽ mọc một ô tìm kiếm vô nghĩa. Nếu pha sau THÊM
        // `navigationDestination` vào tab này thì phải chuyển `.searchable` lên ngang
        // `.navigationTitle` NGAY, giống HomeView.
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: String(localized: "Search order # or scan name")
        )
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
    /// File khách gửi kèm yêu cầu sửa (ảnh chụp chỗ sai, PDF đánh dấu…). Đã upload xong lên R2,
    /// chờ gửi metadata {name,url} kèm lời nhắn. Cùng endpoint `/order-files` với form đặt hàng.
    @State private var files: [OrderFileItem] = []
    @State private var showFileImporter = false
    @State private var uploadingFile = false
    @State private var fileUploadError: String?

    var body: some View {
        NavigationStack {
            Form {
                if sent {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.green)
                            Text(String(localized: "Revision requested!"))
                                .font(.headline)
                            Text(String(localized: "Our team will update your floor plan and deliver a revised version."))
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
                            String(localized: "What should we change? (e.g. missing door on Floor 2, wrong room label…)"),
                            text: $message,
                            axis: .vertical
                        )
                        .lineLimit(4...8)
                    } header: {
                        Text(order.orderNumber)
                    } footer: {
                        Text(String(localized: "Revisions for mistakes on our side are free."))
                    }
                    attachmentsSection
                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Request a revision"))
            .navigationBarTitleDisplayMode(.inline)
            // Vuốt xuống lúc ĐANG GỬI / ĐANG TẢI FILE thì sheet đóng mà request vẫn bay tiếp:
            // khách tin là đã hủy, thực tế đội vẽ vẫn nhận yêu cầu (và `onSent` không chạy nên
            // danh sách đơn không được làm tươi). Cùng bài học với [3] ở `OrderSheet`: cửa "đang
            // gửi" KHÔNG hủy an toàn được, nên khoá đường đóng thay vì giả vờ hủy.
            .interactiveDismissDisabled(isBusy || uploadingFile)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(sent ? String(localized: "Close") : String(localized: "Cancel")) { dismiss() }
                }
                if !sent {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            submit()
                        } label: {
                            if isBusy {
                                ProgressView()
                            } else {
                                Text(String(localized: "Send")).bold()
                            }
                        }
                        // Khoá luôn khi ĐANG TẢI FILE: gửi lúc đó là lời nhắn tới nơi mà file
                        // thì chưa, và sheet đóng mất — khách không còn đường gửi lại file đó
                        // vào đúng yêu cầu này.
                        .disabled(isBusy || uploadingFile || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    /// Mục đính kèm — cùng khuôn với mục "Đính kèm file" ở form đặt hàng (`OrderSheet`).
    private var attachmentsSection: some View {
        Section {
            ForEach(files) { file in
                HStack {
                    Image(systemName: "doc.fill").foregroundStyle(.secondary)
                    Text(file.name).lineLimit(1)
                    Spacer()
                    Button {
                        files.removeAll { $0.id == file.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                fileUploadError = nil
                showFileImporter = true
            } label: {
                if uploadingFile {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(String(localized: "Uploading…")).foregroundStyle(.secondary)
                    }
                } else {
                    Label(String(localized: "Add a file (photo, PDF…)"), systemImage: "paperclip")
                }
            }
            // Khoá cả khi ĐANG GỬI (`isBusy`): thêm file lúc đó là file lên R2 SAU khi POST đã
            // bay, không bao giờ vào đơn — mà `sent == true` thì cả mục này biến mất nên khách
            // không thấy gì bất thường. Và khoá theo TRẦN SERVER (10): server trả 400 nếu vượt,
            // chặn ở đây thì lỗi đó không bao giờ với tới khách.
            .disabled(uploadingFile || isBusy || files.count >= Self.maxFiles)
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.image, .pdf],
                allowsMultipleSelection: false
            ) { result in
                handleFilePick(result)
            }
            if let fileUploadError {
                Text(fileUploadError).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            // "(không bắt buộc)" bỏ theo mục cùng tên ở form đặt hàng (`ScanDetailView`, 13/08):
            // hai mục này cố ý CÙNG KHUÔN, để lệch chữ là hai màn nói hai kiểu về cùng một việc.
            // Ở đây cũng đúng nghĩa — nút Gửi chỉ đòi có LỜI NHẮN, file thì không.
            Text(String(localized: "Attachments"))
        } footer: {
            Text(files.count >= Self.maxFiles
                 ? String(localized: "Maximum \(Self.maxFiles) files per request.")
                 : String(localized: "A marked-up photo or PDF helps us find exactly what to fix."))
        }
    }

    /// Trần số file — PHẢI khớp `MAX_REVISION_FILES` ở server (`revision/route.ts`), nơi vượt trần
    /// là bị từ chối 400 chứ không cắt lặng lẽ.
    private static let maxFiles = 10

    private func handleFilePick(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        Task { await upload(url) }
    }

    /// Upload 1 file lên R2 qua presigned URL rồi thêm vào `files`. Cùng đường với `OrderSheet`.
    private func upload(_ url: URL) async {
        uploadingFile = true
        fileUploadError = nil
        // File từ .fileImporter nằm ngoài sandbox → phải xin quyền truy cập (và nhả sau).
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            uploadingFile = false
        }
        let name = url.lastPathComponent
        do {
            let slot = try await APIClient.shared.presignOrderFile(
                fileName: name,
                contentType: OrderFileItem.mimeType(for: url)
            )
            try await APIClient.shared.uploadFile(at: url, to: slot.putUrl, contentType: slot.contentType) { _ in }
            files.append(OrderFileItem(id: slot.fileId, name: slot.name, url: slot.publicUrl))
        } catch {
            fileUploadError = error.localizedDescription
        }
    }

    private func submit() {
        isBusy = true
        errorMessage = nil
        Task {
            do {
                _ = try await APIClient.shared.requestRevision(
                    orderId: order.orderId,
                    message: message,
                    files: files.map { ["name": $0.name, "url": $0.url] }
                )
                sent = true
                onSent()
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }
}

/// Bộ lọc trạng thái ở đầu tab Đơn hàng.
///
/// MỖI TRẠNG THÁI SERVER TRẢ VỀ ĐỀU CÓ ĐÚNG MỘT Ô (chủ app chốt 2026-07-23). Server có 5 trạng
/// thái (`customerOrderStatus` trong `app-api.ts`): received · in_production · on_hold · delivered
/// · refunded. Ở đây received+in_production gộp thành "Đang xử lý" — chủ app đã chốt bỏ nhãn "Đã
/// nhận" để khách bớt nôn nóng — còn ba cái kia mỗi cái một ô.
///
/// 🔴 Ô "Khác" tồn tại để TỔNG LUÔN KHỚP. Bản trước để `.processing` ôm "mọi thứ chưa giao chưa
/// hoàn" nên trạng thái mới của server tự rơi vào đó; nay `.processing` liệt kê tường minh (bắt
/// buộc, vì `.onHold` phải tách ra thì mới đếm riêng được), và nếu server thêm trạng thái thứ sáu
/// mà không có ô "Khác" thì đơn đó KHÔNG nằm trong ô nào — khách mở tab Đơn hàng thấy nó ở "Tất
/// cả" rồi bấm lọc là mất tích. Ô "Khác" chỉ hiện khi thật sự có đơn như vậy (xem `visibleFilters`).
enum OrderFilter: String, CaseIterable, Identifiable {
    case all, processing, onHold, ready, refunded, other
    var id: String { rawValue }

    /// Các trạng thái app BIẾT tên. Dùng cho ô "Khác" — đừng sửa một mình nó, phải sửa cùng `matches`.
    private static let known: Set<String> = [
        "received", "in_production", "on_hold", "delivered", "refunded",
    ]

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .processing: return String(localized: "Processing")
        case .onHold: return String(localized: "On hold")
        case .ready: return String(localized: "Ready")
        case .refunded: return String(localized: "Refunded")
        case .other: return String(localized: "Other")
        }
    }

    func matches(_ status: String) -> Bool {
        switch self {
        case .all: return true
        case .processing: return status == "received" || status == "in_production"
        case .onHold: return status == "on_hold"
        case .ready: return status == "delivered"
        case .refunded: return status == "refunded"
        case .other: return !Self.known.contains(status)
        }
    }
}

struct StatusBadge: View {
    let status: String

    private var info: (String, Color) {
        switch status {
        case "delivered":
            return (String(localized: "Delivered"), .green)
        case "on_hold":
            return (String(localized: "On hold"), .orange)
        case "refunded":
            return (String(localized: "Refunded"), .red)
        // "in_production" VÀ "received"/mặc định đều hiện "Đang xử lý" — chủ app chốt bỏ nhãn
        // "Đã nhận" (khiến khách nôn nóng), gộp vào "đang xử lý".
        //
        // Dùng MÀU NHẤN của app (cobalt) chứ không phải `.blue` hệ thống: nhãn này nằm cùng màn
        // với hàng chip lọc vốn đã tô `Color.accentColor`. Để `.blue` ở đây là hai sắc xanh khác
        // nhau cạnh nhau trên một màn hình — đọc thành lỗi render chứ không thành hai ý nghĩa.
        // Xanh lá/cam/đỏ ở trên thì GIỮ NGUYÊN: chúng là bộ màu ngữ nghĩa, đọc theo nhau.
        default:
            return (String(localized: "Processing"), .accentColor)
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
