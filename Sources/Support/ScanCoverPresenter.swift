import SwiftUI
import UIKit

/// 🔴 TRÌNH BÀY COVER QUÉT BẰNG UIKIT `.overFullScreen` — BẢN VÁ GỐC CỦA LỖI "LỀ VỀ 0 SAU KHI
/// QUÉT" (bản 2.11). Thay cho `.fullScreenCover` ở HomeView + ProjectView.
///
/// **Vì sao phải bỏ `.fullScreenCover` — chuỗi số đo 2.6→2.10, ✗ đào lại:**
/// `.fullScreenCover` present kiểu `.fullScreen`, tức UIKit **THÁO HẲN view bên dưới khỏi
/// window** trong lúc cover mở rồi gắn lại khi đóng. Trên iOS 26, cú tháo-gắn đó làm bộ máy vùng
/// an toàn phía SwiftUI đông cứng ở 0: đo bằng nhãn vàng (2.10, lúc đang lỗi) —
/// `win t47 b34 · root t47 b34 · geo t0 b0` — tức UIKit lành TỚI TẬN VIEW GỐC mà cây SwiftUI vẫn
/// nhận 0. Mọi cú sửa từ ngoài đều trơ, kể cả bắn tay bỏ qua mọi cổng (`fix 9` + "chạm trơ"):
/// co cửa sổ + ép layout toàn cây · toggle `additionalSafeAreaInsets` · `poke`
/// `safeAreaInsetsDidChange()` từng view. Chỗ kẹt nằm BÊN TRONG SwiftUI — không đường ngoài nào
/// với tới. Cách chữa duy nhất còn lại: **đừng bao giờ tháo cây** — `.overFullScreen` giữ nguyên
/// view bên dưới suốt vòng đời cover, cơ chế gây bệnh không còn tồn tại.
///
/// **Giữ nguyên được gì so với `.fullScreenCover`:** vẫn là VC presentation THẬT — hoạt ảnh
/// slide-up y hệt (`coverVertical`), `onAppear`/`onDisappear` của nội dung vẫn bắn qua vòng đời
/// VC (quan trọng: `.onDisappear` của MeshScanFlowView cầm `controller.cancel()` +
/// `store.endBusy()` — lưới an toàn chống mất buổi quét), alert/sheet BÊN TRONG cover vẫn present
/// bình thường. Khác đúng một điều: view bên dưới không bị tháo (tốn thêm ít RAM giữ cây Home
/// sống sau cover — chấp nhận, cây đó nhẹ).
///
/// **Cái mất:** `@Environment(\.dismiss)` bên trong nội dung không còn nối với presentation của
/// SwiftUI ⇒ `MeshScanFlowView` nhận closure `dismiss` BƠM VÀO từ call site (lật binding
/// `isMeshScanning = false`; call site nghe `onChange` rồi gọi `dismiss(completion:)` ở đây).
///
/// ⚠ **`.fullScreenCover` CỦA TRÌNH XEM 3D (`ScanDetailView.viewerTarget`) CHƯA ĐỔI THEO** — nó
/// vẫn tháo-gắn cây và VẪN GÂY ĐÔNG CỨNG y hệt khi khách mở mô hình 3D. Đổi một cơ chế mỗi vòng
/// thử: chứng minh đường quét xong đã, viewer là vòng sau. Ghi ở SESSION-HANDOFF §LỖI ĐÈ CHỮ.
enum ScanCoverPresenter {
    /// Hosting VC của cover đang mở (nil = không có). Chỉ đụng trên main.
    private static var hosting: UIViewController?
    /// Một lượt present đang chờ retry (transition đang bay) — chống double-present khi
    /// `present()` bị gọi lại trong lúc lượt trước còn treo.
    private static var presentScheduled = false
    /// Số THẾ HỆ present/dismiss — tăng ở mỗi `present()`/`dismiss()`. Lượt retry đang treo mang
    /// số cũ thì tự bỏ. Chống ca review bắt được: dismiss chen vào giữa chuỗi retry → retry nổ
    /// muộn present ra một cover MỒ CÔI mà closure `dismiss` của nó ghi false-đè-false (binding
    /// không đổi, onChange không bắn) — cover không bao giờ đóng được.
    private static var generation = 0

    /// Present nội dung cover. Idempotent: đang mở / đang chờ mở thì bỏ qua.
    ///
    /// 🔴 Call site PHẢI tự `.environmentObject(...)` những gì nội dung cần — present bằng UIKit
    /// là RỜI CÂY SwiftUI, environment KHÔNG tự chảy sang. Quên `store` là
    /// `EnvironmentObject.error()` ngay khi cover mở (đúng họ crash 11/08 — lần này trap NGAY,
    /// không phải "thỉnh thoảng", nên bắt được ở lần quét đầu tiên).
    ///
    /// 🔴 `onFailure` BẮT BUỘC (bẫy #13, không mặc định): chạy khi present THẤT BẠI (không có
    /// cửa sổ / UIKit từ chối) — call site phải lật `isMeshScanning = false` trong đó. Thiếu nó
    /// thì binding kẹt true mà không có cover: mọi lối vào quét từ đó ghi true-đè-true, onChange
    /// không bao giờ bắn lại, nút quét CHẾT IM LẶNG tới khi mở lại app (review 11/08, cả ba lens
    /// cùng bắt). `.fullScreenCover` cũ tự đối chiếu binding↔presentation hộ; khuôn UIKit thì
    /// mình phải tự làm.
    @MainActor
    static func present<Content: View>(_ content: Content, onFailure: @escaping () -> Void) {
        // Hosting cũ đã bị tháo ngoài ý muốn (presenting VC chết…) → coi như không còn.
        if let existing = hosting, existing.presentingViewController == nil {
            hosting = nil
        }
        guard hosting == nil, !presentScheduled else { return }
        presentScheduled = true
        generation += 1
        attemptPresent(content, retries: 3, gen: generation, onFailure: onFailure)
    }

