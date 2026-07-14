import Foundation

/// Chuyển mô hình LiDAR CÓ MÀU (file .ply do ColorMeshBuilder xuất) sang OBJ + MTL —
/// dạng file rời (makeOBJFiles, chế độ quét Mesh) hoặc gói ZIP (makeOBJZip, luồng RoomPlan).
/// OBJ mang MÀU THEO ĐỈNH (v x y z r g b), mở được CÓ MÀU trong MeshLab, CloudCompare
/// và (bật tay) trong Blender.
///
/// LƯU Ý: màu đỉnh trong OBJ là phi tiêu chuẩn — Blender khi RENDER lấy màu từ vật liệu
/// nên OBJ+MTL không tự ra màu khi render. Muốn Blender ra màu ngay, dùng GLBExporter.
///
/// Chạy NỀN (nặng ~10–20MB với 120k đỉnh). Chỉ đọc/ghi file, không đụng UIKit.
enum ColoredOBJExporter {
    enum ExportError: Error { case zipFailed }

    private static let mtlText = """
    # CedarScan material — màu nằm ở từng đỉnh (vertex colors), không dùng texture map.
    newmtl vertexcolor
    Ka 1.000 1.000 1.000
    Kd 1.000 1.000 1.000
    Ks 0.000 0.000 0.000
    d 1.0
    illum 1

    """

    /// Ghi THẲNG model.obj + model.mtl (không nén) từ PLY màu — dùng cho chế độ quét MESH:
    /// thư mục bản quét chỉ giữ OBJ + video (yêu cầu vận hành), uploader gửi 2 file này
    /// theo kind "obj"/"mtl" có sẵn trên server.
    static func makeOBJFiles(fromPLY plyURL: URL, objURL: URL, mtlURL: URL) throws {
        let mesh = try ColoredMeshPLY.parse(plyURL)
        do {
            // MTL (bé) ghi TRƯỚC — file rẻ không được phép làm hỏng file đắt đã ghi xong.
            try Data(mtlText.utf8).write(to: mtlURL)
            try writeOBJ(mesh, to: objURL)
        } catch {
            // Ghi dở giữa chừng (thường do ĐẦY Ổ — đúng lúc dễ xảy ra nhất vì OBJ ~200MB
            // ghi ngay sau video): phải dọn cả hai file CỤT, không thì menu chia sẻ +
            // uploader coi OBJ cụt là sản phẩm thật trong khi PLY phao nằm ngay cạnh.
            try? FileManager.default.removeItem(at: objURL)
            try? FileManager.default.removeItem(at: mtlURL)
            throw error
        }
    }

    /// Đọc PLY màu → ghi model.obj + model.mtl vào 1 thư mục tạm rồi nén thành .zip tại `zipURL`.
    static func makeOBJZip(fromPLY plyURL: URL, to zipURL: URL) throws {
        let mesh = try ColoredMeshPLY.parse(plyURL)

        // MARK: - Ghi 2 file vào thư mục tạm rồi nén
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("CedarScan-3D-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try writeOBJ(mesh, to: work.appendingPathComponent("model.obj"))
        try Data(mtlText.utf8).write(to: work.appendingPathComponent("model.mtl"))

        try zipDirectory(work, to: zipURL)
    }

    /// Ghi OBJ dạng STREAM (buffer ~1MB, màu theo đỉnh: v x y z r g b).
    /// Bản cũ gom hơn 1 triệu String rồi joined() — đỉnh RAM tạm ~200MB ở 450k đỉnh;
    /// stream giữ đỉnh ~20MB ở mọi mức nét và bỏ được cú khựng joined()+copy.
    private static func writeOBJ(_ mesh: ColoredMeshPLY.Mesh, to objURL: URL) throws {
        FileManager.default.createFile(atPath: objURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: objURL)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1_200_000)

        func flushIfNeeded(force: Bool = false) throws {
            if buffer.count >= 1_000_000 || (force && !buffer.isEmpty) {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        buffer.append(contentsOf: "# CedarScan colored LiDAR mesh\nmtllib model.mtl\no CedarScanMesh\nusemtl vertexcolor\n".utf8)
        for k in mesh.positions.indices {
            let p = mesh.positions[k]
            let c = mesh.colors[k]
            // Tách sẵn từng đối số thành let Double để biểu thức String(format:) nhẹ cho
            // type-checker (CI này từng timeout vì biểu thức phức tạp).
            let x = Double(p.x)
            let y = Double(p.y)
            let z = Double(p.z)
            let r = Double(c.r) / 255.0
            let g = Double(c.g) / 255.0
            let b = Double(c.b) / 255.0
            let line = String(format: "v %.4f %.4f %.4f %.3f %.3f %.3f\n", x, y, z, r, g, b)
            buffer.append(contentsOf: line.utf8)
            try flushIfNeeded()
        }
        var i = 0
        while i < mesh.indices.count {
            // OBJ đánh chỉ số đỉnh từ 1
            let a = mesh.indices[i] + 1
            let b = mesh.indices[i + 1] + 1
            let c = mesh.indices[i + 2] + 1
            buffer.append(contentsOf: "f \(a) \(b) \(c)\n".utf8)
            try flushIfNeeded()
            i += 3
        }
        try flushIfNeeded(force: true)
    }

    // MARK: - Nén thư mục thành .zip (dùng NSFileCoordinator, không cần thư viện ngoài)

    private static func zipDirectory(_ directory: URL, to zipURL: URL) throws {
        let fm = FileManager.default
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: directory, options: .forUploading, error: &coordError
        ) { tempZipURL in
            do {
                if fm.fileExists(atPath: zipURL.path) {
                    try fm.removeItem(at: zipURL)
                }
                // tempZipURL chỉ hợp lệ TRONG closure này — phải copy ra ngay.
                try fm.copyItem(at: tempZipURL, to: zipURL)
            } catch {
                copyError = error
            }
        }
        if let coordError { throw coordError }
        if let copyError { throw copyError }
        guard fm.fileExists(atPath: zipURL.path) else { throw ExportError.zipFailed }
    }
}
