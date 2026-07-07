import Foundation
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

    let captureView: RoomCaptureView
    private var isCancelled = false

    override init() {
        captureView = RoomCaptureView(frame: .zero)
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
        captureView.captureSession.stop()
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
