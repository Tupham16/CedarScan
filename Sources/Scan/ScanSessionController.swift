import Foundation
import ARKit
import RoomPlan

enum ScanPhase {
    case scanning
    case processing
    case roomReady
}

final class ScanSessionController: NSObject, ObservableObject, RoomCaptureViewDelegate {
    @Published var phase: ScanPhase = .scanning
    @Published var rooms: [CapturedRoom] = []
    @Published var lastError: String?

    let arSession: ARSession
    let captureView: RoomCaptureView
    let qualityMonitor: ScanQualityMonitor
    private var recorder: ScanVideoRecorder?
    private var colorMesh: ColorMeshBuilder?
    private var delegateProxy: RoomCaptureSessionDelegateProxy?
    private var isCancelled = false
    private var hasStarted = false

    override init() {
        let session = ARSession()
        arSession = session
        captureView = RoomCaptureView(frame: .zero, arSession: session)
        qualityMonitor = ScanQualityMonitor(arSession: session)
        super.init()
        captureView.delegate = self
    }

    // RoomCaptureViewDelegate yêu cầu NSCoding/NSSecureCoding; app không dùng archiving.
    static var supportsSecureCoding: Bool { true }

    required init?(coder: NSCoder) {
        return nil
    }

    func encode(with coder: NSCoder) {}

    func startSession() {
        phase = .scanning
        if !hasStarted {
            hasStarted = true
            // Bật dựng lưới LiDAR trên chính ARSession dùng chung (RoomPlan tôn trọng config này).
            // Nhờ đó lấy được lưới 3D + màu để dựng file màu nội bộ.
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                let config = ARWorldTrackingConfiguration()
                config.sceneReconstruction = .mesh
                arSession.run(config)
                let colorMesh = ColorMeshBuilder(arSession: arSession)
                self.colorMesh = colorMesh
                colorMesh.start()
            }
            let recorder = ScanVideoRecorder(arSession: arSession)
            self.recorder = recorder
            recorder.start()
            qualityMonitor.start()
            // "Nghe ké" delegate của RoomCaptureSession (cửa + instruction) — forward nguyên
            // vẹn cho delegate gốc của RoomCaptureView. Kill-switch: enableDelegateProxy.
            if ScanQualityConfig.current.enableDelegateProxy {
                let proxy = RoomCaptureSessionDelegateProxy()
                proxy.original = captureView.captureSession.delegate
                proxy.monitor = qualityMonitor
                delegateProxy = proxy
                captureView.captureSession.delegate = proxy
            }
        }
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        qualityMonitor.setActive(true)
    }

    func finishCurrentRoom() {
        phase = .processing
        qualityMonitor.setActive(false)
        captureView.captureSession.stop(pauseARSession: false)
    }

    func scanNextRoom() {
        phase = .scanning
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        qualityMonitor.setActive(true)
    }

    func cancel() {
        isCancelled = true
        recorder?.cancel()
        recorder = nil
        colorMesh?.stop()
        colorMesh = nil
        qualityMonitor.stop()
        captureView.captureSession.stop()
    }

    /// Bản chụp mesh thô cho cross-check tường — PHẢI gọi trước finishColoredMesh().
    func snapshotMeshVertices() -> [[SIMD3<Float>]] {
        colorMesh?.snapshotWorldVertices() ?? []
    }

    /// Mesh bị cắt vì chạm trần đỉnh (nhà lớn) — báo cáo dùng để không trừ điểm oan.
    var meshCapReached: Bool {
        colorMesh?.capReached ?? false
    }

    /// Chốt số liệu chất lượng (gọi 1 lần lúc Hoàn tất & Lưu).
    func finishQualityMetrics() -> ScanMonitorMetrics {
        qualityMonitor.finish()
    }

    /// Dừng quay video và trả về file (gọi khi bấm Hoàn tất & Lưu).
    func finishRecording() async -> URL? {
        let url = await recorder?.finish()
        recorder = nil
        return url
    }

    /// Dựng và trả về file mô hình 3D CÓ MÀU (.ply) — nguyên liệu nội bộ. Nil nếu không có.
    func finishColoredMesh() async -> URL? {
        let url = await colorMesh?.exportColoredPLY()
        colorMesh = nil
        return url
    }

    // MARK: - RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if isCancelled { return false }
        if let error {
            // shouldPresent trả về false thì didPresent không được gọi nữa,
            // nên phải báo lỗi và mở lại phiên quét ngay tại đây.
            DispatchQueue.main.async {
                self.lastError = error.localizedDescription
                self.phase = .scanning
            }
            return false
        }
        return true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        if let error {
            lastError = error.localizedDescription
            phase = .scanning
            return
        }
        rooms.append(processedResult)
        phase = .roomReady
    }
}
