import SwiftUI

@main
struct CedarScanApp: App {
    @StateObject private var store = ScanStore()
    @StateObject private var account = AccountStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(account)
        }
    }
}

enum RootTab: Hashable { case home, orders, scan, learn, account }

struct RootView: View {
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var account: AccountStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var tab: RootTab = .home
    /// Tab SCAN là NÚT HÀNH ĐỘNG, không phải trang: bấm nó bật về Home rồi yêu cầu HomeView mở màn
    /// quét mới. Tăng số này mỗi lần bấm = tín hiệu; `HomeView.onChange(of: scanRequest)` bắt được.
    @State private var scanRequest = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView(scanRequest: scanRequest)
                .tabItem {
                    Label(L.t("Home", "Home"), systemImage: "house")
                }
                .tag(RootTab.home)
                .toolbar(.hidden, for: .tabBar)
            OrdersView()
                .tabItem {
                    Label(L.t("Orders", "Đơn hàng"), systemImage: "shippingbox")
                }
                .tag(RootTab.orders)
                .toolbar(.hidden, for: .tabBar)
            // Placeholder: onChange bên dưới bật về Home NGAY khi chọn tab này nên nội dung gần như
            // không bao giờ hiện. Color.clear cho nhẹ.
            Color.clear
                .tabItem {
                    Label(L.t("Scan", "SCAN"), systemImage: "viewfinder")
                }
                .tag(RootTab.scan)
                .toolbar(.hidden, for: .tabBar)
            LearnView()
                .tabItem {
                    Label(L.t("Learn", "Learn"), systemImage: "graduationcap")
                }
                .tag(RootTab.learn)
                .toolbar(.hidden, for: .tabBar)
            AccountView()
                .tabItem {
                    Label(L.t("Account", "Tài khoản"), systemImage: "person.circle")
                }
                .tag(RootTab.account)
                .toolbar(.hidden, for: .tabBar)
        }
        // THANH TAB TỰ VẼ (2026-07-23). Thanh gốc của TabView không cho phóng to/làm nổi một nút,
        // nên nó bị ẩn (`.toolbar(.hidden, for: .tabBar)` ở TỪNG tab — modifier này đọc từ tab đang
        // hiện, đặt ở một chỗ không đủ) và thay bằng `CedarTabBar` gắn qua `safeAreaInset`.
        //
        // Vì sao safeAreaInset chứ không phải overlay: inset RÚT NGẮN vùng an toàn của nội dung
        // trong TabView, nên danh sách cuộn hết cỡ vẫn dừng NGAY TRÊN thanh. Overlay thì thanh đè
        // lên dòng cuối cùng và không ai chạm được nó.
        //
        // `.tabItem` vẫn khai đủ nhãn/icon: nếu một bản iOS nào đó không ẩn được thanh gốc thì app
        // vẫn dùng được (hai thanh, xấu nhưng không kẹt), thay vì còn một dải nút trắng trơn.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CedarTabBar(selection: $tab)
                // Bàn phím KHÔNG được đẩy thanh tab lên. Nội dung safeAreaInset mặc định né bàn
                // phím, nên ô tìm kiếm ở Home/Đơn hàng sẽ làm thanh tab trôi lên nằm đè kết quả.
                // Thanh gốc của iOS nằm im dưới bàn phím — giữ đúng hành vi đó.
                .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        // Tab SCAN không "ở lại": bật về Home (để màn quét mở TRÊN HomeView — đằng sau sheet là danh
        // sách bản quét, không phải nền trống), rồi báo HomeView mở màn quét mới. Cùng cơ chế "center
        // action tab" phổ biến; toàn bộ máy quét (bẫy đã ghi ở handoff) vẫn nằm nguyên trong HomeView.
        .onChange(of: tab) { _, newTab in
            guard newTab == .scan else { return }
            tab = .home
            scanRequest += 1
        }
        .task(id: account.isSignedIn) {
            await purgeDeliveredScans()
        }
        // `.task(id:)` KHÔNG đủ: TabView gốc không bao giờ disappear/reappear trong vòng đời
        // tiến trình, và `AccountStore` đọc Keychain ĐỒNG BỘ lúc init nên `isSignedIn` không
        // đổi giá trị sau đó → task chỉ chạy ĐÚNG MỘT LẦN mỗi lần khởi động app. Khách để app
        // trong nền cả tuần thì không bao giờ được dọn. Thêm mốc quay lại foreground.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await purgeDeliveredScans() }
        }
    }

    /// Dọn IM LẶNG bản quét thuộc đơn đã giao (chủ app chốt: làm như CubiCasa, không hỏi khách).
    ///
    /// Mọi đường lỗi đều dẫn tới KHÔNG XOÁ GÌ — chưa đăng nhập, mất mạng, server trả rác, decode
    /// hỏng, `deliveredAt` parse không ra: tất cả `return`/lọc bỏ. Nguyên tắc: không chắc chắn
    /// thì đừng đụng vào dữ liệu của khách. Bỏ sót một lần dọn chỉ tốn dung lượng; xoá nhầm một
    /// lần là mất buổi quét 10–30 phút không lấy lại được.
    private func purgeDeliveredScans() async {
        guard account.isSignedIn else { return }
        guard let response = try? await APIClient.shared.listOrders() else { return }

        // Dữ liệu đơn KHÔNG ĐẦY ĐỦ → không xoá gì cả. `allScanIds` có phao về `[scanId]` (chỉ
        // TẦNG ĐẦU TIÊN) khi server cũ không trả `scanIds`. Phao đó an toàn ở vế "xoá" (xoá ít
        // hơn) nhưng NGUY HIỂM ở vế "giữ": tầng 2,3… của đơn chưa xong sẽ rơi khỏi tập bảo vệ
        // và bị xoá mất. Hai vế đòi hỏi ngược nhau nên không được dùng chung một phao.
        guard response.orders.allSatisfy({ $0.scanIds != nil }) else { return }

        let ripe = { (o: OrderDTO) in
            o.isDeliveredToCustomer && o.wasDeliveredAtLeast(daysAgo: Self.keepAfterDeliveryDays)
        }
        // TRỪ ĐI bản quét còn dính đơn CHƯA xong. MỘT bản quét có thể nằm trong NHIỀU đơn:
        // `OrderSheet.ensureUploaded` tái dùng `cloudScanId` nếu đã có, nên khách đặt thêm gói
        // khác từ chính bản quét cũ là cùng scanId xuất hiện ở cả đơn đã giao lẫn đơn đang vẽ.
        // Chỉ hợp các đơn đã giao mà không trừ, là xoá mất dữ liệu đơn đang chạy.
        let stillNeeded = Set(response.orders.filter { !ripe($0) }.flatMap(\.allScanIds))
        let deliveredIds = Set(response.orders.filter(ripe).flatMap(\.allScanIds))
            .subtracting(stillNeeded)

        store.purgeDelivered(scanIds: deliveredIds)
    }

    /// Giữ bản quét thêm bấy nhiêu ngày SAU khi giao rồi mới dọn — cửa sổ để vòng "Yêu cầu sửa"
    /// kịp xảy ra (xem `OrderDTO.wasDeliveredAtLeast`). Hạ số này xuống 0 là khách có thể trắng
    /// tay giữa vòng sửa: server đã thu lại file thành phẩm mà máy thì đã xoá bản gốc.
    private static let keepAfterDeliveryDays = 14
}
