import Foundation

struct ScanRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var roomCount: Int
}
