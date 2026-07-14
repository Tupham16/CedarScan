import SwiftUI
import SceneKit
import ARKit

/// ARSCNView chỉ để HIỆN HÌNH CAMERA cho phiên AR do MeshScanController tự chạy.
/// ARSCNView không tự run/pause/đổi config session được gán vào — controller giữ toàn
/// quyền vòng đời (giống RoomCaptureViewRepresentable: dismantle KHÔNG pause session).
/// Lưới quét vẽ bằng MeshOverlayView chồng lên trên (tái dùng, đã chạy ổn với RoomPlan).
struct ARCameraViewRepresentable: UIViewRepresentable {
    let arSession: ARSession
    /// Delegate cần giữ trên session (MeshScanController). Gán lại SAU khi view nhận
    /// session — chống mọi thứ tự makeUIView/onAppear và mọi hành vi ARSCNView đụng
    /// vào delegate khi được gán session (belt-and-suspenders, 1 dòng).
    weak var sessionDelegate: ARSessionDelegate?

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = arSession
        if let sessionDelegate {
            arSession.delegate = sessionDelegate
        }
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = false
        view.antialiasingMode = .none        // đỡ GPU — MeshOverlayView còn render chồng lên
        view.preferredFramesPerSecond = 30
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