    /// Đóng cover rồi chạy `completion` SAU KHI hoạt ảnh đóng xong — tương đương `onDismiss` của
    /// `.fullScreenCover` (mọi việc hậu-quét của call site nằm trong completion này, đúng luật
    /// "mọi việc hậu-quét nằm ở onDismiss" đã trả giá 06/08).
    /// Không có cover nào đang mở thì vẫn gọi `completion` — binding đã lật, việc hậu-quét vẫn
    /// phải chạy.
    @MainActor
    static func dismiss(completion: @escaping () -> Void) {
        generation += 1          // huỷ mọi retry present đang treo
        presentScheduled = false
        guard let vc = hosting else {
            completion()
            return
        }
        hosting = nil
        if let presenter = vc.presentingViewController {
            // 🔴 Dismiss QUA PRESENTER, ✗ `vc.dismiss(...)`. Hợp đồng UIKit: gọi dismiss trên VC
            // đang CÓ presentedViewController là đóng ĐỨA CON, không phải chính nó — mà cover này
            // có alert con thật (LiDAR/camera-denied trong MeshScanFlowView), và nút của chính
            // alert đó là thứ lật binding, tức lúc dismiss chạy thì alert còn đang tháo dở.
            // `vc.dismiss` khi ấy đóng nhầm xác alert và COVER KẸT VĨNH VIỄN (binding đã false,
            // không đường nào bắn lại; onDisappear không chạy = idle timer kẹt + endBusy mất).
            // Dismiss từ presenter nuốt cả VC lẫn mọi thứ nó đang present trong MỘT transition,
            // completion vẫn chạy đúng một lần. (Review 11/08, lens lifecycle — MAJOR.)
            presenter.dismiss(animated: true, completion: completion)
        } else {
            completion()
        }
    }

    /// Thử present; presenter đang bận transition thì đợi 0,25s thử lại (≤3 lần). Luồng vào cover
    /// vốn đã đi qua "present từ onDismiss của sheet" nên gần như không bao giờ phải retry — đây
    /// là lưới an toàn, không phải đường thường.
    private static func attemptPresent<Content: View>(
        _ content: Content, retries: Int, gen: Int, onFailure: @escaping () -> Void
    ) {
        // Thế hệ đã đổi (dismiss chen vào lúc đang chờ retry) → bỏ lượt, KHÔNG gọi onFailure:
        // binding đã được phía dismiss lo, present ra lúc này mới là tạo cover mồ côi.
        guard gen == generation else {
            presentScheduled = false
            return
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                ?? scenes.first,
              let window = scene.keyWindow ?? scene.windows.first,
              let root = window.rootViewController else {
            // Không có cửa sổ (app đang nền?) — thất bại, trả binding về false qua onFailure.
            presentScheduled = false
            onFailure()
            return
        }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        if top.transitionCoordinator != nil, retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                attemptPresent(content, retries: retries - 1, gen: gen, onFailure: onFailure)
            }
            return
        }
        let vc = UIHostingController(rootView: content)
        // 🔴 `.overFullScreen`, ✗ `.fullScreen` — TOÀN BỘ lý do tồn tại của file này nằm ở một
        // dòng này. Đổi về `.fullScreen` là lỗi đè chữ quay lại nguyên vẹn.
        vc.modalPresentationStyle = .overFullScreen
        // `.overFullScreen` giữ cây bên dưới trong hierarchy ⇒ VoiceOver có thể vuốt THOÁT ra
        // sau cover (bấm được cả dòng dự án/tab bar giữa buổi quét). Repo đã trả giá 2 lần vì VO
        // lọt focus ở đúng luồng này — một dòng chặn cả họ lỗi:
        vc.view.accessibilityViewIsModal = true
        top.present(vc, animated: true)
        hosting = vc
        presentScheduled = false
        // Kiểm present có ĂN THẬT không: UIKit từ chối ("Attempt to present while...") là từ chối
        // IM LẶNG — `presentingViewController` vẫn nil ở nhịp sau. Không kiểm là binding kẹt true.
        DispatchQueue.main.async {
            guard gen == generation else { return } // dismiss đã chen vào, phía đó lo rồi
            if vc.presentingViewController == nil {
                hosting = nil
                onFailure()
            }
        }
    }
}
