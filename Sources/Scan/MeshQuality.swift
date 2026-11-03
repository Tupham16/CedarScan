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
    /// 🔴 `maxVertices` (= `deviceVertexCap`, theo RAM máy) là VAN AN TOÀN RAM — chỗ CẮT CỤT để
    /// nguyên căn lọt trọn, KHÔNG phải núm chỉnh độ nét (mật độ lưới do ARKit quyết). ✗ hạ.
    ///
    /// `maxKeyframes` 60 (trước 160/320): kho khung màu nay CHỈ phục vụ ĐƯỜNG PHAO — buổi dưới
    /// 30 ảnh texture (recorder hỏng / quét vài chục giây), lúc đó app tự sơn màu-đỉnh và đội vẽ
    /// nhận PLY màu, còn máy trạm thì cũng không bake được. Mỗi khung ≈ 1,12MB (RGB 640×480 +
    /// depth 256×192) → 60 khung ≈ 67MB thay cho 179/358MB.
    /// ⚠ Kho nhỏ ⇒ `maybeCaptureColorFrame` chạm trần SỚM hơn ⇒ nhịp chụp nhân đôi sớm hơn ⇒
    /// khung màu trải thưa hơn ở buổi dài. Đúng chủ đích: buổi dài luôn đi đường máy trạm.
    var wholeHomePreset: Preset {
        Preset(maxVertices: Self.deviceVertexCap, keyframeWidth: 640, maxKeyframes: 60, keyframeIntervalSec: 0.4)
    }

    /// Mesh vertex cap by the phone's RAM (owner OK 03/11; was 2M on every phone). Measured on
    /// #LS-MW0HFEWGL (iPhone 12 Pro, 6 GB, 2.79.2; scan-report MB): 2.0M vertices = 1,598 MB at Save,
    /// iOS limit ~4,095 MB (increased-memory-limit entitlement), ~600 MB more per million vertices
    /// ⇒ 3M ≈ 2,200 MB on 6 GB (12–14 Pro), 4M ≈ 2,800 on 8 GB (15 / 16 Pro), 5M ≈ 3,400 on 12 GB+
    /// (17 Pro on). The 8 / 12 GB limits are estimates: `ColorMeshBuilder`'s low-memory valve backs
    /// them up. Also the overlay's mask budget (`MeshOverlayView.maskMaxVerts`). physicalMemory
    /// reads a little under the label, hence 7 / 10.5.
    static let deviceVertexCap: Int = {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1e9
        return gb < 7 ? 3_000_000 : gb < 10.5 ? 4_000_000 : 5_000_000
    }()

    /// Mức dùng cho mọi buổi quét. Giữ một hằng số duy nhất thay vì rải `.high` ở các call site.
    static let storageDefault: MeshQuality = .high
}
