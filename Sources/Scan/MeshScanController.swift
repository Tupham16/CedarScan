import Foundation
import ARKit
import UIKit

/// Điều khiển chế độ quét MESH 3D: chạy thẳng ARWorldTrackingConfiguration +
/// sceneReconstruction = .mesh, KHÔNG qua RoomPlan/RoomCaptureView.
/// Quét liền mạch mọi hình dạng, one-shot nhiều tầng, Dừng & Lưu bất kỳ lúc nào.
/// Sản phẩm: mesh màu (PLY → GLB/OBJ) + video walkthrough — không có floorplan/USDZ.
///
/// Khác luồng RoomPlan: KHÔNG có RoomCaptureSession pause ARSession hộ, nên controller
/// này phải tự `arSession.pause()` ở cả hai đường Dừng & Lưu lẫn Hủy.
final class MeshScanController: NSObject, ObservableObject, ARSessionDelegate {
    /// Chạm trần đỉnh mesh — khu vực quét thêm sẽ KHÔNG vào file. UI hiện banner cố định.
    @Published private(set) var capReached = false
    /// Phiên đang bị gián đoạn (cuộc gọi, khóa máy, đổi app) — đang chờ khôi phục.
    @Published private(set) var isInterrupted = false
    /// Tracking không hồi phục được sau gián đoạn / phiên lỗi → khuyên "Dừng & Lưu ngay".
    @Published private(set) var trackingLost = false

    let arSession = ARSession()
    let qualityMonitor: ScanQualityMonitor
    let quality: MeshQuality

    private var recorder: ScanVideoRecorder?
    private var colorMesh: ColorMeshBuilder?
    private var hasStarted = false
    private var isStopped = false
    private var capPollTimer: Timer?
    private var relocalizeTimer: Timer?

    init(quality: MeshQuality) {
        self.quality = quality
        qualityMonitor = ScanQualityMonitor(arSession: arSession)
        super.init()
    }

    var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    /// Số đỉnh mesh đã gom — UI chặn "Dừng & Lưu" khi gần như chưa quét được gì.
    var meshVertexCount: Int {
        colorMesh?.vertexCount ?? 0
    }

    /// Gọi từ onAppear của MeshScanFlowView — makeUIView của ARCameraViewRepresentable đã
    /// chạy trước đó, nên gán arSession.delegate tại đây chắc chắn KHÔNG bị ARSCNView đè.
    func startSession() {
        guard !hasStarted, isSupported else { return }
        hasStarted = true
        arSession.delegate = self
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        // Giữ isLightEstimationEnabled mặc định (true) — cảnh báo thiếu sáng cần nó.
        arSession.run(config)

        let colorMesh = ColorMeshBuilder(arSession: arSession, quality: quality)
        self.colorMesh = colorMesh
        colorMesh.start()
        let recorder = ScanVideoRecorder(arSession: arSession)
        self.recorder = recorder
        recorder.start()
        qualityMonitor.start()
        qualityMonitor.setActive(true)
        // Buổi quét 10–30 phút: không được để auto-lock cắt ngang phiên AR.
        UIApplication.shared.isIdleTimerDisabled = true
        // capReached được ColorMeshBuilder set trên tick main-thread (không observable) →
        // poll nhẹ 1s/lần để đẩy sang @Published cho banner SwiftUI.
        capPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let mesh = self.colorMesh else { return }
            if mesh.capReached && !self.capReached {
                self.capReached = true
            }
        }
    }

    /// Dừng quét và xuất (video, mesh PLY). Pause session TRƯỚC khi export — giải phóng
    /// camera/LiDAR và CPU dựng lưới cho việc dựng PLY (không còn RoomPlan nào cần session).
    func stopAndExport() async -> (videoURL: URL?, meshURL: URL?) {
        guard !isStopped else { return (nil, nil) }
        isStopped = true
        teardownCommon()
        arSession.pause()
        let videoURL = await recorder?.finish()
        recorder = nil
        let meshURL = await colorMesh?.exportColoredPLY()
        colorMesh = nil
        return (videoURL, meshURL)
    }

    func cancel() {
        guard !isStopped else { return }
        isStopped = true
        teardownCommon()
        recorder?.cancel()
        recorder = nil
        colorMesh?.stop()
        colorMesh = nil
        // BẮT BUỘC pause tường minh: luồng RoomPlan được RoomCaptureSession.stop() pause hộ,
        // ở đây không có ai làm thay — thiếu là camera/LiDAR chạy ngầm sau khi thoát.
        arSession.pause()
    }

    private func teardownCommon() {
        qualityMonitor.stop()
        capPollTimer?.invalidate()
        capPollTimer = nil
        relocalizeTimer?.invalidate()
        relocalizeTimer = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - ARSessionObserver (delegate queue mặc định = main)
    // Buổi quét dài thì gián đoạn (cuộc gọi/Face ID/khóa máy) gần như chắc chắn xảy ra.
    // Sau gián đoạn ARKit relocalize; nếu thất bại, anchor mới nằm ở HỆ TỌA ĐỘ LỆCH và sẽ
    // phá mesh (hai "căn nhà ma" chồng nhau) — nên chỉ gom tiếp khi tracking đã về normal.

    func sessionWasInterrupted(_ session: ARSession) {
        guard !isStopped else { return }
        isInterrupted = true
        colorMesh?.stop()
        qualityMonitor.setActive(false)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        guard !isStopped else { return }
        isInterrupted = false
        // Chờ relocalize tối đa 10s; không về normal được → khuyên lưu phần đã quét.
        relocalizeTimer?.invalidate()
        relocalizeTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self, !self.isStopped else { return }
            if case .some(.normal) = self.arSession.currentFrame?.camera.trackingState {
                // đã hồi phục — cameraDidChangeTrackingState xử lý rồi
            } else {
                self.trackingLost = true
            }
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        guard !isStopped, !isInterrupted else { return }
        if case .normal = camera.trackingState {
            relocalizeTimer?.invalidate()
            relocalizeTimer = nil
            trackingLost = false
            colorMesh?.start() // idempotent — chỉ tạo lại CADisplayLink nếu đã stop
            qualityMonitor.setActive(true)
        }
    }

    /// KHÔNG có hàm này thì ARKit reset tracking sau mọi gián đoạn — tệ hơn cả relocalize hụt.
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        true
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        guard !isStopped else { return }
        trackingLost = true
    }
}
