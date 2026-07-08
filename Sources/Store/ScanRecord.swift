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
    var captureType: String? // nil/"lidar" = quét LiDAR | "video" = quay video (máy không LiDAR)
    var qualityScore: Int? // điểm chất lượng quét 0-100 (báo cáo đầy đủ trong quality.json)
    var qualityGrade: String? // A/B/C/D
    var qualityRescan: Bool? // true = nên quét lại

    var isVideoOnly: Bool { captureType == "video" }
}

/// Dự án = một căn nhà/địa chỉ (vd "1600 College Avenue") chứa nhiều bản quét (các tầng, nhà phụ...).
struct ScanProject: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
}
