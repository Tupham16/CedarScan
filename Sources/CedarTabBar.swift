import SwiftUI
import UIKit // UIColor.systemBackground cho vòng "khoét lỗ" quanh nút SCAN

/// Thanh tab TỰ VẼ (thay thanh gốc của TabView, đã bị ẩn ở `RootView`).
///
/// Lý do phải tự vẽ: thanh gốc của SwiftUI/UIKit không cho phóng to riêng một nút, không cho nó
/// nhô lên khỏi thanh, cũng không cho đổ bóng màu. Chủ app muốn nút SCAN nằm GIỮA, to hơn và nổi
/// bật — đó là khuôn "center action button" quen thuộc (Instagram/TikTok), bắt buộc phải tự vẽ.
///
/// 🔴🔴 **NÚT SCAN GỌI `onScan()`, TUYỆT ĐỐI ✗ ĐẶT `selection = .scan`. ĐÂY LÀ BẢN VÁ CỦA LỖI
/// "LỀ SwiftUI ĐÔNG CỨNG" — 9 BẢN IPA MỚI TÌM RA. ✗ ĐỔI NGƯỢC LẠI DÙ VÌ LÝ DO GÌ.**
///
/// Chú thích cũ ở đúng chỗ này dặn ngược lại — nguyên văn: *"Thanh này CHỈ đổi `selection`… Đừng
/// rút gọn thành gọi thẳng hàm quét ở đây"*. **Chính lời dặn đó là con bug.** Giữ lại đoạn này để
/// ai định "khôi phục cho đúng khuôn cũ" thì đọc được vì sao không được.
///
/// **Cơ chế cũ (SAI):** bấm SCAN → `selection = .scan` → `RootView.onChange(of: tab)` bật NGƯỢC
/// về `.home` + tăng `scanRequest`, tất cả trong CÙNG một nhịp; `.scan` chỉ là một tab
/// `Color.clear` giả. Cú **nhảy-vào-rồi-ra** đó, trên một `TabView` bị ẩn thanh gốc và gắn thanh
/// tự vẽ bằng `.safeAreaInset`, làm SwiftUI **bỏ hẳn vùng an toàn của cả cây** — vĩnh viễn, tới
/// khi tắt app. Triệu chứng: header đè danh sách, nút đáy bị đĩa Scan đè, ở MỌI màn sau đó.
///
/// **Đo được, ✗ suy luận** (harness CI `31559667222`, iPhone 17 Pro / iOS 26.5 — cùng một cái
/// sheet, chỉ khác đường mở):
///  · mở màn địa chỉ bằng NÚT THƯỜNG → `geo t116 b34` (lành);
///  · đổi tab THƯỜNG (Home→Đơn hàng→Home) → lành;
///  · sheet rỗng / sheet có `NavigationStack`+`.toolbar` → lành;
///  · **mở CHÍNH màn đó qua ĐĨA SCAN → `geo t0 b0`.**
/// ⇒ Thủ phạm là cú nảy tab, ✗ phải sheet, ✗ phải màn quét, ✗ phải `.safeAreaInset` trong sheet.
/// 8 bản trước (2.6→2.14) vá ở phía SAU thủ phạm nên bản nào cũng trượt.
///
/// 🔴 `onScan` KHÔNG có giá trị mặc định — quên truyền là lỗi biên dịch, ✗ phải một cái nút chết
/// im lặng (bẫy #13).
struct CedarTabBar: View {
    @Binding var selection: RootTab
    /// Bấm đĩa SCAN. `RootView` nối vào `requestScan()` — đọc khối 🔴🔴 ở trên trước khi đụng.
    let onScan: () -> Void

    /// Phần THANH nhìn thấy (nền mờ + divider), đo từ mép trên vùng an toàn dưới:
    /// hàng nút 58 + 8pt thở phía trên icon (cao hơn đời trước 4pt để dải trong suốt bên
    /// trên — xem `totalHeight` — mỏng lại tương ứng).
    private static let barHeight: CGFloat = 66
    /// Chiều cao Ô CHẠM của 4 nút thường. Chúng ghim ĐÁY khung tổng (HStack alignment .bottom),
    /// KHÔNG cao hết khung: dải trong suốt phía trên thanh phải để chạm RƠI XUYÊN xuống nội dung
    /// đang cuộn phía sau (dòng nào thấy được thì chạm được — đúng trực giác), chứ không bị một
    /// nút tab vô hình nuốt mất.
    private static let itemRowHeight: CGFloat = 58
    private static let scanDiameter: CGFloat = 66

