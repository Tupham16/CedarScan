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

    static let defaults = ScanQualityConfig(
        enabled: true,
        maxSpeedSoft: 0.7,
        maxSpeedHard: 1.0,
        maxRotationSoft: 60,
        maxRotationHard: 100,
        lowLightSoft: 250,
        trackingWarnAfterSec: 1.0,
        warmupSec: 5.0
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
    }

    init(
        enabled: Bool,
        maxSpeedSoft: Double, maxSpeedHard: Double,
        maxRotationSoft: Double, maxRotationHard: Double,
        lowLightSoft: Double,
        trackingWarnAfterSec: Double, warmupSec: Double
    ) {
        self.enabled = enabled
        self.maxSpeedSoft = maxSpeedSoft
        self.maxSpeedHard = maxSpeedHard
        self.maxRotationSoft = maxRotationSoft
        self.maxRotationHard = maxRotationHard
        self.lowLightSoft = lowLightSoft
        self.trackingWarnAfterSec = trackingWarnAfterSec
        self.warmupSec = warmupSec
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
