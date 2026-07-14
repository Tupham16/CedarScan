import Foundation
import SwiftUI
import RoomPlan

@MainActor
final class ScanStore: ObservableObject {
    @Published private(set) var records: [ScanRecord] = []
    @Published private(set) var projects: [ScanProject] = []

    private let fileManager = FileManager.default

    private var documentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var rootURL: URL {
        documentsURL.appendingPathComponent("Scans", isDirectory: true)
    }

    private var projectsURL: URL {
        documentsURL.appendingPathComponent("projects.json")
    }

    init() {
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        loadProjects()
        reload()
    }

    // MARK: - Dự án (căn nhà / địa chỉ)

    private func loadProjects() {
        guard let data = try? Data(contentsOf: projectsURL),
              let loaded = try? JSONDecoder().decode([ScanProject].self, from: data) else {
            return
        }
        projects = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    private func persistProjects() {
        if let data = try? JSONEncoder().encode(projects) {
            try? data.write(to: projectsURL)
        }
    }

    @discardableResult
    func createProject(name: String) -> ScanProject? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let project = ScanProject(id: UUID(), name: trimmed, createdAt: Date())
        projects.insert(project, at: 0)
        persistProjects()
        return project
    }

    func renameProject(_ project: ScanProject, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].name = trimmed
        persistProjects()
    }

    /// Xoá dự án — các bản quét bên trong KHÔNG mất, chỉ trở về danh sách chưa phân loại.
    func deleteProject(_ project: ScanProject) {
        for record in records where record.projectId == project.id {
            update(record) { $0.projectId = nil }
        }
        projects.removeAll { $0.id == project.id }
        persistProjects()
    }

    func moveScan(_ record: ScanRecord, to project: ScanProject?) {
        update(record) { $0.projectId = project?.id }
    }

    func scans(in project: ScanProject) -> [ScanRecord] {
        records.filter { $0.projectId == project.id }
    }

    var looseScans: [ScanRecord] {
        records.filter { record in
            record.projectId == nil || !projects.contains(where: { $0.id == record.projectId })
        }
    }

    func project(with id: UUID?) -> ScanProject? {
        guard let id else { return nil }
        return projects.first(where: { $0.id == id })
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
        name: String? = nil,
        projectId: UUID? = nil,
        quality: ScanQualityReport? = nil
    ) async throws -> ScanRecord {
        let planModel = FloorPlanModel(rooms: rooms)
        var record = ScanRecord(
            id: UUID(),
            name: name?.isEmpty == false ? name! : Self.defaultName(),
            createdAt: Date(),
            roomCount: rooms.count,
            areaSqm: planModel.areaSquareMeters,
            projectId: projectId,
            qualityScore: quality?.score,
            qualityGrade: quality?.grade,
            qualityRescan: quality?.rescanRecommended
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
            let plyURL = folder.appendingPathComponent("colored-mesh.ply")
            try? fileManager.moveItem(at: coloredMeshURL, to: plyURL)

            // 6b. Gói màu để khách tự mở/chia sẻ — dựng nền vì nặng, hỏng cũng không chặn lưu:
            //   • GLB (glTF): Blender kéo vào là có màu ngay cả khi render.
            //   • OBJ+MTL (zip): màu theo đỉnh, hợp MeshLab/CloudCompare.
            if fileManager.fileExists(atPath: plyURL.path) {
                let zipURL = folder.appendingPathComponent("model-colored.zip")
                let glbURL = folder.appendingPathComponent("model-colored.glb")
                try? await Task.detached(priority: .utility) {
                    try? ColoredOBJExporter.makeOBJZip(fromPLY: plyURL, to: zipURL)
                    try GLBExporter.makeGLB(fromPLY: plyURL, to: glbURL)
                }.value
            }
        }

        // 7. Báo cáo chất lượng quét — gửi kèm khi upload để đội vẽ biết scan tin được đến đâu
        if let quality, let data = try? JSONEncoder().encode(quality) {
            try? data.write(to: folder.appendingPathComponent("quality.json"))
        }

        try writeMeta(record)
        records.insert(record, at: 0)
        return record
    }

    /// Lưu bản quét CHẾ ĐỘ MESH 3D (không RoomPlan): model.obj màu (+mtl) + video —
    /// PLY chỉ là file trung gian, chuyển sang OBJ xong là xóa (lỗi chuyển thì giữ làm phao).
    /// videoURL/meshURL đều có thể nil (recorder/builder có thể fail lặng lẽ) — nhưng cả hai
    /// cùng nil thì throw: không ghi record rỗng (upload về sau sẽ từ chối nó).
    func saveMeshScan(
        videoURL: URL?,
        meshURL: URL?,
        name: String?,
        projectId: UUID? = nil,
        quality: MeshQuality
    ) async throws -> ScanRecord {
        let hasVideo = videoURL.map { fileManager.fileExists(atPath: $0.path) } ?? false
        let hasMesh = meshURL.map { fileManager.fileExists(atPath: $0.path) } ?? false
        guard hasVideo || hasMesh else {
            throw NSError(domain: "CedarScan", code: 1, userInfo: [
                NSLocalizedDescriptionKey: L.t(
                    "Nothing was captured — no 3D mesh and no video.",
                    "Chưa thu được dữ liệu — không có mesh 3D lẫn video."
                ),
            ])
        }

        let record = ScanRecord(
            id: UUID(),
            name: name?.isEmpty == false ? name! : Self.defaultName(),
            createdAt: Date(),
            roomCount: 0,
            areaSqm: nil,
            projectId: projectId,
            captureType: "mesh",
            // Không có mesh (chỉ cứu được video) thì đừng gắn nhãn tier — dòng danh sách
            // sẽ không quảng cáo "Mesh 3D (Nét)" cho một bản chỉ có video.
            meshQuality: hasMesh ? quality.rawValue : nil
        )
        let folder = folderURL(for: record)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        // 1. Video walkthrough (nếu quay được)
        if hasVideo, let videoURL {
            try? fileManager.moveItem(
                at: videoURL,
                to: folder.appendingPathComponent("scan-video.mp4")
            )
        }

        // 2. Mô hình 3D: CHỈ giữ OBJ màu (+MTL nhỏ) theo yêu cầu vận hành — không giữ
        //    PLY/GLB. PLY chỉ là file trung gian từ builder → chuyển sang OBJ rồi XÓA.
        //    Chuyển đổi lỗi thì giữ PLY lại (colored-mesh.ply) — không bao giờ mất dữ liệu 3D
        //    (menu chia sẻ + uploader đều xử lý được PLY).
        if hasMesh, let meshURL {
            let objURL = folder.appendingPathComponent("model.obj")
            let mtlURL = folder.appendingPathComponent("model.mtl")
            // .userInitiated: người dùng đang đứng chờ trên overlay "Đang dựng mô hình 3D…"
            // (.utility đẩy sang efficiency core, nhà lớn chờ lâu gấp đôi vô ích).
            let converted = await Task.detached(priority: .userInitiated) { () -> Bool in
                do {
                    try ColoredOBJExporter.makeOBJFiles(fromPLY: meshURL, objURL: objURL, mtlURL: mtlURL)
                    return true
                } catch {
                    return false
                }
            }.value
            if converted {
                try? fileManager.removeItem(at: meshURL)
            } else {
                try? fileManager.moveItem(
                    at: meshURL,
                    to: folder.appendingPathComponent("colored-mesh.ply")
                )
            }
        }

        try writeMeta(record)
        records.insert(record, at: 0)
        return record
    }

    /// Lưu bản quét CHỈ CÓ VIDEO (máy không LiDAR): video khảo sát để đội vẽ từ video.
    func saveVideoScan(videoURL: URL, name: String?, projectId: UUID? = nil) throws -> ScanRecord {
        var record = ScanRecord(
            id: UUID(),
            name: name?.isEmpty == false ? name! : Self.defaultName(),
            createdAt: Date(),
            roomCount: 0,
            areaSqm: 0,
            projectId: projectId,
            captureType: "video"
        )
        let folder = folderURL(for: record)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try fileManager.moveItem(at: videoURL, to: folder.appendingPathComponent("scan-video.mp4"))
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
