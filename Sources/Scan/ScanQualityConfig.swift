import Foundation

/// Ngưỡng cho huấn luyện viên quét thời gian thực (cảnh báo tốc độ/xoay/sáng/tracking/quá gần).
/// Giá trị mặc định đặt bảo thủ theo nghiên cứu; server có thể ghi đè qua /catalog
/// (AppSetting "scan-quality-config") — tinh chỉnh KHÔNG cần build lại app.
///
/// ĐÃ CẮT 21/29 FIELD (2026-07-20, cùng đợt gỡ RoomPlan): các nhóm `door*`, `wall*`, `rescan*`
/// và `enableDelegateProxy`/`enableDoorCoach` chỉ có nghĩa với RoomPlan (cửa lấy từ
/// `CapturedRoom`, tường đối chiếu bằng `WallCrossCheck`, điểm số do `ScanQualityReport` chấm) —
/// cả ba đã bị xoá. Núm điều khiển từ xa mà không điều khiển gì tệ hơn không có núm.
///
/// ⚠ HỆ QUẢ CHO VẬN HÀNH: kill-switch từ xa `{"enableDelegateProxy": false}` từng ghi trong sổ
/// tay nay KHÔNG còn tác dụng (không còn proxy nào để tắt). `{"enabled": false}` vẫn tắt được
/// toàn bộ huấn luyện viên như cũ. Server cứ gửi nguyên JSON cũ cũng an toàn: `Codable` bỏ qua
/// key lạ, và mọi field đều `decodeIfPresent` nên thiếu key thì rơi về mặc định.
struct ScanQualityConfig: Codable {
    /// Kill-switch toàn bộ huấn luyện viên (viền cảnh báo + rung + giọng nói).
    var enabled: Bool

    // Tốc độ (m/s, độ/giây) — trên cửa sổ trượt ~0.5s
    var maxSpeedSoft: Double        // cảnh báo mềm khi vượt
    var maxSpeedHard: Double        // cảnh báo mạnh
    var maxRotationSoft: Double     // độ/giây
    var maxRotationHard: Double

    // Ánh sáng (ambientIntensity, 1000 = trung tính theo Apple)
    var lowLightSoft: Double

    // Tracking
    var trackingWarnAfterSec: Double    // limited liên tục bao lâu thì cảnh báo
    var warmupSec: Double               // bỏ qua N giây đầu (initializing)

    // White balance lock (26/09, owner-approved): texbake says blotchy colour comes mainly from
    // exposure/colour jumping between shots. MeshScanController locks WHITE BALANCE ONLY (never
    // exposure) once tracking is normal, this many seconds after start. Kill-switch:
    // `{"lockWhiteBalance": false}`. ⚠ Server values only arrive after OrderSheet opens
    // (`APIClient.catalog()`), so a kill reaches a device one order-form visit later.
    var lockWhiteBalance: Bool
    var whiteBalanceLockDelaySec: Double

    // Auto torch (26/09, see AutoTorch). Kill-switch `{"autoTorch": false}` (same delivery lag
    // as above). torchLevel (0, 1] — heat: the LED sits next to the camera module.
    // torchOnBelow / torchOffAbove = ambientIntensity; AutoTorch forces off ≥ 1.5 × on.
    // 🔴 Frozen-default trap (see load()): the persisted blob stores these defaults too — a
    // changed default needs a rewrite line in load(), like maxRotationSoft.
    var autoTorch: Bool
    var torchLevel: Double
    var torchOnBelow: Double
    var torchOffAbove: Double

    static let defaults = ScanQualityConfig(
        enabled: true,
        maxSpeedSoft: 0.7,
        maxSpeedHard: 1.0,
        // 60 → 45 (26/09, owner "mục 5 cách 3"): the texture-shot gate skips photos above
        // 40°/s (TextureShotRecorder.maxTurnRateDegPerSec, 50 since 2.58) — warn before photos stop.
        // 45 → 68 (26/09 later, owner): "Turn slowly" too naggy; CubiCasa warns at ~1.5× our old
        // speed. Owner knows the cost: 40–68°/s again = no texture photo AND no warning.
        maxRotationSoft: 68,
        maxRotationHard: 100,
        lowLightSoft: 250,
        trackingWarnAfterSec: 1.0,
        warmupSec: 5.0,
        lockWhiteBalance: true,
        whiteBalanceLockDelaySec: 3.0,
        autoTorch: true,
        torchLevel: 0.7,
        torchOnBelow: 250,
        torchOffAbove: 500
    )

