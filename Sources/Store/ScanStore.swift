import Foundation
import RoomPlan

@MainActor
final class ScanStore: ObservableObject {
    @Published private(set) var records: [ScanRecord] = []

    private let fileManager = FileManager.default

    private var rootURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scans", isDirectory: true)
    }

    init() {
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let folders = (try? fileManager.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil)) ?? []
        records = folders
            .compactMap { folder -> ScanRecord? in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")) else {
                    return nil
                }
                return try? JSONDecoder().decode(ScanRecord.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func folderURL(for record: ScanRecord) -> URL {
        rootURL.appendingPathComponent(record.id.uuidString, isDirectory: true)
    }

    func usdzURL(for record: ScanRecord) -> URL {
        folderURL(for: record).appendingPathComponent("model.usdz")
    }

    func save(rooms: [CapturedRoom]) async throws -> ScanRecord {
        let record = ScanRecord(
            id: UUID(),
            name: Self.defaultName(),
            createdAt: Date(),
            roomCount: rooms.count
        )
        let folder = folderURL(for: record)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let usdzURL = folder.appendingPathComponent("model.usdz")
        if rooms.count > 1 {
            let builder = StructureBuilder(options: [])
            let structure = try await builder.capturedStructure(from: rooms)
            try structure.export(to: usdzURL)
        } else if let room = rooms.first {
            try room.export(to: usdzURL)
        }

        try JSONEncoder().encode(rooms)
            .write(to: folder.appendingPathComponent("rooms.json"))
        try JSONEncoder().encode(record)
            .write(to: folder.appendingPathComponent("meta.json"))

        records.insert(record, at: 0)
        return record
    }

    func loadRooms(for record: ScanRecord) throws -> [CapturedRoom] {
        let data = try Data(contentsOf: folderURL(for: record).appendingPathComponent("rooms.json"))
        return try JSONDecoder().decode([CapturedRoom].self, from: data)
    }

    func delete(_ record: ScanRecord) {
        try? fileManager.removeItem(at: folderURL(for: record))
        records.removeAll { $0.id == record.id }
    }

    func rename(_ record: ScanRecord, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = records.firstIndex(where: { $0.id == record.id }) else {
            return
        }
        records[index].name = trimmed
        let updated = records[index]
        try? JSONEncoder().encode(updated)
            .write(to: folderURL(for: updated).appendingPathComponent("meta.json"))
    }

    private static func defaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        return "Quét \(formatter.string(from: Date()))"
    }
}
