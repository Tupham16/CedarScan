import SwiftUI
import SceneKit
import ARKit

/// ARSCNView chỉ để HIỆN HÌNH CAMERA cho phiên AR do MeshScanController tự chạy.
/// ARSCNView không tự run/pause/đổi config session được gán vào — controller giữ toàn
/// quyền vòng đời (giống RoomCaptureViewRepresentable: dismantle KHÔNG pause session).
/// Lưới quét vẽ bằng MeshOverlayView chồng lên trên (tái dùng, đã chạy ổn với RoomPlan).
struct ARCameraViewRepresentable: UIViewRepresentable {
    let arSession: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = arSession
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = false
        view.antialiasingMode = .none        // đỡ GPU — MeshOverlayView còn render chồng lên
        view.preferredFramesPerSecond = 30
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
