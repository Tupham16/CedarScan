import Foundation
import ARKit
import AVFoundation
import UIKit
import simd

/// Cảnh báo chất lượng đang hiển thị (viền màu + 1 dòng chữ ngắn).
struct QualityAlert: Equatable {
    enum Severity { case caution, critical }
    enum Code {
        case trackingLost, slowDown, turnSlowly, lowLight, tooClose
    }

    var severity: Severity
    var code: Code

    var message: String {
        switch code {
        case .trackingLost: return String(localized: "Hold still")
        case .slowDown: return String(localized: "Slow down")
        case .turnSlowly: return String(localized: "Turn slowly")
        case .lowLight: return String(localized: "Turn on lights")
        case .tooClose: return String(localized: "Step back a little")
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

    // 🔴 NHIỆT — CỐ Ý KHÔNG CÒN THEO DÕI, KHÔNG CÒN CẢNH BÁO. Chủ app chốt 2026-08-10:
    // **"Tắt hết cảnh báo máy nóng"**, lý do của ông: *"các app khác không báo như vậy… làm
    // giảm trải nghiệm khách. Và giờ có xem được mesh rồi nên họ không cần"*. Ông được hỏi
    // ĐÚNG câu "tắt hết, hay vẫn nhắc 1 lần TRƯỚC khi bấm quét khi máy đang nóng?" và trả lời
    // tắt hết ⇒ ✗ đề xuất lại, ✗ lặng lẽ thêm lại "cho khách đỡ khổ", ✗ dựng cổng ở màn bắt đầu.
    //
    // 🔴 NHƯNG SỰ THẬT ĐO ĐƯỢC VẪN ĐÚNG — GIỮ LẠI, nó tốn cả một chiến dịch đo mới có (bản 1.3,
    // 2 log máy thật): thermal `.serious` ⇒ iOS ÂM THẦM hạ camera ARKit 60→30fps NGAY TỪ GIÂY
    // ĐẦU. Đó là lời giải DUY NHẤT AI ĐÓ ĐANG CÓ cho vụ mesh TRÔI khi bắt đầu quét lúc máy đang
    // nóng — chính xác thì: giả thuyết "đói main thread" ĐÃ ĐO VÀ BỊ BÁC (cpuMain 3–6%,
    // mainGapMax median 18–19ms, hot và cool như nhau), còn các giả thuyết khác (nhịp depth
    // LiDAR, phơi sáng, GPU throttle) thì CHƯA AI KIỂM — ✗ đọc thành "đã loại trừ hết".
    // `ScanPerfProfiler` VẪN ghi nhiệt vào log nên dữ liệu không mất. Chủ app báo trôi lại thì
    // ĐÓ là câu trả lời tốt nhất đang có, và cách xử lý là NÓI CHUYỆN VỚI ÔNG. Đọc lại nhiệt
    // sau này là đúng MỘT dòng: `ProcessInfo.processInfo.thermalState`.

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
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
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
        let perfT0 = ScanPerfProfiler.tickBegin()
        defer { ScanPerfProfiler.tickEnd(.quality, perfT0) }
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

        // Ưu tiên: mất tracking > quá gần > tốc độ > xoay > ánh sáng
        // ⚠ Vế NHIỆT đã gỡ khỏi chuỗi này 10/08 (xem khối chú thích ở phần thuộc tính). Hai hệ
        // quả TRÔNG NHƯ LỖI MỚI nhưng là ĐÚNG: (1) cảnh báo THIẾU SÁNG nay hiện lại — vế `isHot`
        // CŨ nằm ngay TRÊN nó và trên máy nóng thì luôn đúng, tức đã che nó suốt buổi quét;
        // (2) rung/đọc tiếng nhiều hơn — `feedback(for:isNew:)` chỉ chạy khi `isNew`, mà cảnh
        // báo nhiệt cũ không bao giờ tự tắt nên mọi caution sau nó tới trong IM LẶNG. Lever nếu
        // chủ app kêu: hai toggle trong tab Tài khoản, ✗ sửa code.
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
            utterance.voice = AVSpeechSynthesisVoice(language: AppLanguage.speechVoice)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            speech.speak(utterance)
        }
    }
}
