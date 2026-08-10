import SwiftUI
import QuickLook

/// Trình xem USDZ bằng QuickLook của Apple — **CHỈ CÒN MỘT CALL SITE: `ScanDetailView.legacyTab`**
/// (bản quét RoomPlan đời cũ, `model.usdz`, nhúng trong trang).
///
/// 🔴 **✗ DÙNG LẠI NÓ CHO MÔ HÌNH CÓ TEXTURE.** Chủ app test bản 1.8 (10/08) và báo màn xem
/// texture "bị phóng to và nền của nó là camera đang mở"; ông xác nhận nền CHẠY THEO máy ⇒ đúng
/// là camera. QuickLook mở `.usdz` bằng **AR Quick Look**, và vì controller này bị NHÚNG làm VC
/// con nên thanh công cụ của Apple (Done + nút gạt Object/AR) không vẽ ra ⇒ không có đường thoát
/// khỏi chế độ AR. Apple không có API công khai nào tắt chế độ đó. Màn texture nay tự vẽ bằng
/// SceneKit — toàn bộ lời khai + cơ chế ở `ModelViewer.swift`.
///
/// ⚠ **GẦN NHƯ CHẮC CHẮN CALL SITE LEGACY DƯỚI ĐÂY CŨNG DÍNH ĐÚNG LỖI ĐÓ**, chỉ là chưa ai còn
/// bản quét RoomPlan cũ để mở thử. Để nguyên vì đổi một đường KHÔNG KIỂM ĐƯỢC còn tệ hơn: bản cũ
/// là `model.usdz` do RoomPlan sinh, hình học và vật liệu khác hẳn bản bake. Ghi ở §OPEN.
struct USDZPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
