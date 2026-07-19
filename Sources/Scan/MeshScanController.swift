import Foundation
import ARKit
import UIKit

/// Điều khiển chế độ quét MESH 3D: chạy thẳng ARWorldTrackingConfiguration +
/// sceneReconstruction = .mesh, KHÔNG qua RoomPlan/RoomCaptureView.
/// Quét liền mạch mọi hình dạng, one-shot nhiều tầng, Dừng & Lưu bất kỳ lúc nào.
/// Sản phẩm: model.obj màu (+mtl) + video walkthrough — không có floorplan/USDZ
/// (PLY chỉ là file trung gian, ScanStore chuyển sang OBJ rồi xóa).
///
/// Khác luồng RoomPlan: KHÔNG có RoomCaptureSession pause ARSession hộ, nên controller
/// này phải tự `arSession.pause()` ở cả hai đường Dừng & Lưu lẫn Hủy.
final class MeshScanController: NSObject, ObservableObject, ARSessionDelegate {
    /// Mesh ĐANG đầy — khu vực quét thêm không vào file cho tới khi có chỗ trở lại
    /// (ARKit gộp anchor có thể giải phóng chỗ). UI hiện banner khi cờ bật.
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

    /// Anchor đã VÀO dữ liệu xuất (kèm số đỉnh đã ghi) — MeshOverlayView tô lưới trung
    /// thực theo đây (xanh = chắc chắn có trong file, đỏ = chưa/thiếu).
    var recordedAnchorCounts: [UUID: Int] {
        colorMesh?.recordedAnchorCounts ?? [:]
    }

    /// Gọi từ onAppear của MeshScanFlowView — makeUIView của ARCameraViewRepresentable đã
    /// chạy trước đó, nên gán arSession.delegate tại đây chắc chắn KHÔNG bị ARSCNView đè.
    func startSession() {
        guard !hasStarted, isSupported else { return }
        hasStarted = true
        arSession.delegate = self
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        // Bật depth map cho coach "quá gần" (LiDAR kém chính xác dưới ~25-30cm —
        // dí sát vật thể tạo lỗ trên mesh + khung màu out nét).
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
            qualityMonitor.tooCloseCoachEnabled = true
        }
        // Giữ isLightEstimationEnabled mặc định (true) — cảnh báo thiếu sáng cần nó.
        arSession.run(config)

