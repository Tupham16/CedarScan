import Foundation

/// Chuyển mô hình LiDAR CÓ MÀU (file .ply do ColorMeshBuilder xuất) sang gói ZIP
/// chứa OBJ + MTL — kiểu Scaniverse/Polycam. OBJ mang MÀU THEO ĐỈNH (v x y z r g b),
/// mở được CÓ MÀU trong MeshLab, CloudCompare và (bật tay) trong Blender.
///
/// LƯU Ý: màu đỉnh trong OBJ là phi tiêu chuẩn — Blender khi RENDER lấy màu từ vật liệu
/// nên OBJ+MTL không tự ra màu khi render. Muốn Blender ra màu ngay, dùng GLBExporter.
///
/// Chạy NỀN (nặng ~10–20MB với 120k đỉnh). Chỉ đọc/ghi file, không đụng UIKit.
enum ColoredOBJExporter {
    enum ExportError: Error { case zipFailed }

    /// Đọc PLY màu → ghi model.obj + model.mtl vào 1 thư mục tạm rồi nén thành .zip tại `zipURL`.
    static func makeOBJZip(fromPLY plyURL: URL, to zipURL: URL) throws {
        let mesh = try ColoredMeshPLY.parse(plyURL)

        // MARK: - Dựng OBJ (màu theo đỉnh) + MTL
        var lines: [String] = []
        lines.reserveCapacity(mesh.positions.count + mesh.indices.count / 3 + 4)
        lines.append("# CedarScan colored LiDAR mesh")
        lines.append("mtllib model.mtl")
        lines.append("o CedarScanMesh")
        lines.append("usemtl vertexcolor")
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
            lines.append(String(format: "v %.4f %.4f %.4f %.3f %.3f %.3f", x, y, z, r, g, b))
        }
        var i = 0
        while i < mesh.indices.count {
            // OBJ đánh chỉ số đỉnh từ 1
            let a = mesh.indices[i] + 1
            let b = mesh.indices[i + 1] + 1
            let c = mesh.indices[i + 2] + 1
            lines.append("f \(a) \(b) \(c)")
            i += 3
        }
        let objText = lines.joined(separator: "\n") + "\n"

        let mtlText = """
        # CedarScan material — màu nằm ở từng đỉnh (vertex colors), không dùng texture map.
        newmtl vertexcolor
        Ka 1.000 1.000 1.000
        Kd 1.000 1.000 1.000
        Ks 0.000 0.000 0.000
        d 1.0
        illum 1

        """

        // MARK: - Ghi 2 file vào thư mục tạm rồi nén
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("CedarScan-3D-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try Data(objText.utf8).write(to: work.appendingPathComponent("model.obj"))
        try Data(mtlText.utf8).write(to: work.appendingPathComponent("model.mtl"))

        try zipDirectory(work, to: zipURL)
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
