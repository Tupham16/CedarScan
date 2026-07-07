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
}
