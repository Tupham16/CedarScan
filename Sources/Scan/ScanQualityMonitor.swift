import Foundation
import ARKit
import RoomPlan
import AVFoundation
import UIKit
import simd

/// Cảnh báo chất lượng đang hiển thị (viền màu + 1 dòng chữ ngắn).
struct QualityAlert: Equatable {
    enum Severity { case caution, critical }
    enum Code { case trackingLost, doorAhead, doorTooFast, slowDown, turnSlowly, lowLight }

    var severity: Severity
    var code: Code

    var message: String {
        switch code {
        case .trackingLost: return L.t("Hold still", "Đứng yên một chút")
        case .doorAhead: return L.t("Slow through doorway", "Đi chậm qua cửa")
        case .doorTooFast: return L.t("Too fast through door", "Qua cửa nhanh quá")
        case .slowDown: return L.t("Slow down", "Đi chậm lại")
        case .turnSlowly: return L.t("Turn slowly", "Xoay chậm lại")
        case .lowLight: return L.t("Turn on lights", "Bật thêm đèn")
        }
    }
}

/// Theo dõi chất lượng quét real-time: tốc độ di chuyển/xoay, ánh sáng, tracking, đi qua cửa.
/// CHỈ ĐỌC arSession.currentFrame qua CADisplayLink riêng (không chiếm ARSession.delegate —
/// RoomPlan vẫn toàn quyền, đúng pattern của ColorMeshBuilder/ScanVideoRecorder).
final class ScanQualityMonitor: NSObject, ObservableObject {
    @Published private(set) var alert: QualityAlert?

    private weak var arSession: ARSession?
    private var displayLink: CADisplayLink?
    private let config = ScanQualityConfig.current

    // Người dùng đang thật sự quét (false trong lúc processing/roomReady — không tính metrics)
    private var isActive = false
    private var sessionStartTime: TimeInterval = -1

    // Cửa sổ trượt pose để tính vận tốc (nhiễu vi phân từng frame rất lớn — phải trung bình)
    private struct PoseSample {
        var t: TimeInterval
        var pos: SIMD3<Float>
        var quat: simd_quatf
    }
    private var poses: [PoseSample] = []

    // Tích lũy metrics
    private var lastTickTime: TimeInterval = -1
    private var activeTime: Double = 0
    private var limitedTime: Double = 0
    private var overspeedTime: Double = 0
    private var overRotationTime: Double = 0
    private var lowLightTime: Double = 0
    private var lightSum: Double = 0
    private var lightSamples: Int = 0
    private var minLight: Double = .greatestFiniteMagnitude
    private var speedSamples: [Float] = []
    private var relocalizations = 0
    private var longestLimited: Double = 0
    private var currentLimitedEpisode: Double = 0
    private var instructionCounts: [String: Int] = [:]

    // Trạng thái cảnh báo (debounce để không nhấp nháy)
    private var overspeedSince: TimeInterval = -1
    private var overRotationSince: TimeInterval = -1
    private var lowLightSince: TimeInterval = -1
    private var limitedSince: TimeInterval = -1
    private var alertRaisedAt: TimeInterval = -1
    private var allClearSince: TimeInterval = -1
    private var transientAlert: (alert: QualityAlert, until: TimeInterval)?

