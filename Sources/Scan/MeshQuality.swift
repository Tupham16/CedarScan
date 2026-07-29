import Foundation

/// Mức độ nét của mesh màu (số đỉnh tối đa + độ phủ khung màu).
/// Chế độ RoomPlan dùng preset mặc định viết thẳng trong ColorMeshBuilder.init (mesh chỉ là
/// tư liệu nội bộ);
/// chế độ quét Mesh 3D cho người dùng chọn để so cả hai mức trên máy thật.
///
/// 🔴 HAI MỨC CHỈ KHÁC NHAU Ở **MÀU**, KHÔNG KHÁC MỘT MILIMET HÌNH HỌC. Mật độ lưới do ARKit
/// quyết định, việc chia nhỏ tam giác lúc xuất (`refineLargeTriangles`) chạy Y HỆT nhau ở cả
/// hai mức, nên số đỉnh, số mặt và dung lượng file GIỐNG NHAU. Thứ duy nhất mức trên mua thêm
/// là ĐỘ PHỦ KHUNG MÀU (`maxKeyframes`) — xem `wholeHomePreset`.
///
/// Vì sao KHÔNG mua độ nét bằng cách chia nhỏ tam giác mạnh hơn (đã đo và loại 2026-07-29):
/// trên lưới bề mặt, khoảng cách giữa hai đỉnh tỉ lệ với V^(-1/2), trong khi dung lượng file,
/// thời gian lưu, thời gian upload 4G và thời gian đội vẽ mở file đều tỉ lệ THUẬN với V. Hạ
/// `refineEdgeThreshold` 0.07 → 0.06 tốn +25% cho cả bốn khoản đó để đổi lấy 11% mịn hơn —
/// mắt không thấy. Muốn nét gấp đôi phải trả gấp BỐN lần mọi thứ, tức phá đúng hai ràng buộc
/// "nhẹ" và "khách không phải chờ lâu". Đường đúng để nét thật sự là TEXTURE (dán ảnh lên bề
/// mặt) — dự án riêng, không nằm trong khuôn màu-theo-đỉnh này.
///
/// Mức "Nhẹ" ĐÃ BỎ (2026-07-19) và mức "Vừa" ĐÃ BỎ (2026-07-29): đo ra chúng không nhẹ hơn
/// thật — hình học và dung lượng file giống hệt các mức kia (ARKit cố định mật độ lưới), chỉ
/// màu xấu hơn. Giữ lại chỉ tổ làm người dùng chọn nhầm rồi nhận bản quét màu kém mà chẳng
/// tiết kiệm được gì.
enum MeshQuality: String, CaseIterable, Identifiable {
    case high
    /// 🔴 rawValue PHẢI là "ultra". TUYỆT ĐỐI KHÔNG tái dùng chuỗi "medium" của mức Vừa đã bỏ:
    /// `@AppStorage` không bao giờ ghi mặc định ngược vào UserDefaults (xem `storageDefault`),
    /// nên mọi máy từng chọn Vừa vẫn còn nguyên chuỗi đó trên đĩa — tái dùng là cả nhóm máy ấy
    /// tự nhảy sang mức nặng nhất mà không ai bấm gì và không ai biết.
    case ultra

    var id: Self { self }

    struct Preset {
        let maxVertices: Int
        let keyframeWidth: Int
        let maxKeyframes: Int
        let keyframeIntervalSec: Double
    }

    /// Preset của luồng RoomPlan CŨ. Gần như là code chết: người đọc DUY NHẤT là
    /// `wholeHomePreset` bên dưới (`let base = preset`), và nó ghi đè `maxVertices` +
    /// `maxKeyframes` bằng giá trị riêng — chỉ `keyframeWidth` và `keyframeIntervalSec` đi
    /// tiếp xuống máy quét. Hai nhánh để y hệt nhau cho khỏi phải nghĩ.
    var preset: Preset {
        switch self {
        case .high:
            return Preset(maxVertices: 450_000, keyframeWidth: 640, maxKeyframes: 64, keyframeIntervalSec: 0.4)
        case .ultra:
            return Preset(maxVertices: 450_000, keyframeWidth: 640, maxKeyframes: 64, keyframeIntervalSec: 0.4)
        }
    }

