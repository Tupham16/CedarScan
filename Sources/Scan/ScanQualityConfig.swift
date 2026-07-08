import Foundation

/// Ngưỡng cho Accuracy Suite (cảnh báo real-time + cross-check tường + chấm điểm).
/// Giá trị mặc định đặt bảo thủ theo nghiên cứu; server có thể ghi đè qua /catalog
/// (AppSetting "scan-quality-config") — tinh chỉnh KHÔNG cần build lại app.
struct ScanQualityConfig: Codable {
    // Bật/tắt từng phần (kill-switch từ server nếu có vấn đề trên máy thật)
    var enabled: Bool
    var enableDelegateProxy: Bool   // nghe instruction + cửa qua RoomCaptureSessionDelegate proxy
    var enableDoorCoach: Bool

    // Tốc độ (m/s, độ/giây) — EMA trên cửa sổ ~0.5s
    var maxSpeedSoft: Double        // cảnh báo mềm khi vượt
    var maxSpeedHard: Double        // cảnh báo mạnh
    var maxRotationSoft: Double     // độ/giây
    var maxRotationHard: Double

    // Ánh sáng (ambientIntensity, 1000 = trung tính theo Apple)
    var lowLightSoft: Double
    var lowLightHard: Double

    // Tracking
    var trackingWarnAfterSec: Double    // limited liên tục bao lâu thì cảnh báo
    var warmupSec: Double               // bỏ qua N giây đầu (initializing)

    // Cửa
    var doorApproachDistance: Double    // m — bắt đầu theo dõi khi lại gần
    var doorCrossBand: Double           // m — dải đo tốc độ băng qua
    var doorMaxCrossSpeed: Double       // m/s — nhanh hơn là "qua cửa quá nhanh"

    // Cross-check tường vs mesh thô (mét / độ)
    var wallBand: Double                // dải lấy điểm quanh mặt phẳng tường
    var wallEdgeMargin: Double          // né mép hai đầu tường (góc nhà)
    var wallVerticalMargin: Double      // né sát sàn/trần (phào, chân tường)
    var wallMinPoints: Int
    var wallMinCoverage: Double         // 0-1
    var wallOffsetOK: Double            // ≤ → OK
    var wallOffsetSuspect: Double       // ≤ → SUSPECT, vượt → MISALIGNED
    var wallAngleOK: Double             // độ
    var wallAngleSuspect: Double
    var wallResidOK: Double             // p90 residual
    var wallResidSuspect: Double

    // Chấm điểm
    var rescanScoreBelow: Int           // điểm dưới ngưỡng → khuyên quét lại
    var rescanMisalignedPct: Double     // % tường misaligned trên tường verified
    var rescanNotNormalPct: Double      // % thời gian tracking không normal
    var rescanRelocalizations: Int

    static let defaults = ScanQualityConfig(
        enabled: true,
        enableDelegateProxy: true,
        enableDoorCoach: true,
        maxSpeedSoft: 0.7,
        maxSpeedHard: 1.0,
        maxRotationSoft: 60,
        maxRotationHard: 100,
        lowLightSoft: 250,
        lowLightHard: 100,
        trackingWarnAfterSec: 1.0,
        warmupSec: 5.0,
        doorApproachDistance: 1.2,
        doorCrossBand: 0.75,
        doorMaxCrossSpeed: 0.5,
        wallBand: 0.15,
        wallEdgeMargin: 0.10,
        wallVerticalMargin: 0.25,
        wallMinPoints: 500,
        wallMinCoverage: 0.25,
        wallOffsetOK: 0.03,
        wallOffsetSuspect: 0.06,
        wallAngleOK: 2.0,
        wallAngleSuspect: 4.0,
        wallResidOK: 0.06,
        wallResidSuspect: 0.10,
        rescanScoreBelow: 55,
        rescanMisalignedPct: 30,
        rescanNotNormalPct: 25,
        rescanRelocalizations: 4
    )

