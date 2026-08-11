import SwiftUI
import UIKit

/// 🔴 TRÌNH BÀY COVER QUÉT TRÊN MỘT **CỬA SỔ RIÊNG** — BẢN VÁ GỐC CỦA LỖI "LỀ VỀ 0 SAU KHI QUÉT"
/// (bản 2.12). ✗ present view controller lên cửa sổ gốc dưới BẤT KỲ hình thức nào.
///
/// **Chuỗi số đo dẫn tới đây — ✗ đào lại, ✗ thử lại các hướng đã chết:**
///  · `.fullScreenCover` (kiểu `.fullScreen`, THÁO cây view) → lề SwiftUI kẹt 0. (2.6→2.10)
///  · `.overFullScreen` (KHÔNG tháo cây) → **VẪN kẹt 0.** Chủ app xác nhận trên 2.11, và bằng
///    phép thử "mở màn quét → Hủy NGAY, không quét gì → ra Home → kích dự án": vẫn lỗi. ⇒ loại
///    hẳn nghi phạm RAM/ARKit/mesh, và loại luôn "tại cover THÁO cây".
///  · Mọi cú sửa-từ-ngoài (co cửa sổ, toggle `additionalSafeAreaInsets`, `poke` toàn cây, bắn
///    tay bỏ mọi cổng) đều TRƠ: lúc lỗi `root t47 b34` (UIKit lành tới view gốc) mà `geo t0 b0`.
///  ⇒ **Kết luận đo được:** present MỘT view controller toàn màn TỪ CỬA SỔ GỐC — kiểu gì cũng
///  vậy — làm iOS 26 đông cứng bộ máy vùng an toàn của cây SwiftUI trong cửa sổ đó, tới khi dựng
///  lại cả cửa sổ (đúng thứ "thoát app vào lại" làm) mới khỏi.
///
/// **Vì sao cửa sổ riêng chữa được:** cover nay là `rootViewController` của một `UIWindow` KHÁC,
/// windowLevel cao hơn. Cửa sổ GỐC (chứa `RootView` SwiftUI) KHÔNG BAO GIỜ trở thành "màn đang
/// present" — không có view controller nào được present lên nó — nên iOS không đụng tới vùng an
/// toàn của nó. Cây SwiftUI + `@State` + `NavigationPath` của cửa sổ gốc còn nguyên vẹn (đây còn
/// là điểm CỘNG cho đường "Đặt hàng ngay": `path.append` sau khi cover đóng vẫn chạy trên đúng
/// stack cũ). Cửa sổ riêng cũng tự phủ luôn `CedarTabBar` — khỏi lo thanh tab đè.
///
/// **Giữ được:** vòng đời `onAppear`/`onDisappear` của nội dung vẫn bắn (window hiện → view
/// controller appear); alert bên trong cover (LiDAR/camera-denied) present từ rootVC của cửa sổ
/// riêng, đóng cover là hạ luôn cả window nên alert đi theo — không kẹt. Hoạt ảnh trượt lên vẫn
/// có (animate transform của rootView).
///
/// **Cái phải tự lo (vì rời khỏi SwiftUI):** environment KHÔNG tự chảy sang cửa sổ khác — call
/// site PHẢI `.environmentObject(store)` cho nội dung (quên là `EnvironmentObject.error()` ngay).
///
/// ⚠ Trình xem 3D (`ScanDetailView.viewerTarget`) VẪN là `.fullScreenCover` — CỐ Ý chưa đổi.
/// Mở mô hình 3D vẫn có thể gây đông cứng y hệt; đường quét xác nhận xong thì đưa nó qua đây.
///
/// 🟡 **MỘT ẨN SỐ ĐÃ BIẾT, CỐ Ý CHƯA VÁ — ✗ "vá cho chắc" mà không đọc hết đoạn này.**
/// `window.isHidden = true` KHÔNG được UIKit bảo đảm sẽ bắn `viewDidDisappear` cho root VC của
/// cửa sổ (khác `dismiss(animated:)` của khuôn cũ — cái đó bắn chắc). Nếu nó không bắn thì
/// `.onDisappear` của `MeshScanFlowView` không chạy ⇒ mất `store.endBusy()` + `controller.cancel()`.
/// Vì sao vẫn ship mà không vá:
///  · **Hậu quả THẬT hôm nay = 0.** `endBusy` chỉ để mở khoá `purgeDeliveredScans`, mà việc dọn
///    tự động đã **TẮT HẲN** từ 1.8 (`RootView.autoPurgeAfterDelivery = false`) ⇒ `isBusy` hiện
///    không gác thứ gì đang chạy. Và `ScanStore` còn van thời gian `busyStaleAfter = 3600` tự nhả.
///  · `controller.cancel()` ở đó là LƯỚI, không phải đường chính: nút Hủy gọi `cancel()` tường
///    minh trước khi đóng; đường Lưu thì `stopAndExport` đã pause phiên; hai đường alert
///    (LiDAR-không-hỗ-trợ / camera-bị-từ-chối) thì phiên AR CHƯA HỀ start nên không có gì để nhả
///    (kể cả `isIdleTimerDisabled` — nó chỉ bật trong `controller.start()`).
///  · Vá mò thì ĐẺ LỖI: thêm `endBusy()` tường minh vào `dismiss()` mà `onDisappear` VẪN bắn là
///    trừ HAI LẦN cho một phiên → `busyCount` âm → hỏng khoá của phiên quét CHỒNG (bẫy đếm-không-
///    dùng-Bool ghi ở `ScanStore.busyCount`).
/// 🔴 **CÁCH TRẢ NỢ ĐÚNG (khi nào cần):** dời `beginBusy`/`endBusy` RA KHỎI `onAppear`/`onDisappear`
/// của `MeshScanFlowView`, đặt vào `present()`/`dismiss()` ở đây — vòng đời cửa sổ là ĐÚNG cái
/// khoá muốn bao, và ở đây thì chạy CHẮC CHẮN đúng một lần. Phải dời CẢ HAI cùng lúc, ✗ chỉ thêm.
/// Chỉ làm khi cờ `autoPurgeAfterDelivery` được bật lại, hoặc khi đo thấy khoá thật sự kẹt.
enum ScanCoverPresenter {
    /// Cửa sổ đang giữ cover (nil = không có). Chỉ đụng trên main.
    private static var coverWindow: UIWindow?
    /// Cửa sổ key TRƯỚC khi cover chiếm — trả lại lúc đóng (để bàn phím/thao tác về đúng cửa sổ
    /// gốc). Tự động thường cũng xong, nhưng trả tay là chắc.
    ///
    /// ⚠ `strong` là CỐ Ý và vô hại: nó giữ cửa sổ GỐC, thứ app sở hữu suốt vòng đời — ✗ đổi sang
    /// `weak` "cho sạch", `makeKey()` trên nil là mất bàn phím ở cửa sổ gốc sau khi đóng cover.
    private static var previousKeyWindow: UIWindow?