    /// Preset cho CHẾ ĐỘ QUÉT MESH 3D (nguyên căn). Khác `preset` (dành cho luồng RoomPlan,
    /// nơi file màu chỉ là tư liệu phụ cần nhẹ): mật độ hình học do ARKit quyết định, trần
    /// đỉnh KHÔNG phải núm chỉnh độ nét mà chỉ là chỗ CẮT CỤT — nguyên căn phải lọt trọn.
    /// Nên cả hai mức dùng chung van an toàn RAM 2M đỉnh (~110MB mảng mesh; nhà 2 tầng thực tế
    /// ~0.5–1.5M) và chỉ khác nhau về ĐỘ PHỦ MÀU.
    var wholeHomePreset: Preset {
        let base = preset
        // 🔴 VÌ SAO ĐÚNG 320 CHỨ KHÔNG PHẢI 192/224/256 (tính lại 2026-07-29):
        // khi kho khung đầy, `maybeCaptureColorFrame` bỏ khung XEN KẼ rồi NHÂN ĐÔI nhịp chụp.
        // Nhịp chụp thật là 0,667s (cổng 0.4s nhưng tick CADisplayLink của builder chạy 3Hz
        // nên chỉ qua được ở bội số 1/3s), nên mốc giãn nhịp lần thứ n rơi vào t = c(n)·K với
        // c = {0,667 · 1,167 · 2,0 · 3,667 · 7,0 · 13,5}. Vì mốc tỉ lệ THUẦN với K, chỉ
        // K = 2×160 mới dời TRỌN một nấc ở MỌI thời lượng quét:
        //   8 phút  3,33s → 1,67s ·  10 phút 6,67s → 1,67s · 15 phút 6,67s → 3,33s
        //   20 phút 13,0s → 6,67s ·  25 phút 13,0s → 6,67s · 30 phút 13,0s → 6,67s
        // K=224 HOÀ với 160 ở 3/6 mốc; K=256 hoà đúng ở mốc 30 phút — tức đúng buổi quét mà
        // bệnh đói màu nặng nhất. Quy ra quãng đường người quét đi giữa hai tấm màu
        // (0,3–0,5 m/s): buổi 25–30 phút từ 3,9–6,5m xuống còn 2,0–3,3m.
        //
        // Giá phải trả của .ultra là RAM LÚC QUÉT: mỗi khung giữ RGB 640×480 (0,92MB) +
        // depth 256×192 (0,19MB) ≈ 1,12MB → 160 khung ≈ 179MB, 320 khung ≈ 358MB, giữ suốt
        // buổi. KHÔNG tốn thêm một byte FILE nào (khung màu chỉ sống trong lúc dựng mesh).
        let keyframes: Int
        switch self {
        case .high: keyframes = 160
        case .ultra: keyframes = 320
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
        case .high: return L.t("Fine", "Nét")
        case .ultra: return L.t("Ultra", "Siêu nét")
        }
    }

    /// Caption đổi theo lựa chọn.
    ///
    /// ĐÃ BỎ chữ "máy nóng hơn" ở mức Nét (2026-07-19) vì nó SAI và đã khiến chính chủ app quy
    /// kết nhầm nguyên nhân: các mức dùng CHUNG keyframeWidth 640 và CHUNG keyframeIntervalSec
    /// 0.4, chỉ khác maxKeyframes tức khác NHỊP chụp qua cơ chế halving. Nhiệt lúc quét đến từ
    /// ARKit sceneReconstruction + overlay lưới + video H.264 + poll depth 12Hz, toàn thứ
    /// KHÔNG phụ thuộc mức nét.
    ///
    /// 🔴 CAPTION CỦA .ultra TUYỆT ĐỐI KHÔNG ĐƯỢC HỨA "nét/sắc/chi tiết hơn" — hình học không
    /// đổi một milimet (xem chú ở đầu file). Nó chỉ được nói về MÀU. Repo đã trả giá một lần
    /// vì caption nói sai; đừng trả giá lần hai.
    var caption: String {
        switch self {
        case .high:
            return L.t("Recommended — balanced colour and save time",
                       "Khuyên dùng — cân bằng giữa màu và thời gian lưu")
        case .ultra:
            return L.t("2–4× the colour coverage on longer scans — same file size, a bit longer to save",
                       "Màu dày gấp 2–4 lần ở buổi quét dài — cùng dung lượng file, lưu lâu hơn một chút")
        }
    }