    // Decode "khoan dung": server chỉ cần gửi field muốn đổi, thiếu field nào dùng mặc định.
    // Giá trị nguy hiểm bị CLAMP — config từ xa sai tay không được phép crash app
    // (vd wallMinPoints=0 từng cho phép RANSAC chạy trên mảng rỗng → fatalError mất bản quét).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaults
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        enableDelegateProxy = (try? c.decodeIfPresent(Bool.self, forKey: .enableDelegateProxy)) ?? d.enableDelegateProxy
        enableDoorCoach = (try? c.decodeIfPresent(Bool.self, forKey: .enableDoorCoach)) ?? d.enableDoorCoach
        maxSpeedSoft = (try? c.decodeIfPresent(Double.self, forKey: .maxSpeedSoft)) ?? d.maxSpeedSoft
        maxSpeedHard = (try? c.decodeIfPresent(Double.self, forKey: .maxSpeedHard)) ?? d.maxSpeedHard
        maxRotationSoft = (try? c.decodeIfPresent(Double.self, forKey: .maxRotationSoft)) ?? d.maxRotationSoft
        maxRotationHard = (try? c.decodeIfPresent(Double.self, forKey: .maxRotationHard)) ?? d.maxRotationHard
        lowLightSoft = (try? c.decodeIfPresent(Double.self, forKey: .lowLightSoft)) ?? d.lowLightSoft
        lowLightHard = (try? c.decodeIfPresent(Double.self, forKey: .lowLightHard)) ?? d.lowLightHard
        trackingWarnAfterSec = (try? c.decodeIfPresent(Double.self, forKey: .trackingWarnAfterSec)) ?? d.trackingWarnAfterSec
        warmupSec = (try? c.decodeIfPresent(Double.self, forKey: .warmupSec)) ?? d.warmupSec
        doorApproachDistance = (try? c.decodeIfPresent(Double.self, forKey: .doorApproachDistance)) ?? d.doorApproachDistance
        doorCrossBand = (try? c.decodeIfPresent(Double.self, forKey: .doorCrossBand)) ?? d.doorCrossBand
        doorMaxCrossSpeed = (try? c.decodeIfPresent(Double.self, forKey: .doorMaxCrossSpeed)) ?? d.doorMaxCrossSpeed
        wallBand = min(0.5, max(0.03, (try? c.decodeIfPresent(Double.self, forKey: .wallBand)) ?? d.wallBand))
        wallEdgeMargin = max(0, (try? c.decodeIfPresent(Double.self, forKey: .wallEdgeMargin)) ?? d.wallEdgeMargin)
        wallVerticalMargin = max(0, (try? c.decodeIfPresent(Double.self, forKey: .wallVerticalMargin)) ?? d.wallVerticalMargin)
        wallMinPoints = max(50, (try? c.decodeIfPresent(Int.self, forKey: .wallMinPoints)) ?? d.wallMinPoints)
        wallMinCoverage = min(1, max(0.01, (try? c.decodeIfPresent(Double.self, forKey: .wallMinCoverage)) ?? d.wallMinCoverage))
        wallOffsetOK = (try? c.decodeIfPresent(Double.self, forKey: .wallOffsetOK)) ?? d.wallOffsetOK
        wallOffsetSuspect = (try? c.decodeIfPresent(Double.self, forKey: .wallOffsetSuspect)) ?? d.wallOffsetSuspect
        wallAngleOK = (try? c.decodeIfPresent(Double.self, forKey: .wallAngleOK)) ?? d.wallAngleOK
        wallAngleSuspect = (try? c.decodeIfPresent(Double.self, forKey: .wallAngleSuspect)) ?? d.wallAngleSuspect
        wallResidOK = (try? c.decodeIfPresent(Double.self, forKey: .wallResidOK)) ?? d.wallResidOK
        wallResidSuspect = (try? c.decodeIfPresent(Double.self, forKey: .wallResidSuspect)) ?? d.wallResidSuspect
        rescanScoreBelow = (try? c.decodeIfPresent(Int.self, forKey: .rescanScoreBelow)) ?? d.rescanScoreBelow
        rescanMisalignedPct = (try? c.decodeIfPresent(Double.self, forKey: .rescanMisalignedPct)) ?? d.rescanMisalignedPct
        rescanNotNormalPct = (try? c.decodeIfPresent(Double.self, forKey: .rescanNotNormalPct)) ?? d.rescanNotNormalPct
        rescanRelocalizations = (try? c.decodeIfPresent(Int.self, forKey: .rescanRelocalizations)) ?? d.rescanRelocalizations
    }

    init(
        enabled: Bool, enableDelegateProxy: Bool, enableDoorCoach: Bool,
        maxSpeedSoft: Double, maxSpeedHard: Double, maxRotationSoft: Double, maxRotationHard: Double,
        lowLightSoft: Double, lowLightHard: Double,
        trackingWarnAfterSec: Double, warmupSec: Double,
        doorApproachDistance: Double, doorCrossBand: Double, doorMaxCrossSpeed: Double,
        wallBand: Double, wallEdgeMargin: Double, wallVerticalMargin: Double,
        wallMinPoints: Int, wallMinCoverage: Double,
        wallOffsetOK: Double, wallOffsetSuspect: Double,
        wallAngleOK: Double, wallAngleSuspect: Double,
        wallResidOK: Double, wallResidSuspect: Double,
        rescanScoreBelow: Int, rescanMisalignedPct: Double,
        rescanNotNormalPct: Double, rescanRelocalizations: Int
    ) {
        self.enabled = enabled
        self.enableDelegateProxy = enableDelegateProxy
        self.enableDoorCoach = enableDoorCoach
        self.maxSpeedSoft = maxSpeedSoft
        self.maxSpeedHard = maxSpeedHard
        self.maxRotationSoft = maxRotationSoft
        self.maxRotationHard = maxRotationHard
        self.lowLightSoft = lowLightSoft
        self.lowLightHard = lowLightHard
        self.trackingWarnAfterSec = trackingWarnAfterSec
        self.warmupSec = warmupSec
        self.doorApproachDistance = doorApproachDistance
        self.doorCrossBand = doorCrossBand
        self.doorMaxCrossSpeed = doorMaxCrossSpeed
        self.wallBand = wallBand
        self.wallEdgeMargin = wallEdgeMargin
        self.wallVerticalMargin = wallVerticalMargin
        self.wallMinPoints = wallMinPoints
        self.wallMinCoverage = wallMinCoverage
        self.wallOffsetOK = wallOffsetOK
        self.wallOffsetSuspect = wallOffsetSuspect
        self.wallAngleOK = wallAngleOK
        self.wallAngleSuspect = wallAngleSuspect
        self.wallResidOK = wallResidOK
        self.wallResidSuspect = wallResidSuspect
        self.rescanScoreBelow = rescanScoreBelow
        self.rescanMisalignedPct = rescanMisalignedPct
        self.rescanNotNormalPct = rescanNotNormalPct
        self.rescanRelocalizations = rescanRelocalizations
    }

    // MARK: - Bản đang dùng (cache UserDefaults, server ghi đè qua /catalog)

    private static let storageKey = "scanQualityConfig.v1"

    static var current: ScanQualityConfig = load() {
        didSet { persist(current) }
    }

    private static func load() -> ScanQualityConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let cfg = try? JSONDecoder().decode(ScanQualityConfig.self, from: data) else {
            return .defaults
        }
        return cfg
    }

    private static func persist(_ cfg: ScanQualityConfig) {
        if let data = try? JSONEncoder().encode(cfg) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
