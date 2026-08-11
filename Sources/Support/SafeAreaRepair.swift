import UIKit
// Combine cho `ObservableObject`/`@Published` của `SafeAreaRepairStats` (bản đo 2.10) — UIKit
// KHÔNG re-export Combine, thiếu dòng này là CI chết "cannot find type 'ObservableObject'".
import Combine

/// 🔴 VÁ LỖI "LỀ VỀ 0 SAU KHI ĐÓNG COVER QUÉT" — ép UIKit + SwiftUI đọc lại vùng an toàn.
///
/// **Lỗi (chủ app, 2.4→2.8 đều bị):** quét xong → mọi màn mất lề (header đè danh sách, nút đáy bị
/// đĩa Scan đè). Thoát app vào lại là hết.
///
/// **Số đo (nhãn vàng `safeAreaProbe`, iPhone 12 Pro):**
///  · đang lỗi (2.7): `win t47 b34 · geo t0 b0` — cửa sổ UIKit ĐÚNG, cây SwiftUI nhận 0;
///  · lành (2.8 sau khi thoát app): `win t47 b34 · geo t91 b34` (91 = 47 tai thỏ + 44 thanh
///    điều hướng) — mốc chuẩn để đối chiếu.
///
/// **Lịch sử các phát đã bắn — ✗ bắn lại phát cũ:**
///  · 2.7: gỡ `.toolbar(.hidden, for:.tabBar)` → vẫn lỗi → minh oan, đã khai lại.
///  · 2.8 (v1): toggle `additionalSafeAreaInsets` root VC, ĐỒNG BỘ ngay trong onDismiss → **vẫn
///    lỗi.** Kết luận: tín hiệu đổi-lề phát từ root nhưng cây dưới không nhận — chỗ đông cứng
///    SÂU HƠN root / phía SwiftUI / hoặc tái nhiễm SAU onDismiss (crash 11/08 nổ trong bộ máy
///    bar item GIỮA cú push — tái nhiễm lúc push là giả thuyết sống).
///
/// **v2 (bản 2.9): một lượt sửa = BA phát, mỗi phát nhắm một giả thuyết còn sống:**
///  1. co CỬA SỔ 0,5pt rồi trả lại trong CÙNG nhịp (đổi hình học gốc → UIKit tính lại lề từ cửa
///     sổ xuống, phá cache MỌI tầng; không render giữa chừng nên mắt không thấy);
///  2. toggle `additionalSafeAreaInsets` (giữ từ v1, rẻ);
///  3. `poke` — gọi `safeAreaInsetsDidChange()` (method công khai của UIView, mặc định no-op)
///     đệ quy TOÀN cây: điểm móc để hosting view của SwiftUI đọc lại lề — nhắm ca "UIKit đúng,
///     SwiftUI ôm giá trị cũ". ⚠ Tiền đề "_UIHostingView nghe callback này" là giả thuyết chưa
///     kiểm chứng — nếu sau này có crash log dừng ở khung `safeAreaInsetsDidChange` thì gỡ phát
///     này TRƯỚC TIÊN.
///
/// **🔴 LỊCH BẮN — ✗ BAO GIỜ chạy đồng bộ tại chỗ gọi. Review đối kháng 11/08 (vòng 2) bắt được
/// bản nháp bắn thẳng trong `onAppear`, tức co cửa sổ + ép layout GIỮA hoạt ảnh push — đúng cửa
/// sổ thời gian đã văng app hai lần (06/08, 11/08), lặp mỗi cú push. Thiết kế chốt:**
///  · `nudge()` chỉ ĐẶT LỊCH: chạy sau **0,6s**; các cú dồn dập (onDismiss + onAppear + pop-back)
///    được GỘP — một lịch chờ là đủ;
///  · tới giờ, TỪNG scene phải qua HAI cổng, trượt cổng nào cũng **hẹn lại (≤5 lần × 0,6s)**:
///    (a) **không transition nào đang chạy** — kiểm `transitionCoordinator` đệ quy toàn cây VC.
///        ✗ bỏ cổng này với lý lẽ "0,6s là hoạt ảnh xong rồi": vuốt-back tương tác kéo dài theo
///        NGÓN TAY, không theo đồng hồ — mà onAppear của màn được lộ ra bắn NGAY LÚC BẮT ĐẦU
///        vuốt, nên "vuốt chậm >0,6s" là phát sửa rơi đúng giữa transition, có hệ thống chứ
///        không phải trùng hợp (review vòng 3 bắt);
///    (b) **không có presentation kiểu FULL-SCREEN** — cover đang mở nghĩa là cây cần sửa BỊ
///        THÁO khỏi window: sửa vừa vô ích vừa chèn layout toàn cửa sổ vào giữa vòng render AR
///        của một buổi quét thật. Cover đóng thì `onDismiss` của chính nó re-arm, nên chuỗi chết
///        ở đây không sao.
///        🔴 CHỈ chặn fullScreen/overFullScreen, ✗ chặn mọi `presentedViewController`: sheet đặt
///        hàng và alert KHÔNG tháo cây bên dưới — sửa dưới chân chúng an toàn và BẮT BUỘC, vì
///        đường "Đặt hàng ngay" tự mở form trước cả mốc 0,6s; chặn cả sheet là chuỗi hẹn chết
///        đói và màn mục-3a không bao giờ được sửa (review vòng 3, cả hai reviewer cùng bắt).
///  Giá chấp nhận: sau khi cover đóng, màn có thể lệch ~0,6s rồi mới được sửa — đổi lấy việc
///  không bao giờ ép layout giữa transition.
///
/// 💀 **KẾT CỤC (2.10): SỬA-TỪ-NGOÀI THẤT BẠI TOÀN TẬP — đo được, ✗ thử thêm biến thể nào nữa.**
/// Lúc đang lỗi: `fix 9` (repair đã chạy 9 lần, cổng không kẹt) · `root t47 b34` (UIKit lành tới
/// view gốc) · `geo t0 b0` · chạm nút bắn tay (`forceRepairNow`, bỏ mọi cổng) cũng TRƠ. Chỗ đông
/// cứng nằm BÊN TRONG SwiftUI. **Vá gốc là `ScanCoverPresenter` (2.11)**: cover quét bỏ
/// `.fullScreenCover`, present `.overFullScreen` để cây bên dưới không bao giờ bị tháo.
/// File này GIỮ LẠI làm lưới cho `.fullScreenCover` CÒN SÓT: trình xem 3D ở `ScanDetailView`
/// (chưa đổi khuôn — đổi xong thì cân nhắc gỡ cả file). Biết trước: với chỗ đã đông cứng thì nó
/// KHÔNG cứu được (bằng chứng trên) — nó chỉ còn giá trị "nếu may thì đỡ", không phải thuốc.
/// Chỗ gọi hiện tại: `afterScanCoverClosed()` của HomeView + ProjectView (completion đóng cover
/// quét), `onDismiss` của viewer 3D, `onAppear` của Home và hai màn PUSH.
/// 🔴 BẢN ĐO TẠM (2.10) — đếm số lượt `repair()` ĐÃ THẬT SỰ chạy, cho nhãn vàng hiện.
/// Sinh ra vì một lỗ trong phép thử 2.9: không có bằng chứng nào cho thấy repair CÓ chạy trong ca
/// lỗi — nếu cổng `inTransition` kẹt luôn-true thì cả 3 phát chưa từng nổ, và "v2 thất bại" là
/// kết luận rút từ thí nghiệm chưa chạy. GỠ CÙNG nhãn vàng khi đóng vụ.
final class SafeAreaRepairStats: ObservableObject {
    static let shared = SafeAreaRepairStats()
    /// Tăng ở cuối mỗi `repair()` (luôn trên main). Nhãn vàng quan sát để tự vẽ lại.
    @Published var repairCount = 0
}

