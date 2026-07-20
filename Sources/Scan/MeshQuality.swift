import Foundation

/// Mức độ nét của mesh màu (số đỉnh tối đa + độ phủ khung màu).
/// Chế độ RoomPlan dùng preset mặc định viết thẳng trong ColorMeshBuilder.init (mesh chỉ là
/// tư liệu nội bộ);
/// chế độ quét Mesh 3D cho người dùng chọn để so cả hai mức trên máy thật.
///
/// Ghi chú chọn số (từ review): màu là MÀU THEO ĐỈNH, đỉnh lưới LiDAR cách nhau ~2–5cm nên
/// khung màu 640px đã vượt độ phân giải của mesh — thứ quyết định chất lượng màu ở buổi quét
/// dài là ĐỘ PHỦ (số khung màu trải đều buổi quét), không phải độ rộng khung. Vì vậy hai mức
/// trên tăng maxKeyframes thay vì đẩy keyframeWidth lên 960 (tốn RAM + nghẽn main thread).
/// Mức "Nhẹ" ĐÃ BỎ (2026-07-19): đo ra nó không nhẹ hơn thật — hình học và dung lượng file
/// giống hệt hai mức kia (ARKit cố định mật độ lưới), chỉ màu xấu hơn. Giữ lại chỉ tổ làm
/// người dùng chọn nhầm rồi nhận bản quét màu kém mà chẳng tiết kiệm được gì.
enum MeshQuality: String, CaseIterable, Identifiable {
    case medium
    case high

    var id: Self { self }

    struct Preset {
        let maxVertices: Int
        let keyframeWidth: Int
        let maxKeyframes: Int
        let keyframeIntervalSec: Double
    }

    var preset: Preset {
        switch self {
        case .medium:
            return Preset(maxVertices: 250_000, keyframeWidth: 640, maxKeyframes: 48, keyframeIntervalSec: 0.4)
        case .high:
            return Preset(maxVertices: 450_000, keyframeWidth: 640, maxKeyframes: 64, keyframeIntervalSec: 0.4)
        }
    }

    /// Preset cho CHẾ ĐỘ QUÉT MESH 3D (nguyên căn). Khác `preset` (dành cho luồng RoomPlan,
    /// nơi file màu chỉ là tư liệu phụ cần nhẹ): mật độ hình học do ARKit quyết định, trần
    /// đỉnh KHÔNG phải núm chỉnh độ nét mà chỉ là chỗ CẮT CỤT — nguyên căn phải lọt trọn.
    /// Nên cả hai mức dùng chung van an toàn RAM 2M đỉnh (~110MB mảng mesh; nhà 2 tầng thực tế
    /// ~0.5–1.5M) và chỉ khác nhau về MÀU (độ phủ + độ nét khung màu) + thời gian lưu.
    var wholeHomePreset: Preset {
        let base = preset
        // Keyframe NHIỀU hơn preset RoomPlan cùng tier: bản quét nguyên căn trải 10–30
        // phút và cả trăm m² — độ phủ khung màu quyết định màu đúng/sai nhiều hơn mọi
        // thứ khác (trần đỉnh tăng ×16 mà giữ nguyên số khung là màu "đói" dữ liệu).
        // Mức Nét 160 khung: nhà lớn quét 20–30 phút vẫn đủ độ phủ màu sau các đợt
        // halving. RAM: 160 khung 640px ≈ 147MB + depth ≈ 31MB — chấp nhận trên máy Pro
        // (mức Nét đã cảnh báo "lưu lâu hơn" trong caption — KHÔNG nhắc nhiệt nữa, xem ghi
        // chú ở `caption` bên dưới: nhiệt lúc quét không phụ thuộc mức nét).
        let keyframes: Int
        switch self {
        case .medium: keyframes = 72
        case .high: keyframes = 160
        }
        return Preset(
            maxVertices: 2_000_000,
            keyframeWidth: base.keyframeWidth,
            maxKeyframes: keyframes,
            keyframeIntervalSec: base.keyframeIntervalSec
        )
    }

    /// Nhãn ngắn cho segmented picker.
    var label: String {
        switch self {
        case .medium: return L.t("Medium", "Vừa")
        case .high: return L.t("Fine", "Nét")
        }
    }

    /// Caption đổi theo lựa chọn.
    ///
    /// ĐÃ BỎ chữ "máy nóng hơn" ở mức Nét (2026-07-19) vì nó SAI và đã khiến chính chủ app quy
    /// kết nhầm nguyên nhân: hai mức dùng CHUNG keyframeWidth 640 và CHUNG keyframeIntervalSec
    /// 0.4, chỉ khác maxKeyframes (72 vs 160) tức khác NHỊP chụp qua cơ chế halving. Ở phút thứ
    /// 10 chênh nhau ~0,04% của MỘT nhân CPU — không đo được về nhiệt. Nhiệt lúc quét đến từ
    /// ARKit sceneReconstruction + overlay lưới 30Hz + video H.264 + poll depth 12Hz, toàn thứ
    /// KHÔNG phụ thuộc mức nét. Cái mức nét thật sự điều khiển: độ dày màu + thời gian LƯU.
    var caption: String {
        switch self {
        case .medium:
            return L.t("Enough color for CAD work — quicker save",
                       "Đủ màu để vẽ CAD — lưu nhanh hơn")
        case .high:
            return L.t("Recommended — twice the color coverage, longer save",
                       "Khuyên dùng — màu dày gấp đôi, lưu lâu hơn")
        }
    }

    /// Dòng chung đặt dưới picker. Gỡ hiểu lầm phổ biến nhất ("mức thấp = file nhẹ"): mật độ
    /// lưới do ARKit quyết định, cả hai mức chung trần 2M đỉnh, màu ghi định dạng cố định
    /// %.3f nên mỗi đỉnh tốn đúng bằng nhau byte → file ra gần như bằng nhau.
    static var sharedNote: String {
        L.t("Both levels give the same geometry and the same file size.",
            "Cả hai mức cho hình học và dung lượng file như nhau.")
    }

    /// Mặc định của @AppStorage("meshQuality"). Khoá này được khai báo ở BỐN nơi: HomeView,
    /// ProjectView, ScanAddressView, ScanQualityPickerView — @AppStorage không bao giờ ghi mặc
    /// định ngược vào UserDefaults, nên bốn chỗ lệch nhau là bốn màn hình đọc ra giá trị khác
    /// nhau cho cùng một khoá. Giữ ở một nguồn duy nhất để không thể lệch.
    static let storageDefault: MeshQuality = .high

    /// Nhãn cho rawValue ĐỌC TỪ ĐĨA (meta.json của bản quét đã lưu), khác với `label` của một
    /// case đang sống. Bản quét lưu trước 2026-07-19 mang rawValue "light"; case đó đã bỏ nên
    /// `MeshQuality(rawValue:)` trả nil và nhãn mức nét lặng lẽ biến mất khỏi danh sách. Ánh xạ
    /// lịch sử ở đây để bản quét cũ vẫn hiện đúng mức nó đã được quét.
    static func storedLabel(_ raw: String) -> String? {
        if raw == "light" { return L.t("Light", "Nhẹ") }
        return MeshQuality(rawValue: raw)?.label
    }
}
