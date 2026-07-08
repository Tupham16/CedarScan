import Foundation
import UIKit

/// Số liệu tích lũy trong lúc quét (ScanQualityMonitor sinh ra khi kết thúc).
struct ScanMonitorMetrics {
    var activeDurationSec: Double = 0
    var normalPct: Double = 100
    var limitedPct: Double = 0
    var relocalizations: Int = 0
    var longestLimitedSec: Double = 0
    var avgSpeedMps: Double = 0
    var p95SpeedMps: Double = 0
    var overspeedPct: Double = 0
    var overRotationPct: Double = 0
    var avgIntensity: Double = 0
    var minIntensity: Double = 0
    var lowLightPct: Double = 0
    var doorsDetected: Int = 0
    var doorCrossings: Int = 0
    var doorTooFast: Int = 0
    var instructionCounts: [String: Int] = [:]
}

/// Kết quả kiểm tra chéo 1 bức tường RoomPlan với mesh LiDAR thô.
struct WallCheckResult: Codable {
    enum Class: String, Codable {
        case ok, suspect, misaligned, unverified
    }
    var id: String          // UUID surface RoomPlan — khớp với rooms.json để đội biết tường nào
    var wallClass: Class
    var offsetCm: Double
    var angleDeg: Double
    var coveragePct: Double
    var lengthM: Double

    enum CodingKeys: String, CodingKey {
        case id
        case wallClass = "class"
        case offsetCm, angleDeg, coveragePct, lengthM
    }
}

/// Báo cáo chất lượng bản quét — hiện cho khách (report card) + gửi về Kanban cho đội vẽ.
struct ScanQualityReport: Codable {
    struct Tracking: Codable {
        var normalPct: Double
        var limitedPct: Double
        var relocalizations: Int
        var longestLimitedSec: Double
    }
    struct Motion: Codable {
        var avgSpeedMps: Double
        var p95SpeedMps: Double
        var overspeedPct: Double
        var overRotationPct: Double
    }
    struct Light: Codable {
        var avgIntensity: Double
        var minIntensity: Double
        var lowLightPct: Double
    }
    struct Doors: Codable {
        var detected: Int
        var crossings: Int
        var tooFast: Int
    }
    struct Walls: Codable {
        var total: Int
        var ok: Int
        var suspect: Int
        var misaligned: Int
        var unverified: Int
        var flagged: [WallCheckResult]
    }
    struct Deduction: Codable {
        var code: String
        var points: Double
        var advice: String      // tiếng Anh — portal/khách
        var adviceVi: String    // tiếng Việt — đội vẽ trên Kanban
    }
    struct Device: Codable {
        var model: String
        var os: String
    }

    var version: Int
    var score: Int
    var grade: String
    var rescanRecommended: Bool
    var durationSec: Double
    var floorAreaM2: Double?
    var device: Device
    var tracking: Tracking
    var motion: Motion
    var light: Light
    var doors: Doors
    var walls: Walls
    var deductions: [Deduction]

