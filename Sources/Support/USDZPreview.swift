import SwiftUI
import QuickLook

/// Trình xem mô hình 3D USDZ của Apple: xoay, phóng to, và cả chế độ AR đặt mô hình vào không gian thật.
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

/// Trình xem mô hình CÓ TEXTURE toàn màn hình (`ScanDetailView.texturedRow`) — `USDZPreview`
/// cộng đúng một nút Đóng.
///
/// 🔴 VÌ SAO PHẢI CÓ: `QLPreviewController` để nút **Done** của nó trên `navigationItem`, mà
/// `navigationItem` chỉ được VẼ khi controller nằm trong một `UINavigationController`. Dưới
/// `UIViewControllerRepresentable` nó là VC CON, `navigationController` = nil → **nút Done
/// KHÔNG BAO GIỜ hiện**. Trước bản này màn xem texture không có lối ra NÀO NHÌN THẤY ĐƯỢC (chủ
/// app báo 10/08). Sheet về nguyên tắc vẫn kéo-xuống-để-đóng được, nhưng cú kéo đó hoặc bị chính
/// cử chỉ xoay mô hình của QuickLook nuốt, hoặc khách không biết mà dùng — đúng cái bẫy đã ghi ở
/// `greyMeshURL`.
/// ⚠ Lỗi này CÓ TRƯỚC bản 1.4, nhưng ✗ chứng minh bằng lịch sử của FILE NÀY: `git log --follow`
/// nó ra đúng 1 commit (`0139c04`) chỉ nói file chưa từng sửa. Thứ định NGÀY của lỗi là call
/// site MODAL, thêm ở **`cb48ae5`** ("Lưu nhanh… xem mô hình có texture trong app", trước 1.3).
/// Bản 1.4 chỉ đặt dòng lưới xám ngay TRÊN dòng texture nên chủ app mới lần ra.
///
/// 🔴 ✗ NHÉT NÚT ĐÓNG VÀO THẲNG `USDZPreview`. Nó có call site THỨ HAI —
/// `ScanDetailView.legacyTab` — nơi mô hình RoomPlan cũ hiện NHÚNG TRONG TRANG (dưới thanh điều
/// hướng của app và dưới picker 3D/mặt bằng): nút thêm vào đó sẽ là một dấu X thừa nằm giữa
/// trang, và `dismiss()` của nó pop luôn ScanDetailView về danh sách bản quét.
///
/// ✗ đổi thành `NavigationStack` + nút Đóng trên `.toolbar`: bar-item host chính là chỗ vụ văng
/// 06/08 sống (`UIKitBarItemHost` đọc `@EnvironmentObject` trước khi cầu environment nối). Nút
/// phủ thường không có bar-item host nào, và màn này không cần gì từ environment.
/// Cùng khuôn với `GreyMeshViewerScreen` là CỐ Ý — hai trình xem 3D phải đóng giống hệt nhau.
struct TexturedModelViewerScreen: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            USDZPreview(url: url)
                .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    // Chip đen cố định, ✗ `.ultraThinMaterial`: nền của QuickLook đổi theo
                    // light/dark máy nên vật liệu sẽ ra gần trắng ở light mode và nuốt mất
                    // dấu X trắng. Đen 45% + glyph trắng đọc được trên CẢ HAI nền.
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .padding(.leading, 16)
            .padding(.top, 12)
            .accessibilityLabel(L.t("Close", "Đóng"))
        }
    }
}