enum SafeAreaRepair {
    /// Đang có một lịch sửa chờ chạy — cờ GỘP các cú nudge dồn dập. Chỉ đọc/ghi trên main queue
    /// (nudge là @MainActor, mọi closure đều asyncAfter lên main) nên không cần khoá.
    private static var pending = false

    /// 🔴 BẢN ĐO TẠM (2.10): chạy repair NGAY LẬP TỨC, BỎ QUA lịch 0,6s + CẢ HAI cổng. CHỈ được
    /// gọi từ cú CHẠM của chủ app lên nhãn vàng — lúc đó chắc chắn không có transition nào đang
    /// bay (ngón tay đang bận chạm nhãn) nên bỏ cổng là an toàn. Đây là thí nghiệm quyết định:
    /// đang lỗi mà chạm nhãn → màn tự sửa = sửa-từ-ngoài SỐNG (lỗi nằm ở lịch/cổng, vá rẻ);
    /// chạm mà vẫn lỗi = 3 phát đều trượt THẬT → mới đáng đi nước đổi cách trình bày cover.
    /// GỠ cùng nhãn vàng khi đóng vụ.
    @MainActor
    static func forceRepairNow() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            guard let window = scene.keyWindow ?? scene.windows.first,
                  let root = window.rootViewController else { continue }
            repair(window: window, root: root)
        }
    }

    /// Gọi thoải mái từ `onDismiss`/`onAppear` — vô hình, idempotent, tự gộp, tự hoãn tới lúc yên.
    @MainActor
    static func nudge() {
        schedule(retries: 5)
    }

    private static func schedule(retries: Int) {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            pending = false
            run(retries: retries)
        }
    }

    /// ✗ khai `@MainActor` cho các hàm dưới: chúng bị gọi từ closure GCD (nonisolated). Khuôn
    /// "closure GCD gọi thẳng UIKit" đã compile xanh ở bản 2.8 — khai isolation tường minh là tự
    /// mời lỗi compile mà máy Windows này không tự kiểm được.
    private static func run(retries: Int) {
        var blocked = false
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            guard let window = scene.keyWindow ?? scene.windows.first,
                  let root = window.rootViewController else { continue }
            // Cổng (a): transition đang chạy Ở BẤT KỲ TẦNG NÀO (push/pop kể cả vuốt-back tương
            // tác, present/dismiss đang bay) → chưa phải lúc, hẹn lại.
            guard !inTransition(root) else {
                blocked = true
                continue
            }
            // Cổng (b): cover FULL-SCREEN đang mở → cây cần sửa đang bị tháo khỏi window, sửa vô
            // ích; onDismiss của chính cover sẽ re-arm. Sheet/alert thì KHÔNG chặn — xem đầu file.
            if let presented = root.presentedViewController,
               presented.modalPresentationStyle == .fullScreen
                   || presented.modalPresentationStyle == .overFullScreen {
                blocked = true
                continue
            }
            repair(window: window, root: root)
        }
        if blocked && retries > 0 {
            schedule(retries: retries - 1)
        }
    }

    /// Có transition nào đang chạy trong cây VC không — đi qua `children` (chứa cả
    /// UINavigationController mà NavigationStack dựng ngầm) lẫn chuỗi `presentedViewController`.
    /// `transitionCoordinator` khác nil đúng bằng "hoạt ảnh chuyển màn đang bay", kể cả vuốt-back
    /// đang giữ ngón tay.
    private static func inTransition(_ vc: UIViewController) -> Bool {
        if vc.transitionCoordinator != nil { return true }
        if vc.children.contains(where: inTransition) { return true }
        if let presented = vc.presentedViewController, inTransition(presented) { return true }
        return false
    }

    /// Ba phát, chạy lúc scene YÊN (không present, không transition nào do mình biết).
    private static func repair(window: UIWindow, root: UIViewController) {
        // (1) Đổi hình học CỬA SỔ — nguồn gốc của mọi lề — rồi trả lại trong cùng nhịp.
        // Hai lần layoutIfNeeded = hai lượt tính lề trọn vẹn từ gốc; không frame dở dang nào
        // được render (render chỉ xảy ra lúc commit cuối nhịp). Cú co/trả đồng bộ trên main nên
        // không gì chen được vào giữa để làm frame trả về bị cũ.
        let frame = window.frame
        window.frame = CGRect(
            x: frame.origin.x, y: frame.origin.y,
            width: frame.width, height: frame.height - 0.5
        )
        window.layoutIfNeeded()
        window.frame = frame
        window.layoutIfNeeded()
        // (2) Toggle lề cộng thêm ở root VC (v1) — trả về 0 ở nhịp kế. Nhịp giữa có thể được
        // render với lề +0,5pt đúng MỘT khung hình — v1 đã giao và chủ app không nhận ra.
        root.additionalSafeAreaInsets = UIEdgeInsets(top: 0.5, left: 0, bottom: 0.5, right: 0)
        root.view.setNeedsLayout()
        root.view.layoutIfNeeded()
        // (3) Bắt TỪNG view đọc lại lề.
        poke(window)
        DispatchQueue.main.async {
            root.additionalSafeAreaInsets = .zero
            root.view.setNeedsLayout()
            root.view.layoutIfNeeded()
            poke(window)
        }
        // Bản đo 2.10: ghi nhận lượt chạy — luôn trên main (lịch asyncAfter main / forceRepairNow
        // @MainActor) nên gán thẳng.
        SafeAreaRepairStats.shared.repairCount += 1
    }

    private static func poke(_ view: UIView) {
        view.safeAreaInsetsDidChange()
        // `subviews` trả về MẢNG CHỤP nên duyệt an toàn kể cả khi cây đổi trong lúc poke.
        for sub in view.subviews { poke(sub) }
    }
}
