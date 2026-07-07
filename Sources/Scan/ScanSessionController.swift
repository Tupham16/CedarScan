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
    private var recorder: ScanVideoRecorder?
    private var colorMesh: ColorMeshBuilder?
    private var isCancelled = false
    private var hasStarted = false

    override init() {
        let session = ARSession()
        arSession = session
        captureView = RoomCaptureView(frame: .zero, arSession: session)
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
        }
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    func finishCurrentRoom() {
        phase = .processing
        captureView.captureSession.stop(pauseARSession: false)
    }

    func scanNextRoom() {
        phase = .scanning
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    func cancel() {
        isCancelled = true
        recorder?.cancel()
        recorder = nil
        colorMesh?.stop()
        colorMesh = nil
        captureView.captureSession.stop()
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