    /// Dòng chung đặt dưới picker. Gỡ hiểu lầm phổ biến nhất ("mức thấp = file nhẹ"): mật độ
    /// lưới do ARKit quyết định, cả hai mức chung trần 2M đỉnh, màu ghi định dạng cố định
    /// %.3f nên mỗi đỉnh tốn đúng bằng nhau byte → file ra gần như bằng nhau.
    ///
    /// 🔴 CÂU NÀY VẪN ĐÚNG TỪNG CHỮ sau đợt 2026-07-29 và KHÔNG được "sửa cho đồng bộ": mức
    /// .ultra chỉ tăng số khung màu, không đụng subdivide, nên số đỉnh/số mặt/byte file giống
    /// hệt mức .high. Đó chính là phần thưởng của việc không mua độ nét bằng đỉnh.
    static var sharedNote: String {
        L.t("Both levels give the same geometry and the same file size.",
            "Cả hai mức cho hình học và dung lượng file như nhau.")
    }

    /// Mặc định của @AppStorage("meshQuality"). Khoá này được khai báo ở BỐN nơi: HomeView,
    /// ProjectView, ScanAddressView, ScanQualityPickerView — @AppStorage không bao giờ ghi mặc
    /// định ngược vào UserDefaults, nên bốn chỗ lệch nhau là bốn màn hình đọc ra giá trị khác
    /// nhau cho cùng một khoá. Giữ ở một nguồn duy nhất để không thể lệch.
    ///
    /// GIỮ .high làm mặc định: đổi sang .ultra là âm thầm đẩy MỌI máy chưa từng chạm picker
    /// sang mức tốn thêm ~179MB RAM suốt buổi quét — và đúng chỗ nhóm máy đang lưu "medium"
    /// rơi về. Muốn đổi thì phải là quyết định RIÊNG, sau khi đã quét thử 30 phút trên máy 6GB.
    static let storageDefault: MeshQuality = .high

    /// Nhãn cho rawValue ĐỌC TỪ ĐĨA (meta.json của bản quét đã lưu), khác với `label` của một
    /// case đang sống. Bản quét lưu trước 2026-07-19 mang rawValue "light", trước 2026-07-29
    /// mang "medium"; hai case đó đã bỏ nên `MeshQuality(rawValue:)` trả nil và nhãn mức nét
    /// lặng lẽ biến mất khỏi danh sách. Ánh xạ lịch sử ở đây để bản quét cũ vẫn hiện đúng mức
    /// nó đã được quét.
    ///
    /// 🔴 AI BỎ THÊM MỘT CASE NỮA THÌ THÊM DÒNG VÀO ĐÂY TRƯỚC, RỒI MỚI XOÁ CASE. Hai chỗ đọc
    /// (`HomeView.ScanRow`, `ScanDetailView.meshTitle`) đều `guard let … else { return base }`
    /// nên trả nil là nhãn biến mất KHÔNG một tiếng động. Sự cố "light" đã xảy ra đúng vậy.
    static func storedLabel(_ raw: String) -> String? {
        if raw == "light" { return L.t("Light", "Nhẹ") }
        if raw == "medium" { return L.t("Medium", "Vừa") }
        return MeshQuality(rawValue: raw)?.label
    }
}
