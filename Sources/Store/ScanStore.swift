import Foundation
import SwiftUI
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

    func save(
        rooms: [CapturedRoom],
        videoURL: URL?,
        coloredMeshURL: URL?,
        name: String? = nil
    ) async throws -> ScanRecord {
        let planModel = FloorPlanModel(rooms: rooms)
        var record = ScanRecord(
            id: UUID(),
            name: name?.isEmpty == false ? name! : Self.defaultName(),
            createdAt: Date(),
            roomCount: rooms.count,
            areaSqm: planModel.areaSquareMeters
        )
        let folder = folderURL(for: record)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        // 1. Mô hình 3D USDZ
        let usdzURL = folder.appendingPathComponent("model.usdz")
        if rooms.count > 1 {
            let builder = StructureBuilder(options: [])
            let structure = try await builder.capturedStructure(from: rooms)
            try structure.export(to: usdzURL)
        } else if let room = rooms.first {
            try room.export(to: usdzURL)
        }

        // 2. OBJ (+ MTL) từ USDZ — hỏng cũng không chặn việc lưu
        let objURL = folder.appendingPathComponent("model.obj")
        try? OBJExporter.export(usdzURL: usdzURL, to: objURL)

        // 3. Dữ liệu RoomPlan gốc
        try JSONEncoder().encode(rooms)
            .write(to: folder.appendingPathComponent("rooms.json"))

        // 4. Ảnh mặt bằng PNG
        if !planModel.isEmpty {
            let exportView = FloorPlanExportView(model: planModel, title: record.name)
                .frame(width: 1400, height: 1600)
            let renderer = ImageRenderer(content: exportView)
            renderer.scale = 2
            if let image = renderer.uiImage, let data = image.pngData() {
                try? data.write(to: folder.appendingPathComponent("floorplan.png"))
            }
        }

        // 5. Video quá trình quét (nếu có)
        if let videoURL, fileManager.fileExists(atPath: videoURL.path) {
            try? fileManager.moveItem(
                at: videoURL,
                to: folder.appendingPathComponent("scan-video.mp4")
            )
        }

        // 6. Mô hình 3D có màu (.ply) — nguyên liệu nội bộ (nếu dựng được)
        if let coloredMeshURL, fileManager.fileExists(atPath: coloredMeshURL.path) {
            try? fileManager.moveItem(
                at: coloredMeshURL,
                to: folder.appendingPathComponent("colored-mesh.ply")
            )
        }

        try writeMeta(record)
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
        guard !trimmed.isEmpty else { return }
        update(record) { $0.name = trimmed }
    }

    func setCloudScanId(_ record: ScanRecord, cloudScanId: String) {
        update(record) { $0.cloudScanId = cloudScanId }
    }

    func setOrderNumber(_ record: ScanRecord, orderNumber: String) {
        update(record) { $0.cloudOrderNumber = orderNumber }
    }

    private func update(_ record: ScanRecord, _ mutate: (inout ScanRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        mutate(&records[index])
        try? writeMeta(records[index])
    }

    private func writeMeta(_ record: ScanRecord) throws {
        try JSONEncoder().encode(record)
            .write(to: folderURL(for: record).appendingPathComponent("meta.json"))
    }

    private static func defaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        return "Scan \(formatter.string(from: Date()))"
    }
}
