import Foundation
import SwiftUI

@MainActor
final class ScanStore: ObservableObject {
    @Published private(set) var records: [ScanRecord] = []
    @Published private(set) var projects: [ScanProject] = []

    /// Số việc đang "đụng vào" dữ liệu bản quét: phiên quét đang mở, hoặc đang lưu.
    /// `purgeDelivered` phải đứng NGOÀI cửa sổ này.
    ///
    /// ĐẾM chứ không dùng Bool: hai việc chồng nhau (đang lưu bản này thì mở phiên quét bản
    /// khác) thì lần kết thúc trước sẽ tắt khoá của lần sau.
    ///
    /// Vì sao phải bao CẢ PHIÊN QUÉT chứ không chỉ lúc lưu: `ProjectView` là view SỞ HỮU
    /// `fullScreenCover` quét. Nếu dọn xoá hết bản quét của dự án trong lúc khách đang đi bộ
    /// quét, `ProjectView` bị dismiss → cover bị tháo theo → phiên quét chết giữa chừng,
    /// closure lưu KHÔNG BAO GIỜ chạy, mất trắng 10–30 phút đi bộ. Cờ chỉ-khi-lưu không cứu
    /// được vì suốt lúc đi bộ thì chưa lưu gì cả.
    private var busyCount = 0
    private var busySince: Date?

    /// VAN AN TOÀN THEO THỜI GIAN. `max(0,...)` chỉ chặn hướng ÂM, mà hướng hỏng thật là KẸT
    /// DƯƠNG: `.onDisappear` KHÔNG được SwiftUI bảo đảm gọi — iPad đa cửa sổ (project.yml khai
    /// `TARGETED_DEVICE_FAMILY: "1,2"`) có thể thu hồi cả scene mà không chạy nó, nhất là khi
    /// quét mesh đang ngốn hàng trăm MB. Kẹt một nhịp là việc dọn CHẾT VĨNH VIỄN, im lặng,
    /// không log không dấu vết — khách chỉ thấy máy đầy dần.
    ///
    /// Cửa sổ này bao CẢ màn preview sau khi quét (khách ngồi xem lại video), nên nó có thể dài
    /// hơn "quét + lưu" nhiều — bỏ máy trong túi lúc preview đang mở là vượt một giờ. Chấp nhận:
    /// bản ghi mới lúc đó đã nằm trong `records` nên việc dọn không đụng được dự án của nó.
    /// Ngưỡng này chỉ tha cho khoá đã MỤC RỮA — biến hỏng-vĩnh-viễn thành hỏng-tối-đa-một-giờ.
    private static let busyStaleAfter: TimeInterval = 3600

    var isBusy: Bool {
        guard busyCount > 0 else { return false }
        guard let since = busySince else { return true }
        return Date().timeIntervalSince(since) < Self.busyStaleAfter
    }

    /// Gọi khi mở phiên quét / bắt đầu lưu. PHẢI cặp đôi với `endBusy()`.
    func beginBusy() {
        if busyCount == 0 { busySince = Date() }
        busyCount += 1
    }

    func endBusy() {
        busyCount = max(0, busyCount - 1)
        if busyCount == 0 { busySince = nil }
    }

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

    /// Mô hình USDZ — CHỈ bản quét RoomPlan CŨ mới có. Luồng mesh không sinh USDZ bao giờ.
    /// Giữ lại để `ScanDetailView` còn mở được bản cũ trên máy khách (xem chú thích ở
    /// `delete(_:)` bên dưới); người gọi PHẢI tự `fileExists` trước khi dùng.
    func usdzURL(for record: ScanRecord) -> URL {
        folderURL(for: record).appendingPathComponent("model.usdz")
    }