    // (Biến `generation` của bản 2.11 ĐÃ XOÁ ở 2.12. Nó chống retry-present mồ côi của khuôn
    // present-lên-VC cũ; khuôn cửa-sổ-riêng dựng cửa sổ ĐỒNG BỘ ngay trong `present()`, không có
    // lượt treo nào để mà mồ côi ⇒ biến đó thành CODE CHẾT và chú thích của nó thành LỜI KHAI SAI
    // ("nó chống cửa sổ mồ côi" — không, nó chẳng được đọc ở đâu). Review đối kháng 12/08 bắt.
    // ✗ khai lại nếu không đồng thời VIẾT chỗ ĐỌC nó.)

    /// Mở cover. Idempotent: đang có cover thì bỏ qua.
    ///
    /// 🔴 `onFailure` BẮT BUỘC (bẫy #13): chạy khi KHÔNG mở được (không tìm ra scene đang hiện) —
    /// call site phải lật `isMeshScanning = false` trong đó, nếu không binding kẹt true và nút
    /// quét chết im lặng tới khi mở lại app (mọi lối vào chỉ ghi true-đè-true).
    @MainActor
    static func present<Content: View>(_ content: Content, onFailure: @escaping () -> Void) {
        guard coverWindow == nil else { return }
        guard let scene = activeScene() else {
            onFailure()
            return
        }
        let window = UIWindow(windowScene: scene)
        // Trên thanh nội dung + thanh tab, DƯỚI cửa sổ alert của hệ thống.
        window.windowLevel = .normal + 1
        let host = UIHostingController(rootView: content)
        // Cover phải ĐỤC: nội dung camera tự vẽ nền, nhưng vùng ngoài safe area (tai thỏ) phải
        // che cửa sổ gốc — nếu không sẽ thấy Home lấp ló khi cover trượt lên.
        host.view.backgroundColor = .systemBackground
        window.rootViewController = host
        previousKeyWindow = scene.keyWindow
        window.makeKeyAndVisible()
        coverWindow = window

        // Trượt lên (thay cho hoạt ảnh present mặc định của VC — cửa sổ không tự có).
        // 🔴 `layoutIfNeeded()` TRƯỚC khi đo: `bounds` của cửa sổ vừa dựng có thể còn .zero cho
        // tới lượt layout đầu, và `h = 0` biến cú trượt thành KHÔNG LÀM GÌ (cover hiện thẳng, mất
        // hoạt ảnh — trông như app giật). Phao `scene.screen.bounds.height` cho ca layout vẫn
        // chưa xong. (Review đối kháng 12/08.)
        window.layoutIfNeeded()
        let h = window.bounds.height > 0 ? window.bounds.height : scene.screen.bounds.height
        host.view.transform = CGAffineTransform(translationX: 0, y: h)
        UIView.animate(withDuration: 0.35, delay: 0, options: .curveEaseOut) {
            host.view.transform = .identity
        }
    }

    /// Đóng cover rồi chạy `completion` SAU KHI trượt xong — vai `onDismiss` của cover cũ (mọi
    /// việc hậu-quét của call site nằm trong `completion`, đúng luật 06/08). Không có cover thì
    /// vẫn gọi `completion` (binding đã lật, việc hậu-quét vẫn phải chạy).
    @MainActor
    static func dismiss(completion: @escaping () -> Void) {
        guard let window = coverWindow else {
            completion()
            return
        }
        let h = window.bounds.height > 0 ? window.bounds.height : window.screen.bounds.height
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseIn) {
            window.rootViewController?.view.transform = CGAffineTransform(translationX: 0, y: h)
        } completion: { _ in
            window.isHidden = true
            // Trả key về cửa sổ gốc rồi mới buông tham chiếu (window giải phóng khi hết closure).
            previousKeyWindow?.makeKey()
            previousKeyWindow = nil
            coverWindow = nil            // nil ở ĐÂY (✗ sớm hơn): giữ idempotent suốt lúc trượt;
                                         // nhánh "Quét thêm" set true trong `completion` sau dòng
                                         // này nên present kế thấy nil và mở lại được.
            completion()
        }
    }

    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    }
}
