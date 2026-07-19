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

struct RootView: View {
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var account: AccountStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label(L.t("Scans", "Bản quét"), systemImage: "viewfinder")
                }
            OrdersView()
                .tabItem {
                    Label(L.t("Orders", "Đơn hàng"), systemImage: "shippingbox")
                }
            AccountView()
                .tabItem {
                    Label(L.t("Account", "Tài khoản"), systemImage: "person.circle")
                }
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