    /// Lưu bản quét CHẾ ĐỘ MESH 3D (không RoomPlan): model.obj màu (+mtl) + video —
    /// PLY chỉ là file trung gian, chuyển sang OBJ xong là xóa (lỗi chuyển thì giữ làm phao).
    /// videoURL/meshURL đều có thể nil (recorder/builder có thể fail lặng lẽ) — nhưng cả hai
    /// cùng nil thì throw: không ghi record rỗng (upload về sau sẽ từ chối nó).
    func saveMeshScan(
        videoURL: URL?,
        meshURL: URL?,
        trackURL: URL? = nil,
        name: String?,
        projectId: UUID? = nil,
        quality: MeshQuality
    ) async throws -> ScanRecord {
        // Khoá việc dọn-sau-khi-giao suốt quá trình lưu. Bản ghi chỉ được `records.insert` ở
        // CUỐI hàm (dòng ~297), sau khi await nén zip/GLB — việc mất hàng chục giây tới vài
        // phút với nhà nguyên căn. Trong cửa sổ đó bản quét mới CHƯA có trong `records`, nên
        // nếu dọn chạy xen vào: dự án của nó trông như đã hết bản quét → bị xoá → bản quét vừa
        // lưu xong trỏ vào dự án chết và thành mồ côi. Khoá cả hàm dọn cho chắc, vì xoá thư mục
        // trong lúc đang ghi file cũng là chuyện không nên.
        beginBusy()
        defer { endBusy() }

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

        // 1b. Camera track (vị trí + hướng camera đồng bộ PTS video) — nguyên liệu minimap
        //     kiểu CubiCasa: tool FLOORPLANCUT của đội vẽ đọc file này để vẽ mũi tên chạy
        //     trên ảnh mặt bằng khi phát video. Giữ 1 bản trong thư mục bản quét (viewer
        //     trong app sau này) + đóng kèm vào zip OBJ bên dưới (tới tay đội vẽ, không
        //     cần đổi gì phía server). Hỏng cũng không chặn lưu.
        //     GIỚI HẠN CÓ CHỦ ĐÍCH: track lên server CHỈ qua zip OBJ — nếu nén zip lỗi
        //     (rơi về PLY phao) hay bản chỉ-có-video thì track vẫn nằm đây nhưng KHÔNG
        //     được upload (ScanUploader không có kind riêng; muốn thêm phải đổi server
        //     TRƯỚC app SAU). Mesh mất thì minimap cũng vô nghĩa nên chấp nhận.
        var savedTrackURL: URL?
        if let trackURL, fileManager.fileExists(atPath: trackURL.path) {
            let dest = folder.appendingPathComponent("camera-track.json")
            if (try? fileManager.moveItem(at: trackURL, to: dest)) != nil {
                savedTrackURL = dest
            }
        }

        // 2. Mô hình 3D: giữ OBJ màu ĐÃ NÉN (obj+mtl+glb trong model-colored.zip). OBJ là text
        //    nén ~5 lần → upload nhẹ hơn nhiều bản obj thô (~200MB → ~40MB). GLB kèm trong zip
        //    để đội vẽ kéo vào Blender là CÓ MÀU ngay (OBJ màu-đỉnh Blender render trắng).
        //    PLY chỉ là file trung gian từ builder → nén xong XÓA. Nén lỗi thì dọn zip cụt và
        //    GIỮ PLY lại làm phao (menu chia sẻ + uploader đều xử lý được PLY) — không bao giờ
        //    mất dữ liệu 3D.
        if hasMesh, let meshURL {
            let zipURL = folder.appendingPathComponent("model-colored.zip")
            // .userInitiated: người dùng đang đứng chờ trên overlay "Đang dựng mô hình 3D…"
            // (.utility đẩy sang efficiency core, nhà lớn chờ lâu gấp đôi vô ích).
            let extraFiles = savedTrackURL.map { [$0] } ?? []
            let converted = await Task.detached(priority: .userInitiated) { () -> Bool in
                do {
                    try ColoredOBJExporter.makeOBJZip(
                        fromPLY: meshURL, to: zipURL, includeGLB: true, extraFiles: extraFiles
                    )
                    return true
                } catch {
                    return false
                }
            }.value
            if converted {
                try? fileManager.removeItem(at: meshURL)
            } else {
                try? fileManager.removeItem(at: zipURL) // dọn zip ghi dở
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

    // `saveVideoScan` ĐÃ XOÁ 2026-07-19 cùng luồng quay video khảo sát (chủ app chốt "yêu cầu
    // máy phải có lidar"). `save(rooms:)` + `loadRooms` ĐÃ XOÁ 2026-07-20 cùng RoomPlan.
    // KHÔNG xoá theo, và đây là điểm dễ sai nhất của cả hai lần gỡ: `ScanRecord.captureType`
    // (nil/"lidar"/"video") + `isVideoOnly` + `usdzURL` + các nhánh xem bản cũ trong
    // ScanDetailView + toàn bộ `fileKinds` của ScanUploader. Người dùng đang có bản quét CŨ
    // trên máy, phải xem/chia sẻ/đặt hàng/xoá được. **Gỡ đường TẠO khác hẳn gỡ đường XEM.**

    func delete(_ record: ScanRecord) {
        try? fileManager.removeItem(at: folderURL(for: record))
        records.removeAll { $0.id == record.id }
    }

    /// Dọn hẳn khỏi máy những bản quét thuộc đơn ĐÃ GIAO (chủ app chốt 2026-07-19: "máy khách
    /// chỉ lưu những dự án chưa đặt hàng"). Dữ liệu vẫn nằm trên R2 của chủ app; khách cần sửa
    /// thì chủ app tra đơn trên web. Mỗi bản mesh nặng 40–200MB nên đây là thứ giữ máy khách nhẹ.
    ///
    /// AN TOÀN — người gọi PHẢI chỉ truyền vào scanId của đơn mà khách ĐÃ CẦM ĐƯỢC thành phẩm
    /// (xem `OrderDTO.isDeliveredToCustomer`). Hàm này không tự kiểm tra điều đó.
    ///
    /// Khớp bằng `cloudScanId` — id do SERVER cấp, không phải `record.id` cục bộ. Hai không gian
    /// id khác nhau; lẫn lộn là xoá nhầm bản quét chưa giao.
    /// - Returns: số bản quét đã xoá (0 = không có gì để dọn).
    @discardableResult
    func purgeDelivered(scanIds: Set<String>) -> Int {
        guard !scanIds.isEmpty else { return 0 }
        // Đang quét hoặc đang lưu → hoãn tới lần sau (mỗi lần app vào foreground lại thử).
        // Bản quét đang lưu chưa vào `records` nên dự án của nó trông như rỗng.
        guard !isBusy else { return 0 }
        let doomed = records.filter { record in
            guard let cloudId = record.cloudScanId else { return false }
            return scanIds.contains(cloudId)
        }
        guard !doomed.isEmpty else { return 0 }

        // Nhớ TRƯỚC khi xoá: dự án nào vừa mất bản quét. Chỉ những dự án đó mới được xét dọn —
        // dự án rỗng do người dùng VỪA TẠO mà chưa quét thì phải giữ nguyên.
        let touchedProjects = Set(doomed.compactMap(\.projectId))

        // CHỈ gỡ khỏi `records` những bản mà thư mục ĐÃ BIẾN MẤT THẬT. `try?` nuốt lỗi (file
        // đang mở, quyền, đĩa đầy) — gỡ vô điều kiện thì dòng biến khỏi danh sách trong khi
        // 40–200MB vẫn nằm trên đĩa, và không còn UI nào xoá được nữa (ScanRow là lối vào duy
        // nhất tới swipe-xoá). Giữ lại thì lần mở app sau `reload()` đọc lại meta.json và thử lại.
        var removed: [ScanRecord] = []
        for record in doomed {
            let folder = folderURL(for: record)
            try? fileManager.removeItem(at: folder)
            if !fileManager.fileExists(atPath: folder.path) {
                removed.append(record)
            }
        }
        guard !removed.isEmpty else { return 0 }
        let removedIds = Set(removed.map(\.id))
        records.removeAll { removedIds.contains($0.id) }

        // Chỉ xét dự án mất bản quét THẬT — dùng `removed`, không dùng `doomed`.
        let touched = touchedProjects.intersection(removed.compactMap(\.projectId))
        let nowEmpty = projects.filter { project in
            touched.contains(project.id)
                && !records.contains { $0.projectId == project.id }
        }
        if !nowEmpty.isEmpty {
            let emptyIds = Set(nowEmpty.map(\.id))
            projects.removeAll { emptyIds.contains($0.id) }
            persistProjects()
        }
        return removed.count
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