    // Cửa: lấy từ CapturedRoom live (qua delegate proxy), state machine per-door
    private struct DoorRef {
        var center: SIMD3<Float>
        var rotT: simd_float3x3   // transpose của rotation — đưa điểm về hệ local cửa
        var normal: SIMD3<Float>
        var halfW: Float
        var halfH: Float
    }
    private enum DoorPhase { case idle, approaching, crossing }
    private struct DoorState {
        var phase: DoorPhase = .idle
        var enterSign: Float = 0
        var speedSum: Double = 0
        var speedCount: Int = 0
        var lastEventTime: TimeInterval = -100
        var lastPrewarnTime: TimeInterval = -100
    }
    private var doors: [UUID: DoorRef] = [:]
    private var doorStates: [UUID: DoorState] = [:]
    private var doorIdsSeen: Set<UUID> = []
    private var doorCrossings = 0
    private var doorTooFast = 0

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
            lastTickTime = -1
        }
    }

    /// Gọi từ delegate proxy mỗi khi RoomPlan cập nhật phòng — lấy danh sách cửa live.
    /// Cửa mở toang hay bị nhận thành opening → gộp cả doors lẫn openings.
    func noteRoomUpdate(_ room: CapturedRoom) {
        guard config.enableDoorCoach else { return }
        var refs: [UUID: DoorRef] = [:]
        for surface in room.doors + room.openings {
            let m = surface.transform
            let rot = simd_float3x3(
                SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
            )
            refs[surface.identifier] = DoorRef(
                center: SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z),
                rotT: rot.transpose,
                normal: simd_normalize(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)),
                halfW: surface.dimensions.x / 2,
                halfH: surface.dimensions.y / 2
            )
            doorIdsSeen.insert(surface.identifier)
        }
        doors = refs
    }

    /// Gọi từ delegate proxy khi RoomPlan phát instruction — đếm + dùng làm tín hiệu thứ hai.
    func noteInstruction(_ instruction: RoomCaptureSession.Instruction) {
        let name: String
        switch instruction {
        case .normal: return
        case .moveCloseToWall: name = "moveCloseToWall"
        case .moveAwayFromWall: name = "moveAwayFromWall"
        case .slowDown: name = "slowDown"
        case .turnOnLight: name = "turnOnLight"
        case .lowTexture: name = "lowTexture"
        @unknown default: name = "other"
        }
        instructionCounts[name, default: 0] += 1
    }

    /// Chốt số liệu khi kết thúc quét (gọi 1 lần lúc Hoàn tất & Lưu).
    func finish() -> ScanMonitorMetrics {
        stop()
        var m = ScanMonitorMetrics()
        m.activeDurationSec = activeTime
        guard activeTime > 1 else { return m }
        m.normalPct = max(0, min(100, (activeTime - limitedTime) / activeTime * 100))
        m.limitedPct = min(100, limitedTime / activeTime * 100)
        m.relocalizations = relocalizations
        m.longestLimitedSec = max(longestLimited, currentLimitedEpisode)
        m.overspeedPct = min(100, overspeedTime / activeTime * 100)
        m.overRotationPct = min(100, overRotationTime / activeTime * 100)
        m.lowLightPct = min(100, lowLightTime / activeTime * 100)
        m.avgIntensity = lightSamples > 0 ? lightSum / Double(lightSamples) : 0
        m.minIntensity = minLight == .greatestFiniteMagnitude ? 0 : minLight
        if !speedSamples.isEmpty {
            let sorted = speedSamples.sorted()
            m.avgSpeedMps = Double(sorted.reduce(0, +)) / Double(sorted.count)
            m.p95SpeedMps = Double(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))])
        }
        m.doorsDetected = doorIdsSeen.count
        m.doorCrossings = doorCrossings
        m.doorTooFast = doorTooFast
        m.instructionCounts = instructionCounts
        return m
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
        var speedMeasured = false
        if let first = poses.first, t - first.t >= 0.25 {
            let span = Float(t - first.t)
            speed = simd_distance(pos, first.pos) / span
            let dq = first.quat.inverse * quat
            var angle = abs(dq.angle)
            if angle > .pi { angle = 2 * .pi - angle }
            rotationDps = angle * 180 / .pi / span
            speedMeasured = true
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

        // Tích lũy metrics (chỉ khi đang thật sự quét, sau warmup)
        let dt = lastTickTime > 0 ? min(0.5, t - lastTickTime) : 0
        lastTickTime = t
        if isActive && warmedUp && dt > 0 {
            activeTime += dt
            // Chỉ ghi khi cửa sổ đo đã đủ dài — ghi 0 giả làm tụt avg/p95
            if speedMeasured { speedSamples.append(speed) }
            if Double(speed) > config.maxSpeedSoft { overspeedTime += dt }
            if Double(rotationDps) > config.maxRotationSoft { overRotationTime += dt }
            if let light {
                lightSum += light
                lightSamples += 1
                minLight = min(minLight, light)
                if light < config.lowLightSoft { lowLightTime += dt }
            }
            if trackingLimited {
                limitedTime += dt
                currentLimitedEpisode += dt
            } else if currentLimitedEpisode > 0 {
                if currentLimitedEpisode > 1.0 { relocalizations += 1 }
                longestLimited = max(longestLimited, currentLimitedEpisode)
                currentLimitedEpisode = 0
            }
        }

        guard isActive else { return }

        // Debounce từng điều kiện
        updateCondition(&overspeedSince, active: Double(speed) > config.maxSpeedSoft, now: t)
        updateCondition(&overRotationSince, active: Double(rotationDps) > config.maxRotationSoft, now: t)
        updateCondition(&lowLightSince, active: (light ?? .greatestFiniteMagnitude) < config.lowLightSoft, now: t)
        updateCondition(&limitedSince, active: trackingLimited, now: t)

        if config.enableDoorCoach {
            processDoors(pos: pos, speed: speed, now: t)
        }

        updateAlert(now: t, speed: speed, rotationDps: rotationDps)
    }

    private func updateCondition(_ since: inout TimeInterval, active: Bool, now: TimeInterval) {
        if active {
            if since < 0 { since = now }
        } else {
            since = -1
        }
    }

    // MARK: - Cửa (state machine per-door)

    private func processDoors(pos: SIMD3<Float>, speed: Float, now: TimeInterval) {
        // Hướng di chuyển từ cửa sổ pose
        guard let first = poses.first, now - first.t >= 0.2 else { return }
        let velocity = (pos - first.pos) / Float(now - first.t)

        for (id, door) in doors {
            var st = doorStates[id] ?? DoorState()
            if now - st.lastEventTime < 3.0 {
                doorStates[id] = st
                continue
            }

            let q = door.rotT * (pos - door.center)   // x ngang, y dọc, z = khoảng cách có dấu
            let lateralOK = abs(q.x) < door.halfW + 0.4 && abs(q.y) < door.halfH + 0.5
            let approachSpeed = -sign(q.z) * simd_dot(velocity, door.normal)

            switch st.phase {
            case .idle:
                if lateralOK && abs(q.z) < Float(config.doorApproachDistance) && approachSpeed > 0.15 {
                    st.phase = .approaching
                }
            case .approaching:
                if !lateralOK || abs(q.z) > Float(config.doorApproachDistance) + 0.3 || approachSpeed < -0.1 {
                    st.phase = .idle
                    break
                }
                if Double(speed) > config.doorMaxCrossSpeed && now - st.lastPrewarnTime > 5.0 {
                    st.lastPrewarnTime = now
                    raiseTransient(QualityAlert(severity: .caution, code: .doorAhead), now: now)
                }
                if abs(q.z) < Float(config.doorCrossBand) {
                    st.phase = .crossing
                    st.enterSign = sign(q.z)
                    st.speedSum = 0
                    st.speedCount = 0
                }
            case .crossing:
                st.speedSum += Double(speed)
                st.speedCount += 1
                if sign(q.z) != st.enterSign && abs(q.z) > 0.05 {
                    let crossSpeed = st.speedCount > 0 ? st.speedSum / Double(st.speedCount) : 0
                    doorCrossings += 1
                    if crossSpeed > config.doorMaxCrossSpeed {
                        doorTooFast += 1
                        raiseTransient(QualityAlert(severity: .caution, code: .doorTooFast), now: now)
                    }
                    st.phase = .idle
                    st.lastEventTime = now
                } else if sign(q.z) == st.enterSign && abs(q.z) > 1.0 {
                    st.phase = .idle   // quay lui, không tính
                }
            }
            doorStates[id] = st
        }
    }

    // MARK: - Chọn cảnh báo hiển thị (ưu tiên + giữ tối thiểu, không chồng nhau)

    private func raiseTransient(_ a: QualityAlert, now: TimeInterval) {
        transientAlert = (a, now + 2.5)
    }

    private func updateAlert(now: TimeInterval, speed: Float, rotationDps: Float) {
        var candidate: QualityAlert?

        // Ưu tiên: mất tracking > cửa > tốc độ > xoay > ánh sáng
        if limitedSince > 0 && now - limitedSince > config.trackingWarnAfterSec {
            candidate = QualityAlert(severity: .critical, code: .trackingLost)
        } else if let transient = transientAlert, now < transient.until {
            candidate = transient.alert
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
            utterance.voice = AVSpeechSynthesisVoice(language: L.isVietnamese ? "vi-VN" : "en-US")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            speech.speak(utterance)
        }
    }
}

