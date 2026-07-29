import SwiftUI
import SceneKit
import ARKit

/// ARSCNView hiện hình camera cho phiên AR do MeshScanController tự chạy, VÀ vẽ luôn lớp phủ
/// lưới quét trong cùng scene.
///
/// ARSCNView không tự run/pause/đổi config session được gán vào — controller giữ toàn quyền
/// vòng đời — dismantle KHÔNG pause session.
///
/// 🔴 VÌ SAO LƯỚI NẰM TRONG VIEW NÀY chứ không phải một view chồng lên (đổi 2026-07-29 sau khi
/// chủ app báo "lưới rung khi lia máy", xác nhận hai lần):
/// Đời trước xếp chồng HAI view anh em — ARSCNView vẽ ảnh camera, một SCNView trong suốt vẽ
/// lưới với camera SceneKit tự lái. Hai view = hai CAMetalLayer = hai vòng render độc lập, mỗi
/// bên tự đọc `arSession.currentFrame` theo nhịp riêng. ARKit đẻ khung 60Hz còn hai lớp vẽ
/// 30fps mà không khoá pha → lưới và ảnh nền lệch nhau 0 hoặc 1 khung ARKit, và độ lệch đó ĐẢO
/// QUA ĐẢO LẠI. Lia máy 30–60°/s thì một khung lệch là hàng chục pixel → lưới trượt tới-lui.
/// Nay lưới là node trong `scene` của chính ARSCNView nên nó được rasterize bằng ĐÚNG ARFrame
/// đã sinh ra ảnh nền: sai số đăng ký bằng 0 theo định nghĩa, không còn gì để lệch.
/// ✗ ĐỪNG tách lưới ra view riêng lần nữa, dù vì lý do gì.
struct ARCameraViewRepresentable: UIViewRepresentable {
    let arSession: ARSession
    /// Delegate cần giữ trên session (MeshScanController). Gán lại SAU khi view nhận
    /// session — chống mọi thứ tự makeUIView/onAppear và mọi hành vi ARSCNView đụng
    /// vào delegate khi được gán session (belt-and-suspenders, 1 dòng).
    weak var sessionDelegate: ARSessionDelegate?

    /// Trần đỉnh HIỂN THỊ của lưới (khác trần dữ liệu xuất) — xem `MeshOverlayRenderer`.
    var meshMaxVerts: Int = 150_000
    /// Bật/tắt lớp phủ lưới. Tắt = ẩn node + dừng nhịp cập nhật (không phải tháo view).
    var showMesh: Bool = false
    /// Đưa vào từ mesh mode để lưới tô trung thực (trắng = đã ghi, đỏ = chưa); RoomPlan để nil.
    var recordedCounts: (() -> [UUID: Int])? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: MeshOverlayRenderer?
    }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = arSession
        if let sessionDelegate {
            // 🔴 PHẢI gán lại SAU `view.session = arSession`: ARSCNView tự nhận mình làm
            // delegate của session được gán vào, mà MeshScanController mới là nơi xử lý
            // didFailWithError / interruption / tracking state.
            arSession.delegate = sessionDelegate
        }
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = false
        // Khử răng cưa 2X: vạch wireframe rộng đúng 1 pixel, không khử răng cưa thì camera
        // nhích nửa pixel là vạch tắt/bật giữa hai hàng pixel — mắt đọc thành "lưới lấp lánh".
        // Đời trước để `.none` cho ảnh camera vì lưới nằm ở view khác; nay chung một view nên
        // cài ở đây. 2X chứ không 4X: đủ hết lấp lánh mà không nhân đôi tải GPU cho buổi quét
        // 20–30 phút (nhiệt là ràng buộc thật — xem TECH NOTES trong handoff).
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 30

        let renderer = MeshOverlayRenderer(arSession: arSession, maxVerts: meshMaxVerts)
        renderer.recordedCounts = recordedCounts
        renderer.attach(to: view)
        renderer.setVisible(showMesh)
        context.coordinator.renderer = renderer
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }
        renderer.recordedCounts = recordedCounts
        renderer.setVisible(showMesh)
    }

    /// CADisplayLink giữ strong target — không `detach()` là leak và renderer không bao giờ
    /// được giải phóng.
    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        coordinator.renderer?.detach()
        coordinator.renderer = nil
    }
}
