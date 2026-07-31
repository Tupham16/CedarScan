import Foundation

/// Cấu hình quét mesh màu. **CHỈ CÒN MỘT MỨC** — picker "Nét / Siêu nét" đã bỏ hẳn 2026-07-31
/// (kế hoạch: `PLAN-BO-PICKER-DO-NET.md`, phương án B, chủ app duyệt).
///
/// Vì sao bỏ: hai mức cũ khác nhau ĐÚNG một dòng — `maxKeyframes` 160 (.high) vs 320 (.ultra).
/// Cùng `maxVertices`, cùng số đỉnh, số mặt, dung lượng file. Kho khung màu CHỈ dùng để sơn
/// màu-theo-đỉnh, mà từ đợt lưu nhanh (`cb48ae5`) đường `geometryOnly` VỨT toàn bộ kho đó với
/// mọi bản quét bình thường (≥30 ảnh texture → màu do MÁY TRẠM bake từ ảnh thật). Picker vì vậy
/// không đụng tới sản phẩm giao, chỉ thu của khách 179MB (.high) / 358MB (.ultra) RAM suốt buổi.
///
/// 🔴 GIỮ enum + rawValue: `ScanRecord.meshQuality` vẫn ghi chuỗi này vào meta.json và
/// `MeshScanController` đọc `wholeHomePreset`. Không còn UI nào chọn, không còn @AppStorage nào
/// đọc — khoá UserDefaults "meshQuality" trên máy cũ nằm im, vô hại.
///
/// ✗ ĐỪNG mua độ nét bằng chia nhỏ tam giác mạnh hơn (đã đo và bác 2026-07-29): khoảng cách
/// giữa hai đỉnh tỉ lệ V^(-1/2), còn dung lượng file / thời gian lưu / phút 4G / thời gian đội
/// vẽ mở file đều tỉ lệ THUẬN với V. Đường đúng để nét thật là TEXTURE (máy trạm bake).
enum MeshQuality: String {
    case high

    struct Preset {
        let maxVertices: Int
        let keyframeWidth: Int
        let maxKeyframes: Int
        let keyframeIntervalSec: Double
    }

    /// Preset cho chế độ quét Mesh 3D (nguyên căn).
    ///
    /// 🔴 `maxVertices` 2M là VAN AN TOÀN RAM — chỗ CẮT CỤT để nguyên căn lọt trọn, KHÔNG phải
    /// núm chỉnh độ nét (mật độ lưới do ARKit quyết). ✗ hạ.
    ///
    /// `maxKeyframes` 60 (trước 160/320): kho khung màu nay CHỈ phục vụ ĐƯỜNG PHAO — buổi dưới
    /// 30 ảnh texture (recorder hỏng / quét vài chục giây), lúc đó app tự sơn màu-đỉnh và đội vẽ
    /// nhận PLY màu, còn máy trạm thì cũng không bake được. Mỗi khung ≈ 1,12MB (RGB 640×480 +
    /// depth 256×192) → 60 khung ≈ 67MB thay cho 179/358MB.
    /// ⚠ Kho nhỏ ⇒ `maybeCaptureColorFrame` chạm trần SỚM hơn ⇒ nhịp chụp nhân đôi sớm hơn ⇒
    /// khung màu trải thưa hơn ở buổi dài. Đúng chủ đích: buổi dài luôn đi đường máy trạm.
    var wholeHomePreset: Preset {
        Preset(maxVertices: 2_000_000, keyframeWidth: 640, maxKeyframes: 60, keyframeIntervalSec: 0.4)
    }

    /// Mức dùng cho mọi buổi quét. Giữ một hằng số duy nhất thay vì rải `.high` ở các call site.
    static let storageDefault: MeshQuality = .high
}
