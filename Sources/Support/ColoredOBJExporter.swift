import Foundation

/// Chuyển mô hình LiDAR CÓ MÀU (file .ply do ColorMeshBuilder xuất) sang gói ZIP
/// chứa OBJ + MTL — kiểu Scaniverse/Polycam. OBJ mang MÀU THEO ĐỈNH (v x y z r g b),
/// mở được CÓ MÀU trong Blender, MeshLab, CloudCompare và đa số viewer online.
///
/// Vì sao KHÔNG dùng ModelIO (như OBJExporter cũ): ModelIO xuất từ USDZ TRẮNG của
/// RoomPlan (không màu) và hay tạo file hỏng trên iOS. Ở đây ta ghi OBJ thủ công từ
/// đúng lưới LiDAR có màu nên chắc chắn mở được và có màu thật.
///
/// Chạy NỀN (nặng ~10–20MB với 120k đỉnh). Chỉ đọc/ghi file, không đụng UIKit.
enum ColoredOBJExporter {
    enum ExportError: Error { case unreadable, badHeader, truncated, zipFailed }

    private struct Vertex { var x, y, z: Float; var r, g, b: UInt8 }

    /// Đọc PLY nhị phân (đúng định dạng ColorMeshBuilder ghi) → ghi model.obj + model.mtl
    /// vào 1 thư mục tạm rồi nén thành .zip tại `zipURL`.
    static func makeOBJZip(fromPLY plyURL: URL, to zipURL: URL) throws {
        let (vertices, faces) = try parsePLY(plyURL)

        // MARK: - Dựng OBJ (màu theo đỉnh) + MTL
        var lines: [String] = []
        lines.reserveCapacity(vertices.count + faces.count + 4)
        lines.append("# CedarScan colored LiDAR mesh")
        lines.append("mtllib model.mtl")
        lines.append("o CedarScanMesh")
        lines.append("usemtl vertexcolor")
        for v in vertices {
            // Tách sẵn từng đối số thành let Double để biểu thức String(format:) nhẹ cho
            // type-checker (CI này từng timeout vì biểu thức phức tạp).
            let x = Double(v.x)
            let y = Double(v.y)
            let z = Double(v.z)
            let r = Double(v.r) / 255.0
            let g = Double(v.g) / 255.0
            let b = Double(v.b) / 255.0
            lines.append(String(format: "v %.4f %.4f %.4f %.3f %.3f %.3f", x, y, z, r, g, b))
        }
        for f in faces {
            // OBJ đánh chỉ số đỉnh từ 1
            lines.append("f \(f.0 + 1) \(f.1 + 1) \(f.2 + 1)")
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

    // MARK: - Đọc PLY nhị phân little-endian

    private static func parsePLY(_ url: URL) throws -> (vertices: [Vertex], faces: [(UInt32, UInt32, UInt32)]) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw ExportError.unreadable
        }
        // Tách header (kết thúc ở "end_header\n")
        let marker = Data("end_header\n".utf8)
        guard let headerRange = data.range(of: marker),
              let header = String(data: data.subdata(in: 0..<headerRange.upperBound), encoding: .ascii)
        else { throw ExportError.badHeader }
        let bodyStart = headerRange.upperBound

        // Chỉ nhận đúng bố cục ta tự ghi: pos float + màu uchar, mặt là list uchar/uint.
        // Sai bố cục thì THÔI (throw) để không sinh file rác.
        guard header.contains("format binary_little_endian"),
              header.contains("property float x"),
              header.contains("property uchar red"),
              header.contains("property list uchar uint")
        else { throw ExportError.badHeader }

        var vertexCount = 0
        var faceCount = 0
        for line in header.split(separator: "\n") {
            let p = line.split(separator: " ")
            guard p.count == 3, p[0] == "element" else { continue }
            if p[1] == "vertex" { vertexCount = Int(p[2]) ?? 0 }
            else if p[1] == "face" { faceCount = Int(p[2]) ?? 0 }
        }
        guard vertexCount > 0, faceCount > 0 else { throw ExportError.badHeader }

        let vertexStride = 15   // 3×float (12) + 3×uchar (3)
        let faceStride = 13     // 1×uchar (1) + 3×uint (12)
        let needed = bodyStart + vertexCount * vertexStride + faceCount * faceStride
        guard data.count >= needed else { throw ExportError.truncated }

        var vertices = [Vertex](); vertices.reserveCapacity(vertexCount)
        var faces = [(UInt32, UInt32, UInt32)](); faces.reserveCapacity(faceCount)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!
            var off = bodyStart
            for _ in 0..<vertexCount {
                let x = base.loadUnaligned(fromByteOffset: off, as: Float.self)
                let y = base.loadUnaligned(fromByteOffset: off + 4, as: Float.self)
                let z = base.loadUnaligned(fromByteOffset: off + 8, as: Float.self)
                let r = base.loadUnaligned(fromByteOffset: off + 12, as: UInt8.self)
                let g = base.loadUnaligned(fromByteOffset: off + 13, as: UInt8.self)
                let b = base.loadUnaligned(fromByteOffset: off + 14, as: UInt8.self)
                vertices.append(Vertex(x: x, y: y, z: z, r: r, g: g, b: b))
                off += vertexStride
            }
            for _ in 0..<faceCount {
                let count = base.loadUnaligned(fromByteOffset: off, as: UInt8.self)
                off += 1
                if count == 3 {
                    let a = base.loadUnaligned(fromByteOffset: off, as: UInt32.self)
                    let b = base.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self)
                    let c = base.loadUnaligned(fromByteOffset: off + 8, as: UInt32.self)
                    faces.append((a, b, c))
                }
                off += Int(count) * 4
            }
        }
        return (vertices, faces)
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