    /// Tổng khung LAYOUT của view này = thanh 66 + dải TRONG SUỐT 28pt phía trên chứa phần nút
    /// SCAN nhô lên. Nút "tràn viền" là tràn qua ĐƯỜNG KẺ (divider vẽ ở mép trên phần thanh),
    /// chứ KHÔNG tràn ra ngoài khung layout — toàn bộ vòng tròn + nhãn vẫn nằm trong khung này
    /// nên vùng chạm luôn phủ kín nút. Xem `scanItem` vì sao đây là điều bắt buộc.
    ///
    /// ⚠ GIÁ CỦA DẢI TRONG SUỐT (review 2026-07-29, chấp nhận có chủ đích — chủ app nghiệm
    /// trên máy thật): nội dung cuộn hiện RÕ trong dải 28pt rồi mới mờ sau divider (kiểu
    /// "nút nổi trên nội dung"); danh sách cuộn hết cỡ dừng ở mép TRÊN của khung (28pt trên
    /// divider); màn push chừa `reservedHeight` nên thẻ nút của chúng cũng cách divider 28pt.
    /// Muốn dải mỏng hơn nữa thì phải thu chồng đĩa-nhãn ở `scanItem` trước.
    ///
    /// 🔴 BẤT BIẾN KÍCH THƯỚC: chồng cao nhất trong `scanItem` là
    /// vòng khoét lỗ (66+6=72) + spacing 2 + nhãn ~12 + đệm đáy 6 = 92 ≤ 94 (2pt dư để quầng
    /// sáng không dí sát nội dung phía trên).
    /// Phóng nút/nhãn to hơn thì PHẢI nới `totalHeight` trước, không thì vòng tròn bị cắt cụt.
    private static let totalHeight: CGFloat = 94