    // Decode "khoan dung": server chỉ cần gửi field muốn đổi, thiếu field nào dùng mặc định.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaults
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        maxSpeedSoft = (try? c.decodeIfPresent(Double.self, forKey: .maxSpeedSoft)) ?? d.maxSpeedSoft
        maxSpeedHard = (try? c.decodeIfPresent(Double.self, forKey: .maxSpeedHard)) ?? d.maxSpeedHard
        maxRotationSoft = (try? c.decodeIfPresent(Double.self, forKey: .maxRotationSoft)) ?? d.maxRotationSoft
        maxRotationHard = (try? c.decodeIfPresent(Double.self, forKey: .maxRotationHard)) ?? d.maxRotationHard
        lowLightSoft = (try? c.decodeIfPresent(Double.self, forKey: .lowLightSoft)) ?? d.lowLightSoft
        trackingWarnAfterSec = (try? c.decodeIfPresent(Double.self, forKey: .trackingWarnAfterSec)) ?? d.trackingWarnAfterSec
        warmupSec = (try? c.decodeIfPresent(Double.self, forKey: .warmupSec)) ?? d.warmupSec
        lockWhiteBalance = (try? c.decodeIfPresent(Bool.self, forKey: .lockWhiteBalance)) ?? d.lockWhiteBalance
        // Timer interval: finite and within 0…60 s, else default (a NaN/huge value must not
        // silently disable the lock or fire at once).
        let delay = (try? c.decodeIfPresent(Double.self, forKey: .whiteBalanceLockDelaySec)) ?? d.whiteBalanceLockDelaySec
        whiteBalanceLockDelaySec = (delay.isFinite && delay >= 0 && delay <= 60) ? delay : d.whiteBalanceLockDelaySec
        autoTorch = (try? c.decodeIfPresent(Bool.self, forKey: .autoTorch)) ?? d.autoTorch
        // Out-of-range level = ObjC exception in setTorchModeOn (a crash) → default.
        let level = (try? c.decodeIfPresent(Double.self, forKey: .torchLevel)) ?? d.torchLevel
        torchLevel = (level.isFinite && level > 0 && level <= 1) ? level : d.torchLevel
        let onBelow = (try? c.decodeIfPresent(Double.self, forKey: .torchOnBelow)) ?? d.torchOnBelow
        torchOnBelow = (onBelow.isFinite && onBelow > 0 && onBelow < 5000) ? onBelow : d.torchOnBelow
        let offAbove = (try? c.decodeIfPresent(Double.self, forKey: .torchOffAbove)) ?? d.torchOffAbove
        torchOffAbove = (offAbove.isFinite && offAbove > 0 && offAbove < 20000) ? offAbove : d.torchOffAbove
    }

    init(
        enabled: Bool,
        maxSpeedSoft: Double, maxSpeedHard: Double,
        maxRotationSoft: Double, maxRotationHard: Double,
        lowLightSoft: Double,
        trackingWarnAfterSec: Double, warmupSec: Double,
        lockWhiteBalance: Bool, whiteBalanceLockDelaySec: Double,
        autoTorch: Bool, torchLevel: Double, torchOnBelow: Double, torchOffAbove: Double
    ) {
        self.enabled = enabled
        self.maxSpeedSoft = maxSpeedSoft
        self.maxSpeedHard = maxSpeedHard
        self.maxRotationSoft = maxRotationSoft
        self.maxRotationHard = maxRotationHard
        self.lowLightSoft = lowLightSoft
        self.trackingWarnAfterSec = trackingWarnAfterSec
        self.warmupSec = warmupSec
        self.lockWhiteBalance = lockWhiteBalance
        self.whiteBalanceLockDelaySec = whiteBalanceLockDelaySec
        self.autoTorch = autoTorch
        self.torchLevel = torchLevel
        self.torchOnBelow = torchOnBelow
        self.torchOffAbove = torchOffAbove
    }

    // MARK: - Bản đang dùng (cache UserDefaults, server ghi đè qua /catalog)

    // GIỮ NGUYÊN KHOÁ v1 — đừng đổi sang v2 cho "sạch".
    //
    // Bản v1 đang nằm trên máy khách chứa 29 field cũ, nhưng decode nó bằng struct 8 field vẫn ra
    // ĐÚNG 8 giá trị (Codable bỏ qua key lạ). Đổi khoá thì `load()` không thấy gì → rơi về
    // `.defaults` → MẤT cấu hình mà vận hành đã đẩy xuống từ server (kể cả kill-switch
    // `{"enabled": false}`).
    //
    // Và nó KHÔNG tự lành nhanh: `APIClient.catalog()` chỉ có MỘT nơi gọi là `OrderSheet`
    // (mở form đặt hàng). Khách không đặt hàng thì cấu hình server KHÔNG BAO GIỜ về — mất vĩnh viễn.
    // Cái giá của việc giữ v1 chỉ là lần persist kế tiếp ghi đè blob 29 field bằng 8 field, tức
    // vứt đúng những field đã chết. Không ai mất gì.
    private static let storageKey = "scanQualityConfig.v1"

    static var current: ScanQualityConfig = load() {
        didSet { persist(current) }
    }

    private static func load() -> ScanQualityConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              var cfg = try? JSONDecoder().decode(ScanQualityConfig.self, from: data) else {
            return .defaults
        }
        // 🔴 The blob holds the FULL config, defaults included (every catalog fetch persists
        // `response.scanQuality ?? .defaults`), so a changed DEFAULT does not reach a device that
        // ever opened the order form until its next visit. 26/09: 60 was only ever the old
        // default (prod has no "scan-quality-config" row) → read it as the new default. Change a
        // default again = add the same kind of line here. 45 = the 2.54/2.55 default (→ 68).
        // A remote rollback must avoid 45/60 (load() rewrites them every launch): use 44/46, 59/61.
        if cfg.maxRotationSoft == 60 || cfg.maxRotationSoft == 45 { cfg.maxRotationSoft = defaults.maxRotationSoft }
        return cfg
    }

    private static func persist(_ cfg: ScanQualityConfig) {
        if let data = try? JSONEncoder().encode(cfg) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
