import UIKit

/// 🔴 VÁ LỖI "LỀ VỀ 0 SAU KHI ĐÓNG COVER QUÉT" (11/08, bản 2.8) — ép UIKit PHÁT LẠI vùng an toàn
/// xuống cả cây view sau khi một `.fullScreenCover` tháo xong.
///
/// **Lỗi (chủ app báo, 2.4→2.7 đều bị):** quét xong một dự án → mọi màn sau đó mất lề — header đè
/// lên danh sách, nút đáy bị đĩa Scan đè. Thoát app vào lại là hết.
///
/// **Số đo (bản 2.6/2.7, nhãn vàng `safeAreaProbe`) — nền tảng của cách vá này, ✗ đoán:**
/// lúc đang lỗi, `safeAreaInsets` của CỬA SỔ vẫn ĐÚNG (`win t47 b34` trên iPhone 12 Pro) nhưng
/// `GeometryProxy` của màn push đọc ra `geo t0 b0`. Tức tầng UIKit-cửa-sổ lành, tầng SwiftUI nhận
/// 0 — chỗ đứt nằm ở khâu TRUYỀN lề từ cửa sổ vào hosting view, bị đóng băng khi hosting view bị
/// THÁO RỒI GẮN LẠI vào window quanh vòng đời của fullScreenCover (kiểu present fullScreen gỡ hẳn
/// view bên dưới khỏi hierarchy; đường `didMoveToWindow` này chính là đường trong crash stack vụ
/// văng 11/08 — cùng cửa sổ thời gian, khác nạn nhân).
///
/// **Đã loại trừ bằng đo trước khi tới đây (✗ đào lại):** hỏng tầng cửa sổ (win vẫn đúng) ·
/// `.toolbar(.hidden, for: .tabBar)` (bản 2.7 gỡ cả hai màn, vẫn lỗi y nguyên) · hồi quy 2.4 /
/// đổi toolchain / `Group` đổi nhánh ở Home (chi tiết: SESSION-HANDOFF §LỖI ĐÈ CHỮ).
///
/// **Cơ chế vá:** đổi `additionalSafeAreaInsets` của root view controller đi 0,5pt trong ĐÚNG MỘT
/// nhịp runloop rồi trả về 0. Mỗi lần ĐỔI, UIKit bắt buộc chạy lại `safeAreaInsetsDidChange` +
/// phát lề xuống toàn cây — kể cả những view đang giữ giá trị cũ đông cứng. 0,5pt trong một nhịp
/// là dưới ngưỡng mắt thấy.
///
/// ⚠ ĐÂY LÀ SỬA-SAU-KHI-HỎNG, ✗ phải chữa gốc (gốc nằm trong UIKit/SwiftUI của iOS 26, ngoài tầm
/// với của app). Vì thế nó phải được gọi ở `onDismiss` của MỌI `.fullScreenCover` trong app —
/// hiện có ba: cover quét ở `HomeView` + `ProjectView`, trình xem 3D ở `ScanDetailView`. Thêm
/// cover mới thì gọi thêm; quên là lỗi quay lại đúng ở đường mới đó.
enum SafeAreaRepair {
    /// Gọi từ `onDismiss` của một `.fullScreenCover`, TRƯỚC mọi việc hậu-đóng khác (đặc biệt là
    /// trước `path.append` — đường "Đặt hàng ngay" push màn mới ngay trong `onDismiss`, mà lề
    /// phải được sửa TRƯỚC khi màn mới chốt bố cục; mục 3a chính là hậu quả của việc push vào
    /// một cây đang cầm lề 0).
    @MainActor
    static func nudge() {
        // TỪNG scene một root, ✗ `windows.first` toàn app: app khai `TARGETED_DEVICE_FAMILY
        // "1,2"`, mà trên iPad Split View mỗi UIWindowScene giữ key window RIÊNG — lấy "cái đầu
        // tiên" là có thể sửa nhầm cửa sổ lành và bỏ sót đúng cửa sổ vừa đóng cover (review đối
        // kháng 11/08 bắt được). Trên iPhone một cửa sổ, vòng lặp này = đúng một phần tử.
        let roots = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .compactMap { ($0.keyWindow ?? $0.windows.first)?.rootViewController }
        guard !roots.isEmpty else { return }
        // Đổi → ép phát lại NGAY trong nhịp này (layoutIfNeeded để cú push theo sau — nếu có —
        // thấy lề đã sửa), rồi trả về 0 ở nhịp KẾ TIẾP (một cú đổi nữa, một lần phát lại nữa).
        for root in roots {
            root.additionalSafeAreaInsets = UIEdgeInsets(top: 0.5, left: 0, bottom: 0.5, right: 0)
            root.view.setNeedsLayout()
            root.view.layoutIfNeeded()
        }
        DispatchQueue.main.async {
            for root in roots {
                root.additionalSafeAreaInsets = .zero
                root.view.setNeedsLayout()
            }
        }
    }
}
