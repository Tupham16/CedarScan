import Foundation

struct ScanRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var roomCount: Int

    // Các trường thêm sau (optional để đọc được meta.json cũ)
    var areaSqm: Double?
    var cloudScanId: String? // đã gửi lên server Cedar247
    var cloudOrderNumber: String? // đã đặt xử lý (số đơn, vd "#LS-ABC123")
    var projectId: UUID? // thuộc dự án/căn nhà nào (nil = chưa vào dự án)
    var meshQuality: String? // cấu hình quét mesh (MeshQuality.rawValue); không màn nào hiện
    var qualityScore: Int? // điểm chất lượng quét 0-100 (báo cáo đầy đủ trong quality.json)
    var qualityGrade: String? // A/B/C/D
    var qualityRescan: Bool? // true = nên quét lại
}

// 🔴 `captureType` + `isVideoOnly` + `isMeshOnly` ĐÃ XOÁ 11/08 (bản 2.5) — chủ app chốt:
// *"Cái gì của RoomPlan thì xóa hết đi. App đang bản thử nghiệm chưa lên iOS nên xóa đi không lo
// khách còn bản cũ vì chỉ có tôi xài thôi."*
//
// Ba giá trị cũ: nil/"lidar" = RoomPlan · "video" = quay video khảo sát · "mesh" = quét Mesh 3D.
// Đường TẠO của hai loại đầu chết từ lâu (`saveVideoScan` xoá 2026-07-19, `save(rooms:)` +
// RoomPlan xoá 2026-07-20); nay bóc nốt đường XEM nên trường này không còn ai đọc.
//
// ⚠ HỆ QUẢ ĐÃ BÁO CHỦ APP, ✗ phải lỗi: bản quét CŨ trên máy (meta.json có `captureType`
// nil/"lidar"/"video") **vẫn đọc được** — `Codable` bỏ qua khoá thừa, nên chúng vẫn hiện trong
// danh sách và vẫn xoá/đổi tên được. Cái mất là màn XEM riêng của chúng: nay mọi bản quét đều đi
// đường mesh (video + mô hình 3D). Bản cũ không có `mesh-preview.bin`/`model-colored.zip` thì màn
// chi tiết chỉ còn video + dòng "chưa thu được mô hình 3D". File trên đĩa KHÔNG bị đụng tới.
//
// ⚠ `captureType` VẪN GỬI LÊN SERVER, cắm cứng `"mesh"` ở `ScanUploader` — đó là trường của HỢP
// ĐỒNG app↔server (`APIClient.createScan`), ✗ gỡ ở đây mà không đi đường "SERVER TRƯỚC".

/// Dự án = một căn nhà/địa chỉ (vd "1600 College Avenue") chứa nhiều bản quét (các tầng, nhà phụ...).
struct ScanProject: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
}
