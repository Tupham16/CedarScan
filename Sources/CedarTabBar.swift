import SwiftUI
import UIKit // UIColor.systemBackground cho vòng "khoét lỗ" quanh nút SCAN

/// Thanh tab TỰ VẼ (thay thanh gốc của TabView, đã bị ẩn ở `RootView`).
///
/// Lý do phải tự vẽ: thanh gốc của SwiftUI/UIKit không cho phóng to riêng một nút, không cho nó
/// nhô lên khỏi thanh, cũng không cho đổ bóng màu. Chủ app muốn nút SCAN nằm GIỮA, to hơn và nổi
/// bật — đó là khuôn "center action button" quen thuộc (Instagram/TikTok), bắt buộc phải tự vẽ.
///
/// 🔴 Thanh này CHỈ đổi `selection`. Mọi cơ chế cũ giữ NGUYÊN: bấm SCAN vẫn chỉ là chọn
/// `RootTab.scan`, rồi `RootView.onChange(of: tab)` bật về Home và tăng `scanRequest`. Đừng
/// "rút gọn" thành gọi thẳng hàm quét ở đây — máy quét nằm trong `HomeView` và đường đi hiện tại
/// là đường đã được ghi trong handoff.
struct CedarTabBar: View {
    @Binding var selection: RootTab

    /// Chiều cao phần LAYOUT của thanh (chưa tính safe area dưới). Cao hơn thanh gốc của iOS
    /// (49pt) vì phải chứa TRỌN vòng tròn SCAN — xem `scanItem`.
    private static let rowHeight: CGFloat = 58
    private static let scanDiameter: CGFloat = 44

    var body: some View {
        HStack(spacing: 0) {
            tabItem(.home, icon: "house", filled: "house.fill", title: L.t("Home", "Home"))
            tabItem(.orders, icon: "shippingbox", filled: "shippingbox.fill", title: L.t("Orders", "Đơn hàng"))
            scanItem
            tabItem(.learn, icon: "graduationcap", filled: "graduationcap.fill", title: L.t("Learn", "Learn"))
            tabItem(.account, icon: "person.circle", filled: "person.circle.fill", title: L.t("Account", "Tài khoản"))
        }
        .frame(height: Self.rowHeight)
        .padding(.top, 4)
        // `.bar` là vật liệu mờ đúng chuẩn thanh hệ thống — nội dung cuộn phía sau vẫn thấy mờ mờ.
        //
        // `.ignoresSafeArea(edges: .bottom)` gắn cho RIÊNG phần nền: trên máy có Face ID, dải
        // home-indicator nằm NGOÀI vùng an toàn, nên nếu nền dừng đúng mép vùng an toàn thì bên
        // dưới thanh sẽ lộ ra một vệt nội dung đang cuộn. Đặt ở background chứ không đặt cho cả
        // thanh: các nút phải nằm nguyên trong vùng an toàn, không ai bấm trúng thanh home.
        //
        // Đường kẻ nằm CÙNG trong background chứ không phải `.overlay`: overlay vẽ ĐÈ lên nội
        // dung, tức một vạch xám cắt ngang thân nút SCAN. Trong ZStack này nó nằm trên vật liệu
        // nhưng vẫn dưới mọi nút.
        .background {
            ZStack(alignment: .top) {
                // `Material.bar` viết TƯỜNG MINH, không dùng `.bar` rút gọn: `fill(_:)` nhận
                // `some ShapeStyle`, và implicit-member trên tham số generic là chỗ trình biên
                // dịch hay chịu thua — mà máy này không compile được để biết.
                Rectangle()
                    .fill(Material.bar)
                    .ignoresSafeArea(edges: .bottom)
                Divider()
            }
        }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Cả ô đều bấm được, không chỉ đúng chữ/icon — ngón tay không bao giờ rơi đúng 19pt.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        // Kiểu ghi rõ ở CẢ HAI nhánh (`AccessibilityTraits()` = rỗng): ternary với hai
        // implicit-member của một OptionSet là chỗ trình biên dịch hay chịu thua.
        .accessibilityAddTraits(isOn ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }

    /// Nút SCAN: vòng tròn to, gradient, có quầng sáng.
    ///
    /// 🔴 VÒNG TRÒN NẰM TRỌN TRONG Ô — KHÔNG `offset` cho nó nhô lên khỏi thanh. Đời đầu của
    /// thanh này có `offset(y: -20)` và nó hỏng hai đường cùng lúc (review đối kháng bắt được,
    /// 5 lens độc lập cùng chỉ vào đây):
    ///  1. `offset` KHÔNG mở rộng vùng chạm. Phần nhô lên nằm ngoài `contentShape` nên chạm vào
    ///     đó không mở màn quét, mà RƠI XUỐNG lớp phía sau — ở Home là hàng bản quét cuối danh
    ///     sách, ở tab Đơn hàng có thể là link "Thanh toán ngay". Nút chính của app "lúc được lúc
    ///     không", và bấm hụt còn mở nhầm màn khác.
    ///  2. Đĩa nền đục của nút đè lên chính chữ "SCAN" ở đáy ô.
    /// Cách chữa gọn nhất là bỏ luôn cả hai nguyên nhân: thanh cao thêm vài pt để chứa trọn vòng
    /// tròn, và bỏ nhãn chữ dưới nút (icon viewfinder to + màu nhấn đã là tín hiệu rõ hơn mọi
    /// nhãn 10pt; VoiceOver vẫn đọc được nhờ `accessibilityLabel`).
    private var scanItem: some View {
        Button {
            selection = .scan
        } label: {
            scanCircle
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L.t("Scan a new space", "Quét không gian mới"))
    }

    /// Kích thước lớn nhất trong `scanCircle` là vòng "khoét lỗ" (`scanDiameter + 6`). Nó PHẢI nhỏ
    /// hơn `rowHeight` — nếu không, nút lại tràn ra ngoài ô và quay về đúng hai lỗi đã tả ở
    /// `scanItem`. Hiện: 44 + 6 = 50 < 58. Quầng sáng có tràn ra là được (blur mềm, không ăn layout).
    private var scanCircle: some View {
        ZStack {
            // Quầng sáng: một vòng tròn mờ nằm dưới cùng. CỐ Ý KHÔNG animation nhấp nháy — thanh
            // tab sống suốt vòng đời app, một animation lặp vô hạn ở đây là thứ chạy cả lúc máy
            // đang quét LiDAR (nóng + tốn pin), đổi lại chỉ được một hiệu ứng loè.
            Circle()
                .fill(Color.accentColor.opacity(0.35))
                .frame(width: Self.scanDiameter + 10, height: Self.scanDiameter + 10)
                .blur(radius: 7)
            // Vòng nền: tách nút khỏi vật liệu của thanh, cho ra khuôn "nút khoét lỗ".
            Circle()
                .fill(Color(uiColor: .systemBackground))
                .frame(width: Self.scanDiameter + 6, height: Self.scanDiameter + 6)
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
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
