import Foundation

/// Mức độ nét của mesh màu (số đỉnh tối đa + độ phủ khung màu).
/// Chế độ RoomPlan luôn dùng .light (mesh chỉ là tư liệu nội bộ);
/// chế độ quét Mesh 3D cho người dùng chọn để so cả ba mức trên máy thật.
///
/// Ghi chú chọn số (từ review): màu là MÀU THEO ĐỈNH, đỉnh lưới LiDAR cách nhau ~2–5cm nên
/// khung màu 640px đã vượt độ phân giải của mesh — thứ quyết định chất lượng màu ở buổi quét
/// dài là ĐỘ PHỦ (số khung màu trải đều buổi quét), không phải độ rộng khung. Vì vậy hai mức
/// trên tăng maxKeyframes thay vì đẩy keyframeWidth lên 960 (tốn RAM + nghẽn main thread).
enum MeshQuality: String, CaseIterable, Identifiable {
    case light
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
        case .light:
            return Preset(maxVertices: 120_000, keyframeWidth: 320, maxKeyframes: 40, keyframeIntervalSec: 0.4)
        case .medium:
            return Preset(maxVertices: 250_000, keyframeWidth: 640, maxKeyframes: 48, keyframeIntervalSec: 0.4)
        case .high:
            return Preset(maxVertices: 450_000, keyframeWidth: 640, maxKeyframes: 64, keyframeIntervalSec: 0.4)
        }
    }

    /// Nhãn ngắn cho segmented picker.
    var label: String {
        switch self {
        case .light: return L.t("Light", "Nhẹ")
        case .medium: return L.t("Medium", "Vừa")
        case .high: return L.t("Fine", "Nét")
        }
    }

    /// Caption đổi theo lựa chọn — để người test biết mình đang so cái gì.
    var caption: String {
        switch self {
        case .light:
            return L.t("Fast, small file, coarse colors", "Nhanh, file nhỏ, màu thô")
        case .medium:
            return L.t("Balanced — recommended", "Cân bằng — khuyên dùng")
        case .high:
            return L.t(
                "Best colors; bigger file, slower save, warmer phone",
                "Màu đẹp nhất; file lớn, lưu lâu hơn, máy nóng hơn"
            )
        }
    }
}
