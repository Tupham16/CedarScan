import Foundation
import ARKit
import AVFoundation
import UIKit
import simd

/// Cảnh báo chất lượng đang hiển thị (viền màu + 1 dòng chữ ngắn).
struct QualityAlert: Equatable {
    enum Severity { case caution, critical }
    enum Code {
        case trackingLost, slowDown, turnSlowly, lowLight, overheating, tooClose
    }

    var severity: Severity
    var code: Code

    var message: String {
        switch code {
        case .trackingLost: return L.t("Hold still", "Đứng yên một chút")
        case .slowDown: return L.t("Slow down", "Đi chậm lại")
        case .turnSlowly: return L.t("Turn slowly", "Xoay chậm lại")
        case .lowLight: return L.t("Turn on lights", "Bật thêm đèn")
        case .overheating: return L.t("Phone is hot — short break", "Máy nóng — nghỉ chút cho nguội")
        case .tooClose: return L.t("Step back a little", "Lùi ra xa một chút")
        }
    }
}

/// Theo dõi chất lượng quét real-time: tốc độ di chuyển/xoay, ánh sáng, tracking, khoảng cách.
/// CHỈ ĐỌC arSession.currentFrame qua CADisplayLink riêng (không chiếm ARSession.delegate —
/// MeshScanController vẫn toàn quyền, đúng pattern của ColorMeshBuilder/ScanVideoRecorder).
///
/// CHỈ CÒN LÀ HUẤN LUYỆN VIÊN THỜI GIAN THỰC (2026-07-20, cùng đợt gỡ RoomPlan). Phần tích lũy
/// số liệu (`finish() -> ScanMonitorMetrics`) đã xoá cùng `ScanQualityReport`: người tiêu thụ duy
/// nhất của nó là báo cáo chấm điểm, mà báo cáo đó cần kết quả đối chiếu tường của RoomPlan
/// (`WallCrossCheck`) để có nghĩa. Giữ lại bộ đếm không ai đọc là đúng kiểu hỏng-lặng-lẽ: nó tốn
/// mỗi tick, trông như còn chạy, và người sửa sau sẽ tưởng `quality.json` vẫn được ghi.
/// Hệ quả có chủ đích: bản quét MỚI không còn `quality.json`, nên thẻ Kanban không còn mục
/// "📐 Scan quality". Bản quét CŨ đã có file đó trên máy thì `ScanUploader` vẫn gửi như trước.
final class ScanQualityMonitor: NSObject, ObservableObject {
    @Published private(set) var alert: QualityAlert?

    private weak var arSession: ARSession?
    private var displayLink: CADisplayLink?
    private let config = ScanQualityConfig.current

    // Người dùng đang thật sự quét (false trong lúc đặt tên/đang lưu — không cảnh báo gì)
    private var isActive = false
    private var sessionStartTime: TimeInterval = -1

    // Cửa sổ trượt pose để tính vận tốc (nhiễu vi phân từng frame rất lớn — phải trung bình)
    private struct PoseSample {
        var t: TimeInterval
        var pos: SIMD3<Float>
        var quat: simd_quatf
    }
    private var poses: [PoseSample] = []

    // Nhiệt: quét LiDAR + meshing + H.264 hàng chục phút dễ lên .serious — iOS hạ camera
    // xuống 30fps và meshing chậm lại mà không báo ai. Theo dõi qua notification.
    private var isHot = false
    private var thermalObserver: NSObjectProtocol?

    // "Quá gần": LiDAR kém chính xác dưới ~25-30cm — dí sát vật thể tạo lỗ trên mesh
    // + khung màu out nét.
    private static let tooCloseMeters: Float = 0.35
    private var tooCloseSince: TimeInterval = -1
    /// Coach "quá gần" CHỈ bật tường minh từ chế độ quét Mesh (nơi tự bật .sceneDepth).
    /// KHÔNG suy từ frame.sceneDepth != nil: giữ cờ tường minh thì người thêm luồng quét mới
    /// sau này phải tự quyết định, thay vì âm thầm thừa hưởng một hành vi không ai chọn.
    var tooCloseCoachEnabled = false

    // Trạng thái cảnh báo (debounce để không nhấp nháy)
    private var overspeedSince: TimeInterval = -1
    private var overRotationSince: TimeInterval = -1
    private var lowLightSince: TimeInterval = -1
    private var limitedSince: TimeInterval = -1
    private var alertRaisedAt: TimeInterval = -1
    private var allClearSince: TimeInterval = -1