        // wholeHomePreset: hình học full mật độ ARKit, trần 2M chỉ là van an toàn RAM —
        // tier chỉ quyết định chất lượng MÀU. (Preset thường 120k là cho luồng RoomPlan.)
        // strictVertexCap: không mất geometry đã quét khi ARKit gộp anchor lúc đầy.
        // captureDepthForOcclusion: kiểm tra che khuất khi gán màu (hết màu ghế in lên bàn).
        // refineLargeTriangles: lúc xuất chia nhỏ tam giác lớn để mảng tường/sàn phẳng có
        // thêm đỉnh màu — hết cảnh vài đỉnh kéo nhòe màu cả mét (đổi bằng lưu lâu hơn).
        // fillUncoloredVertices: cứu đỉnh "xám" (vùng đã quét nhưng không khung màu nào
        // qua bộ lọc) bằng lượt vét lỏng tay + vá màu lân cận — hết mảng xám trong OBJ.
        let colorMesh = ColorMeshBuilder(
            arSession: arSession,
            preset: quality.wholeHomePreset,
            strictVertexCap: true,
            captureDepthForOcclusion: true,
            refineLargeTriangles: true,
            fillUncoloredVertices: true
        )
        self.colorMesh = colorMesh
        colorMesh.start()
        // recordCameraTrack: ghi vị trí + hướng camera đồng bộ PTS video → camera-track.json
        // đóng kèm zip OBJ cho minimap kiểu CubiCasa (mũi tên trên floorplan khi xem video).
        // Cờ opt-in, CHỈ mesh mode bật — luồng RoomPlan giữ nguyên hành vi.
        let recorder = ScanVideoRecorder(arSession: arSession, recordCameraTrack: true)
        self.recorder = recorder
        recorder.start()
        qualityMonitor.start()
        qualityMonitor.setActive(true)
        // Buổi quét 10–30 phút: không được để auto-lock cắt ngang phiên AR.
        UIApplication.shared.isIdleTimerDisabled = true
        // Poll nhẹ 1s/lần trạng thái ĐẦY của builder (không observable) → @Published cho
        // banner SwiftUI. Dùng isFull (trạng thái hiện tại) chứ không phải capReached
        // (sticky): ARKit dọn anchor có thể giải phóng chỗ → banner phải tự hạ.
        capPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let mesh = self.colorMesh else { return }
            let full = mesh.isFull
            if full != self.capReached {
                self.capReached = full
                // Rung khi CHUYỂN sang đầy — người quét thường nhìn phòng chứ không nhìn
                // banner; thiếu tín hiệu này là tiếp tục quét vào chỗ không được ghi.
                if full {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                }
            }
        }
    }

    /// Dừng quét và xuất (video, mesh PLY). Pause session TRƯỚC khi export — giải phóng
    /// camera/LiDAR và CPU dựng lưới cho việc dựng PLY (không còn RoomPlan nào cần session).
    /// @MainActor BẮT BUỘC: hàm async không isolation sẽ chạy thân hàm trên executor NỀN
    /// (SE-0338) → Timer.invalidate/UIApplication/pause + sửa state đua với delegate main.
    @MainActor
    func stopAndExport() async -> (videoURL: URL?, meshURL: URL?, trackURL: URL?, hitCap: Bool) {
        guard !isStopped else { return (nil, nil, nil, false) }
        isStopped = true
        teardownCommon()
        // teardownCommon vừa bật lại auto-lock, nhưng export còn chạy hàng chục giây tới
        // vài phút (chia tam giác + bake màu): người quét bấm Lưu rồi ĐẶT MÁY XUỐNG, máy
        // tự khóa là app bị treo giữa chừng → mất trắng buổi quét. Giữ màn hình thức
        // suốt lúc lưu; MeshScanFlowView trả lại auto-lock sau khi lưu xong hẳn.
        UIApplication.shared.isIdleTimerDisabled = true
        colorMesh?.stop() // tắt CADisplayLink ngay trên main trước khi export
        // Gom CHỐT SỔ frame hiện tại trước khi pause: tick 2–5Hz nên nửa giây mesh cuối
        // (vùng vừa quét ngay trước khi bấm Dừng) có thể chưa vào bộ tích lũy.
        colorMesh?.ingestFinalFrame()
        arSession.pause()
        // capReached STICKY của builder = "đã từng phải bỏ dữ liệu" → call-site dùng để
        // mời khách quét BẢN BỔ SUNG cho phần còn thiếu (nhà rất lớn chạm trần 2M).
        let hitCap = colorMesh?.capReached ?? false
        let videoURL = await recorder?.finish()
        let trackURL = recorder?.cameraTrackURL // chỉ khác nil khi video hoàn tất OK
        recorder = nil
        let meshURL = await colorMesh?.exportColoredPLY()
        colorMesh = nil
        return (videoURL, meshURL, trackURL, hitCap)
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
        // Rung báo "đang KHÔNG ghi" — từ giờ lưới quét thêm sẽ hiện ĐỎ trên overlay.
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        // Hủy đồng hồ relocalize còn treo từ gián đoạn trước — không thì nó nổ giữa
        // gián đoạn thứ hai và báo "mất định vị" oan.
        relocalizeTimer?.invalidate()
        relocalizeTimer = nil
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
                // Đã hồi phục — thường cameraDidChangeTrackingState đã lo, nhưng gọi lại
                // cho chắc (cả hai idempotent) để không bao giờ kẹt ở trạng thái
                // "lưới vẫn vẽ mà không ghi gì".
                self.colorMesh?.start()
                self.qualityMonitor.setActive(true)
            } else {
                self.trackingLost = true
                UINotificationFeedbackGenerator().notificationOccurred(.error)
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
        if !trackingLost {
            trackingLost = true
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}