    /// Điểm 0-100 = 100 trừ dần; mỗi khoản trừ có trần riêng để 1 lỗi không nuốt cả điểm,
    /// và mỗi khoản đều gắn đúng 1 lời khuyên hành động được.
    static func build(
        metrics m: ScanMonitorMetrics,
        walls wallResults: [WallCheckResult],
        floorAreaM2: Double?,
        meshCapped: Bool = false,
        config cfg: ScanQualityConfig = .current
    ) -> ScanQualityReport {
        var deductions: [Deduction] = []
        func deduct(_ code: String, _ raw: Double, cap: Double, _ en: String, _ vi: String) {
            let pts = min(max(0, raw), cap)
            guard pts >= 0.5 else { return }
            deductions.append(Deduction(
                code: code, points: (pts * 10).rounded() / 10, advice: en, adviceVi: vi
            ))
        }

        let pctNotNormal = max(0, 100 - m.normalPct)
        deduct("TRACKING", 1.0 * pctNotNormal, cap: 25,
               "Tracking was lost \(pct(pctNotNormal)) of the time — move slower, avoid blank or glossy walls.",
               "Tracking bị mất \(pct(pctNotNormal)) thời gian — quét chậm lại, tránh tường trống/bề mặt bóng.")

        let overMove = max(m.overspeedPct, m.overRotationPct)
        deduct("OVERSPEED", 0.8 * overMove, cap: 15,
               "You moved too fast \(pct(overMove)) of the time — walk at about half your normal pace.",
               "Di chuyển nhanh quá \(pct(overMove)) thời gian — đi chậm bằng nửa tốc độ đi bộ bình thường.")

        deduct("LOW_LIGHT", 0.6 * m.lowLightPct, cap: 12,
               "Lighting was low \(pct(m.lowLightPct)) of the time — turn on lights in every room before scanning.",
               "Thiếu sáng \(pct(m.lowLightPct)) thời gian — bật đèn tất cả các phòng trước khi quét.")

        deduct("RELOC", 4.0 * Double(m.relocalizations), cap: 12,
               "Tracking had to recover \(m.relocalizations) time(s) — when it happens, stand still and point back at an area you already scanned.",
               "Tracking phải khôi phục \(m.relocalizations) lần — khi mất, đứng yên và lia lại vùng đã quét.")

        deduct("DOOR_FAST", 3.0 * Double(m.doorTooFast), cap: 12,
               "\(m.doorTooFast) doorway crossing(s) were too fast — pause 1-2 seconds in each doorway.",
               "\(m.doorTooFast) lần đi qua cửa quá nhanh — dừng 1-2 giây ở khung cửa.")

        let verified = wallResults.filter { $0.wallClass != .unverified }
        let misaligned = wallResults.filter { $0.wallClass == .misaligned }
        let suspect = wallResults.filter { $0.wallClass == .suspect }
        let pctMis = verified.isEmpty ? 0 : Double(misaligned.count) / Double(verified.count) * 100
        let pctSus = verified.isEmpty ? 0 : Double(suspect.count) / Double(verified.count) * 100
        deduct("WALL_MISMATCH", 0.5 * pctMis + 0.2 * pctSus, cap: 25,
               "\(misaligned.count) wall(s) disagree with raw LiDAR data (\(suspect.count) more suspect) — rescan those walls from 1.5-2 m away.",
               "\(misaligned.count) tường lệch so với dữ liệu LiDAR thô (\(suspect.count) tường nghi ngờ) — quét lại các tường này, đứng cách 1.5-2 m.")

        // meshCapped = nhà lớn chạm trần đỉnh mesh, tường unverified KHÔNG phải lỗi khách → miễn trừ
        let pctUnverified = wallResults.isEmpty ? 0 : Double(wallResults.count - verified.count) / Double(wallResults.count) * 100
        deduct("UNVERIFIED", (pctUnverified > 40 && !meshCapped) ? 5 : 0, cap: 5,
               "Many walls lack enough LiDAR data to verify — sweep the camera evenly across every wall.",
               "Nhiều tường thiếu dữ liệu để kiểm — lia camera phủ đều từng mặt tường.")

        if let area = floorAreaM2, area > 5, m.activeDurationSec > 0 {
            let secPerM2 = m.activeDurationSec / area
            if secPerM2 < 4 {
                let mins = Int(((4 * area) / 60).rounded(.up))
                deduct("PACE", (4 - secPerM2) * 3, cap: 8,
                       "The scan was rushed (\(oneDec(secPerM2)) s/m²) — a home this size deserves at least \(mins) minute(s).",
                       "Quét hơi vội (\(oneDec(secPerM2)) giây/m²) — nhà cỡ này nên quét ít nhất \(mins) phút.")
            }
        }

        let score = max(0, min(100, Int((100 - deductions.reduce(0) { $0 + $1.points }).rounded())))
        let grade: String
        switch score {
        case 85...: grade = "A"
        case 70..<85: grade = "B"
        case 55..<70: grade = "C"
        default: grade = "D"
        }

        // Khuyên quét lại khi hỏng nặng — 2 điều kiện sau bắt ca drift lớn làm cả RoomPlan
        // lẫn mesh cùng sai (cross-check "sạch" giả tạo).
        let rescan = score < cfg.rescanScoreBelow
            || pctMis >= cfg.rescanMisalignedPct
            || pctNotNormal >= cfg.rescanNotNormalPct
            || m.relocalizations >= cfg.rescanRelocalizations

        let flagged = wallResults
            .filter { $0.wallClass == .misaligned || $0.wallClass == .suspect }
            .sorted { a, b in
                if a.wallClass != b.wallClass { return a.wallClass == .misaligned }
                return a.offsetCm > b.offsetCm
            }
            .prefix(10)

        return ScanQualityReport(
            version: 1,
            score: score,
            grade: grade,
            rescanRecommended: rescan,
            durationSec: (m.activeDurationSec * 10).rounded() / 10,
            floorAreaM2: floorAreaM2.map { ($0 * 10).rounded() / 10 },
            device: Device(
                model: UIDevice.current.model,
                os: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
            ),
            tracking: Tracking(
                normalPct: round1(m.normalPct), limitedPct: round1(m.limitedPct),
                relocalizations: m.relocalizations, longestLimitedSec: round1(m.longestLimitedSec)
            ),
            motion: Motion(
                avgSpeedMps: round2(m.avgSpeedMps), p95SpeedMps: round2(m.p95SpeedMps),
                overspeedPct: round1(m.overspeedPct), overRotationPct: round1(m.overRotationPct)
            ),
            light: Light(
                avgIntensity: round1(m.avgIntensity), minIntensity: round1(m.minIntensity),
                lowLightPct: round1(m.lowLightPct)
            ),
            doors: Doors(detected: m.doorsDetected, crossings: m.doorCrossings, tooFast: m.doorTooFast),
            walls: Walls(
                total: wallResults.count,
                ok: wallResults.filter { $0.wallClass == .ok }.count,
                suspect: suspect.count,
                misaligned: misaligned.count,
                unverified: wallResults.count - verified.count,
                flagged: Array(flagged)
            ),
            deductions: deductions.sorted { $0.points > $1.points }
        )
    }

    /// Lời khuyên theo ngôn ngữ máy — cho report card trong app.
    func localizedAdvice(_ d: Deduction) -> String {
        L.isVietnamese ? d.adviceVi : d.advice
    }

    /// Chuyển thành object JSON thuần để nhét vào body createScan.
    func jsonObject() -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(self),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func pct(_ v: Double) -> String { "\(round1(v))%" }
    private static func oneDec(_ v: Double) -> String { String(format: "%.1f", v) }
    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    private static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}
