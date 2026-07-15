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

    /// Preset cho CHẾ ĐỘ QUÉT MESH 3D (nguyên căn). Khác `preset` (dành cho luồng RoomPlan,
    /// nơi file màu chỉ là tư liệu phụ cần nhẹ): mật độ hình học do ARKit quyết định, trần
    /// đỉnh KHÔNG phải núm chỉnh độ nét mà chỉ là chỗ CẮT CỤT — nguyên căn phải lọt trọn.
    /// Nên cả 3 mức dùng chung van an toàn RAM 2M đỉnh (~110MB mảng mesh; nhà 2 tầng thực tế
    /// ~0.5–1.5M) và chỉ khác nhau về MÀU (độ phủ + độ nét khung màu) + thời gian lưu.
    var wholeHomePreset: Preset {
        let base = preset
        // Keyframe NHIỀU hơn preset RoomPlan cùng tier: bản quét nguyên căn trải 10–30
        // phút và cả trăm m² — độ phủ khung màu quyết định màu đúng/sai nhiều hơn mọi
        // thứ khác (trần đỉnh tăng ×16 mà giữ nguyên số khung là màu "đói" dữ liệu).
        // Mức Nét 160 khung: nhà lớn quét 20–30 phút vẫn đủ độ phủ màu sau các đợt
        // halving. RAM: 160 khung 640px ≈ 147MB + depth ≈ 31MB — chấp nhận trên máy Pro
        // (mức Nét đã cảnh báo "lưu lâu hơn, máy nóng hơn" trong caption).
        let keyframes: Int
        switch self {
        case .light: keyframes = 56
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
        case .light: return L.t("Light", "Nhẹ")
        case .medium: return L.t("Medium", "Vừa")
        case .high: return L.t("Fine", "Nét")
        }
    }

    /// Caption đổi theo lựa chọn — để người test biết mình đang so cái gì.
    /// (Hình học 3 mức GIỐNG NHAU — mật độ do ARKit quyết; chỉ khác màu + thời gian lưu.)
    var caption: String {
        switch self {
        case .light:
            return L.t("Coarse colors — fastest save", "Màu thô — lưu nhanh nhất")
        case .medium:
            return L.t("Balanced — recommended", "Cân bằng — khuyên dùng")
        case .high:
            return L.t(
                "Best colors — slower save, warmer phone",
                "Màu đẹp nhất — lưu lâu hơn, máy nóng hơn"
            )
        }
    }
}