    /// Chỗ mà thanh này CHIẾM trên màn hình, tính từ mép trên vùng an toàn dưới.
    ///
    /// 🔴 CÁC MÀN ĐƯỢC **PUSH** PHẢI TỰ CHỪA CHỖ NÀY. Chủ app báo (2026-07-23, bản `85bab71`):
    /// vào một dự án thì nút "Quét bổ sung" **bị thanh tab che**, mà chỉ ở MỘT SỐ dự án. Giải
    /// thích khớp hoàn toàn: `ProjectView.bottomButtons` chứa 1 hay 2 nút tuỳ dự án còn bản quét
    /// chưa đặt hay không — dự án 2 nút thì nút dưới (Đặt hàng) hứng phần bị che nên nút "Quét bổ
    /// sung" ở trên vẫn thấy, dự án 1 nút thì chính nó bị che.
    ///
    /// Nguyên nhân: thanh này gắn bằng `.safeAreaInset` trên **TabView**, nhưng vùng an toàn đó
    /// KHÔNG chảy tới các màn được push bên trong `NavigationStack` của tab. `ProjectView` và
    /// `ScanDetailView` cũng ghim nút bằng `.safeAreaInset(edge:.bottom)` của riêng chúng, và
    /// chúng ghim vào một đáy mà chúng tưởng còn trống.
    ///
    /// Giá trị này = `totalHeight` (GỒM cả vùng trong suốt phía trên thanh): nút SCAN nhô vào
    /// vùng đó, nên màn push nào chỉ chừa 62pt là nút "Đặt hàng" của nó chui xuống DƯỚI vòng
    /// tròn SCAN — nửa nút bị đĩa tròn đè, chạm vào đĩa lại mở màn quét.
    ///
    /// ⚠ ĐỪNG bọc TabView trong `VStack { TabView; CedarTabBar }` để "cho chắc về hình học".
    /// Đã cân nhắc và loại: VStack làm bàn phím đẩy CẢ thanh tab lên, mà chữa bằng
    /// `.ignoresSafeArea(.keyboard)` ở VStack thì tắt luôn việc né bàn phím của NỘI DUNG — ô địa
    /// chỉ/ô tìm kiếm chui xuống dưới bàn phím. `.safeAreaInset` là công cụ đúng cho việc này.
    static let reservedHeight: CGFloat = totalHeight

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            tabItem(.home, icon: "house", filled: "house.fill", title: L.t("Home", "Home"))
            tabItem(.orders, icon: "shippingbox", filled: "shippingbox.fill", title: L.t("Orders", "Đơn hàng"))
            scanItem
            tabItem(.learn, icon: "graduationcap", filled: "graduationcap.fill", title: L.t("Learn", "Learn"))
            tabItem(.account, icon: "person.circle", filled: "person.circle.fill", title: L.t("Account", "Tài khoản"))
        }
        .frame(height: Self.totalHeight)
        // Nền mờ + đường kẻ chỉ phủ phần thanh `barHeight` DƯỚI CÙNG (ghim đáy). Vùng phía trên
        // trong suốt — đó chính là "tràn viền": phần vòng tròn nhô lên đứng trên nội dung cuộn.
        .background(alignment: .bottom) { barBackground }
    }

    /// `.bar` là vật liệu mờ đúng chuẩn thanh hệ thống — nội dung cuộn phía sau vẫn thấy mờ mờ.
    ///
    /// `.ignoresSafeArea(edges: .bottom)` gắn cho RIÊNG phần nền: trên máy có Face ID, dải
    /// home-indicator nằm NGOÀI vùng an toàn, nên nếu nền dừng đúng mép vùng an toàn thì bên
    /// dưới thanh sẽ lộ ra một vệt nội dung đang cuộn. Đặt ở background chứ không đặt cho cả
    /// thanh: các nút phải nằm nguyên trong vùng an toàn, không ai bấm trúng thanh home.
    ///
    /// Đường kẻ nằm CÙNG trong background chứ không phải `.overlay`: overlay vẽ ĐÈ lên nội
    /// dung, tức một vạch xám cắt ngang thân nút SCAN. Trong ZStack này nó nằm trên vật liệu
    /// nhưng vẫn dưới mọi nút — nút SCAN nhô QUA đường kẻ là nhờ nó thuộc lớp nút phía trên.
    private var barBackground: some View {
        ZStack(alignment: .top) {
            // `Material.bar` viết TƯỜNG MINH, không dùng `.bar` rút gọn: `fill(_:)` nhận
            // `some ShapeStyle`, và implicit-member trên tham số generic là chỗ trình biên
            // dịch hay chịu thua — mà máy này không compile được để biết.
            Rectangle()
                .fill(Material.bar)
                .ignoresSafeArea(edges: .bottom)
            Divider()
        }
        .frame(height: Self.barHeight)
    }

    /// Một nút thường. Tách thành HÀM (không phải biểu thức lặp trong body) vì CI của repo này
    /// từng chết vì "Swift type-check timeout" với biểu thức SwiftUI lớn.
    private func tabItem(_ tab: RootTab, icon: String, filled: String, title: String) -> some View {
        let isOn = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: isOn ? filled : icon)
                    .font(.system(size: 19, weight: .regular))
                Text(title)
                    .font(.system(size: 10, weight: isOn ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            // Cả ô đều bấm được, không chỉ đúng chữ/icon — ngón tay không bao giờ rơi đúng 19pt.
            // Nhưng ô chỉ cao `itemRowHeight` và ghim ĐÁY khung tổng: vùng chạm phải dừng ở mép
            // thanh nhìn thấy, không được leo lên dải trong suốt (xem chú ở `itemRowHeight`).
            .frame(maxWidth: .infinity)
            .frame(height: Self.itemRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        // Kiểu ghi rõ ở CẢ HAI nhánh (`AccessibilityTraits()` = rỗng): ternary với hai
        // implicit-member của một OptionSet là chỗ trình biên dịch hay chịu thua.
        .accessibilityAddTraits(isOn ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }

    /// Nút SCAN: vòng tròn to nhô qua đường viền + nhãn "Scan" (chủ app yêu cầu 2026-07-28:
    /// nút to 1.5× và trả lại chữ; `HomeView.emptyState` đã tả nút theo nhãn này — đổi nhãn
    /// thì sửa cả câu đó).
    ///
    /// 🔴 KHÔNG `offset` cho nút nhô lên khỏi thanh. Đời đầu của thanh này có `offset(y: -20)`
    /// và nó hỏng hai đường cùng lúc (review đối kháng bắt được, 5 lens độc lập cùng chỉ vào):
    ///  1. `offset` KHÔNG mở rộng vùng chạm. Phần nhô lên nằm ngoài `contentShape` nên chạm vào
    ///     đó không mở màn quét, mà RƠI XUỐNG lớp phía sau — ở Home là hàng bản quét cuối danh
    ///     sách, ở tab Đơn hàng có thể là link "Thanh toán ngay". Nút chính của app "lúc được lúc
    ///     không", và bấm hụt còn mở nhầm màn khác.
    ///  2. Đĩa nền đục của nút đè lên chính chữ "SCAN" ở đáy ô.
    /// Cách nhô ĐÚNG (bản này): khung layout của cả thanh cao `totalHeight`, phần nền/viền chỉ vẽ
    /// 62pt dưới cùng — vòng tròn vượt qua ĐƯỜNG KẺ nhưng vẫn nằm trọn trong khung, nên
    /// `contentShape` phủ kín cả phần nhô (cột này cao HẾT khung, khác 4 nút thường). Nhãn nằm
    /// trong phần thanh nên không bị đĩa đè (nguyên nhân #2 cũng không quay lại).
    private var scanItem: some View {
        Button {
            // 🔴 ✗ ĐỔI THÀNH `selection = .scan`. Đó là con bug — đọc khối 🔴🔴 đầu file.
            onScan()
        } label: {
            VStack(spacing: 2) {
                scanCircle
                Text("Scan")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L.t("Scan a new space", "Quét không gian mới"))
    }

    /// Chồng cao nhất ở đây là vòng "khoét lỗ" (`scanDiameter + 6` = 72) — nó quyết định bất
    /// biến kích thước ghi ở `totalHeight`. Quầng sáng to hơn (76) nhưng nằm trong `.background`
    /// nên KHÔNG ăn layout (blur mềm, tràn ra ngoài khung một chút là chấp nhận được).
    private var scanCircle: some View {
        ZStack {
            // Vòng nền: tách nút khỏi vật liệu của thanh, cho ra khuôn "nút khoét lỗ".
            // `systemGroupedBackground` chứ KHÔNG phải `systemBackground` (review 2026-07-29):
            // phần vòng nhô lên nay đứng trên NỀN LIST của các tab — List mặc định của app
            // (Home/Orders/màn push) đều là insetGrouped nền #F2F2F7 ở light mode, vòng trắng
            // tinh trên đó thành một vành trăng lệch màu ngay giữa thanh. Dark mode hai màu
            // này trùng nhau nên không đổi gì.
            //
            // Quầng sáng đặt làm `.background` của vòng nền: CỐ Ý KHÔNG animation nhấp nháy —
            // thanh tab sống suốt vòng đời app, một animation lặp vô hạn ở đây là thứ chạy cả lúc
            // máy đang quét LiDAR (nóng + tốn pin), đổi lại chỉ được một hiệu ứng loè.
            Circle()
                .fill(Color(uiColor: .systemGroupedBackground))
                .frame(width: Self.scanDiameter + 6, height: Self.scanDiameter + 6)
                .background(
                    Circle()
                        .fill(Color.accentColor.opacity(0.35))
                        .frame(width: Self.scanDiameter + 10, height: Self.scanDiameter + 10)
                        .blur(radius: 7)
                )
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.72)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: Self.scanDiameter, height: Self.scanDiameter)
                .overlay(
                    Circle().stroke(Color.white.opacity(0.28), lineWidth: 1)
                )
                .shadow(color: Color.accentColor.opacity(0.45), radius: 7, y: 2)
            Image(systemName: "viewfinder")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