/// Proxy "nghe ké" RoomCaptureSessionDelegate: giữ nguyên MỌI callback cho RoomCaptureView
/// (delegate gốc), chỉ chép thêm sự kiện cửa + instruction cho ScanQualityMonitor.
/// Nếu gây vấn đề trên máy thật → tắt bằng enableDelegateProxy=false từ server;
/// mất doorway coach + đếm instruction nhưng mọi thứ khác vẫn chạy.
final class RoomCaptureSessionDelegateProxy: NSObject, RoomCaptureSessionDelegate {
    weak var original: RoomCaptureSessionDelegate?
    weak var monitor: ScanQualityMonitor?

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        monitor?.noteRoomUpdate(room)
        original?.captureSession(session, didUpdate: room)
    }

    func captureSession(_ session: RoomCaptureSession, didAdd room: CapturedRoom) {
        original?.captureSession(session, didAdd: room)
    }

    func captureSession(_ session: RoomCaptureSession, didChange room: CapturedRoom) {
        original?.captureSession(session, didChange: room)
    }

    func captureSession(_ session: RoomCaptureSession, didRemove room: CapturedRoom) {
        original?.captureSession(session, didRemove: room)
    }

    func captureSession(
        _ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction
    ) {
        monitor?.noteInstruction(instruction)
        original?.captureSession(session, didProvide: instruction)
    }

    func captureSession(
        _ session: RoomCaptureSession, didStartWith configuration: RoomCaptureSession.Configuration
    ) {
        original?.captureSession(session, didStartWith: configuration)
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        original?.captureSession(session, didEndWith: data, error: error)
    }
}