    // Phản hồi không cần nhìn màn hình
    private let cautionHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let criticalHaptic = UINotificationFeedbackGenerator()
    private let speech = AVSpeechSynthesizer()
    private var lastSpeechTime: TimeInterval = -100

    private var hapticsEnabled: Bool {
        UserDefaults.standard.object(forKey: "scanCoachHaptics") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "scanCoachHaptics")
    }
    private var voiceEnabled: Bool {
        UserDefaults.standard.bool(forKey: "scanCoachVoice")
    }

    init(arSession: ARSession) {
        self.arSession = arSession
        super.init()
    }

    func start() {
        guard config.enabled, displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
        link.add(to: .main, forMode: .common)
        displayLink = link
        cautionHaptic.prepare()

        let hot = { (state: ProcessInfo.ThermalState) -> Bool in
            state == .serious || state == .critical
        }
        isHot = hot(ProcessInfo.processInfo.thermalState)
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.isHot = hot(ProcessInfo.processInfo.thermalState)
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
            self.thermalObserver = nil
        }
        alert = nil
    }

    func setActive(_ active: Bool) {
        isActive = active
        if !active {
            alert = nil
            poses.removeAll()
        }
    }

    // MARK: - Vòng lặp chính (12 Hz, chỉ đọc — không giữ ARFrame)

    @objc private func tick() {
        guard let frame = arSession?.currentFrame else { return }
        let t = frame.timestamp
        let camera = frame.camera
        let transform = camera.transform
        let pos = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let rot = simd_float3x3(
            simd_normalize(SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)),
            simd_normalize(SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)),
            simd_normalize(SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
        )
        let quat = simd_quatf(rot)
        let light = frame.lightEstimate.map { Double($0.ambientIntensity) }

        if sessionStartTime < 0 { sessionStartTime = t }
        let warmedUp = t - sessionStartTime > config.warmupSec

        // Lọc "correction jump" của ARKit (relocalize nhảy vị trí → spike vận tốc giả)
        if let last = poses.last {
            let dt = t - last.t
            if dt > 0, simd_distance(pos, last.pos) / Float(dt) > 3 {
                poses.removeAll(keepingCapacity: true)
            }
        }
        poses.append(PoseSample(t: t, pos: pos, quat: quat))
        while let first = poses.first, t - first.t > 0.6 { poses.removeFirst() }

        // Vận tốc trên cửa sổ trượt
        var speed: Float = 0
        var rotationDps: Float = 0
        if let first = poses.first, t - first.t >= 0.25 {
            let span = Float(t - first.t)
            speed = simd_distance(pos, first.pos) / span
            let dq = first.quat.inverse * quat
            var angle = abs(dq.angle)
            if angle > .pi { angle = 2 * .pi - angle }
            rotationDps = angle * 180 / .pi / span
        }

        let trackingLimited: Bool
        switch camera.trackingState {
        case .limited(let reason):
            trackingLimited = reason != .initializing
        case .notAvailable:
            trackingLimited = warmedUp
        case .normal:
            trackingLimited = false
        }

        guard isActive else { return }

        // Debounce từng điều kiện
        updateCondition(&overspeedSince, active: Double(speed) > config.maxSpeedSoft, now: t)
        updateCondition(&overRotationSince, active: Double(rotationDps) > config.maxRotationSoft, now: t)
        updateCondition(&lowLightSince, active: (light ?? .greatestFiniteMagnitude) < config.lowLightSoft, now: t)
        updateCondition(&limitedSince, active: trackingLimited, now: t)
        // Bỏ qua hẳn khi coach tắt — khỏi tốn lock CVPixelBuffer mỗi tick.
        let frontDepth: Float = tooCloseCoachEnabled
            ? (Self.centerDepth(of: frame) ?? .greatestFiniteMagnitude)
            : .greatestFiniteMagnitude
        updateCondition(&tooCloseSince, active: frontDepth < Self.tooCloseMeters, now: t)

        updateAlert(now: t, speed: speed, rotationDps: rotationDps)
    }

    private func updateCondition(_ since: inout TimeInterval, active: Bool, now: TimeInterval) {
        if active {
            if since < 0 { since = now }
        } else {
            since = -1
        }
    }

    /// Khoảng cách bề mặt trước camera (m) — median 5 điểm quanh tâm depth map LiDAR.
    /// nil khi phiên không bật .sceneDepth hoặc buffer khác định dạng.
    private static func centerDepth(of frame: ARFrame) -> Float? {
        guard let depth = frame.sceneDepth?.depthMap,
              CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32
        else { return nil }
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return nil }
        let w = CVPixelBufferGetWidth(depth)
        let h = CVPixelBufferGetHeight(depth)
        let rowBytes = CVPixelBufferGetBytesPerRow(depth)
        guard w >= 4, h >= 4 else { return nil }

        let points = [
            (w / 2, h / 2),
            (w / 4, h / 2), (3 * w / 4, h / 2),
            (w / 2, h / 4), (w / 2, 3 * h / 4),
        ]
        var samples: [Float] = []
        samples.reserveCapacity(points.count)
        for (x, y) in points {
            let value = base.advanced(by: y * rowBytes + x * 4)
                .assumingMemoryBound(to: Float32.self).pointee
            if value.isFinite && value > 0 {
                samples.append(value)
            }
        }
        // Median để 1-2 điểm nhiễu không kích cảnh báo oan
        guard samples.count >= 3 else { return nil }
        return samples.sorted()[samples.count / 2]
    }

    // MARK: - Chọn cảnh báo hiển thị (ưu tiên + giữ tối thiểu, không chồng nhau)

    private func updateAlert(now: TimeInterval, speed: Float, rotationDps: Float) {
        var candidate: QualityAlert?

        // Ưu tiên: mất tracking > quá gần > tốc độ > xoay > nhiệt > ánh sáng
        if limitedSince > 0 && now - limitedSince > config.trackingWarnAfterSec {
            candidate = QualityAlert(severity: .critical, code: .trackingLost)
        } else if tooCloseSince > 0 && now - tooCloseSince > 0.7,
                  Double(speed) <= config.maxSpeedHard,
                  Double(rotationDps) <= config.maxRotationHard {
            // Nhường khi đang vượt ngưỡng CỨNG tốc độ/xoay — cảnh báo critical bên dưới
            // phải thắng caution này (lia máy nhanh sát kệ/tường là ca tệ nhất của cả hai).
            candidate = QualityAlert(severity: .caution, code: .tooClose)
        } else if overspeedSince > 0 && now - overspeedSince > 0.5 {
            let severity: QualityAlert.Severity = Double(speed) > config.maxSpeedHard ? .critical : .caution
            candidate = QualityAlert(severity: severity, code: .slowDown)
        } else if overRotationSince > 0 && now - overRotationSince > 0.5 {
            let severity: QualityAlert.Severity = Double(rotationDps) > config.maxRotationHard ? .critical : .caution
            candidate = QualityAlert(severity: severity, code: .turnSlowly)
        } else if isHot {
            candidate = QualityAlert(severity: .caution, code: .overheating)
        } else if lowLightSince > 0 && now - lowLightSince > 1.0 {
            candidate = QualityAlert(severity: .caution, code: .lowLight)
        }

        if let candidate {
            allClearSince = -1
            if alert != candidate {
                // Giữ cảnh báo hiện tại tối thiểu 1.5s trừ khi cái mới nghiêm trọng hơn
                if let current = alert, now - alertRaisedAt < 1.5,
                   !(candidate.severity == .critical && current.severity == .caution) {
                    return
                }
                let wasNil = alert == nil
                let escalated = alert?.severity == .caution && candidate.severity == .critical
                alert = candidate
                alertRaisedAt = now
                feedback(for: candidate, isNew: wasNil || escalated, now: now)
            }
        } else if alert != nil {
            if allClearSince < 0 {
                allClearSince = now
            } else if now - allClearSince > 1.0 && now - alertRaisedAt > 1.5 {
                alert = nil
                allClearSince = -1
            }
        }
    }

    private func feedback(for alert: QualityAlert, isNew: Bool, now: TimeInterval) {
        guard isNew else { return }
        if hapticsEnabled {
            switch alert.severity {
            case .caution: cautionHaptic.impactOccurred()
            case .critical: criticalHaptic.notificationOccurred(.warning)
            }
        }
        if voiceEnabled && now - lastSpeechTime > 5.0 {
            lastSpeechTime = now
            let utterance = AVSpeechUtterance(string: alert.message)
            utterance.voice = AVSpeechSynthesisVoice(language: L.isVietnamese ? "vi-VN" : "en-US")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            speech.speak(utterance)
        }
    }
}
