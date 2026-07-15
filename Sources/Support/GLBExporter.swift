import Foundation

/// Xuất mô hình LiDAR CÓ MÀU (từ file .ply của ColorMeshBuilder) sang **GLB (glTF 2.0 nhị phân)**.
///
/// Vì sao GLB thay vì OBJ: glTF mang màu đỉnh qua thuộc tính chuẩn `COLOR_0`, và bộ import
/// glTF của Blender TỰ nối màu này vào vật liệu → kéo file vào Blender là CÓ MÀU ngay ở cả
/// viewport lẫn render, không phải dựng node thủ công (khác hẳn OBJ+MTL).
///
/// Bố cục file GLB:
///   [header 12B] [chunk JSON] [chunk BIN]
/// Buffer nhị phân xếp liền: POSITION (VEC3 float) | COLOR_0 (VEC3 float) | indices (UInt32).
/// Mọi phần tử đều 4 byte nên mọi offset tự căn 4-byte — tránh lỗi alignment của glTF.
///
/// Toạ độ ARKit (Y-up, phải tay, mét) trùng quy ước glTF nên không cần đổi trục.
/// Chạy NỀN (nặng). Chỉ đọc/ghi file.
enum GLBExporter {
    enum ExportError: Error { case emptyMesh, writeFailed }

    private static let magic: UInt32 = 0x46546C67       // "glTF"
    private static let version: UInt32 = 2
    private static let jsonChunkType: UInt32 = 0x4E4F534A // "JSON"
    private static let binChunkType: UInt32 = 0x004E4942  // "BIN\0"

    /// Bảng tra sRGB(0..255) → linear(0..1) cho COLOR_0 của glTF (dựng 1 lần, tra O(1)).
    private static let srgbToLinear: [Float] = (0...255).map { i in
        let s = Float(i) / 255.0
        return s <= 0.04045 ? s / 12.92 : powf((s + 0.055) / 1.055, 2.4)
    }

    /// Đọc PLY màu → ghi file .glb tại `glbURL`.
    static func makeGLB(fromPLY plyURL: URL, to glbURL: URL) throws {
        try makeGLB(mesh: ColoredMeshPLY.parse(plyURL), to: glbURL)
    }

    /// Ghi .glb từ mesh ĐÃ parse — cho nơi gọi có sẵn mesh (ColoredOBJExporter gói zip)
    /// khỏi parse PLY hai lần trên mesh cả triệu đỉnh.
    static func makeGLB(mesh: ColoredMeshPLY.Mesh, to glbURL: URL) throws {
        let vCount = mesh.positions.count
        let iCount = mesh.indices.count
        guard vCount > 0, iCount > 0 else { throw ExportError.emptyMesh }

        // MARK: - Dựng buffer nhị phân + tính bounding box cho accessor POSITION
        let posLen = vCount * 12
        let colLen = vCount * 12
        let idxLen = iCount * 4
        var bin = Data()
        bin.reserveCapacity(posLen + colLen + idxLen)

        var minX = Float.greatestFiniteMagnitude, minY = Float.greatestFiniteMagnitude, minZ = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude, maxZ = -Float.greatestFiniteMagnitude

        // POSITION (VEC3 float)
        for p in mesh.positions {
            appendFloatLE(p.x, to: &bin)
            appendFloatLE(p.y, to: &bin)
            appendFloatLE(p.z, to: &bin)
            if p.x < minX { minX = p.x }; if p.x > maxX { maxX = p.x }
            if p.y < minY { minY = p.y }; if p.y > maxY { maxY = p.y }
            if p.z < minZ { minZ = p.z }; if p.z > maxZ { maxZ = p.z }
        }
        // COLOR_0 (VEC3 float). glTF quy định COLOR_0 là LINEAR; byte trong PLY là giá trị
        // hiển thị sRGB (lấy từ camera) nên giải mã sRGB→linear — nếu không Blender hiện quá sáng.
        for c in mesh.colors {
            appendFloatLE(Self.srgbToLinear[Int(c.r)], to: &bin)
            appendFloatLE(Self.srgbToLinear[Int(c.g)], to: &bin)
            appendFloatLE(Self.srgbToLinear[Int(c.b)], to: &bin)
        }
        // indices (UInt32 scalar)
        for idx in mesh.indices {
            appendUInt32LE(idx, to: &bin)
        }

        // MARK: - JSON glTF
        // Tách thành nhiều let có kiểu rõ ràng để mỗi literal con là bài toán type-check nhỏ,
        // độc lập (CI này từng timeout với biểu thức lớn — đây là bảo hiểm, không đổi hành vi).
        let asset: [String: Any] = ["version": "2.0", "generator": "CedarScan"]
        let scenes: [[String: Any]] = [["nodes": [0]]]
        let nodes: [[String: Any]] = [["mesh": 0, "name": "CedarScanMesh"]]
        let primitive: [String: Any] = [
            "attributes": ["POSITION": 0, "COLOR_0": 1],
            "indices": 2,
            "material": 0,
        ]
        let meshes: [[String: Any]] = [["name": "CedarScanMesh", "primitives": [primitive]]]
        let pbr: [String: Any] = [
            "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
            "metallicFactor": 0.0,
            "roughnessFactor": 1.0,
        ]
        let materials: [[String: Any]] = [["name": "colored", "pbrMetallicRoughness": pbr]]
        let buffers: [[String: Any]] = [["byteLength": bin.count]]
        let bufferViews: [[String: Any]] = [
            ["buffer": 0, "byteOffset": 0, "byteLength": posLen, "target": 34962],
            ["buffer": 0, "byteOffset": posLen, "byteLength": colLen, "target": 34962],
            ["buffer": 0, "byteOffset": posLen + colLen, "byteLength": idxLen, "target": 34963],
        ]
        let posAccessor: [String: Any] = [
            "bufferView": 0, "componentType": 5126, "count": vCount, "type": "VEC3",
            "min": [minX, minY, minZ], "max": [maxX, maxY, maxZ],
        ]
        let accessors: [[String: Any]] = [
            posAccessor,
            ["bufferView": 1, "componentType": 5126, "count": vCount, "type": "VEC3"],
            ["bufferView": 2, "componentType": 5125, "count": iCount, "type": "SCALAR"],
        ]
        let gltf: [String: Any] = [
            "asset": asset,
            "scene": 0,
            "scenes": scenes,
            "nodes": nodes,
            "meshes": meshes,
            "materials": materials,
            "buffers": buffers,
            "bufferViews": bufferViews,
            "accessors": accessors,
        ]
        var jsonData = try JSONSerialization.data(withJSONObject: gltf, options: [])

        // MARK: - Đóng gói GLB (chunk căn 4 byte: JSON đệm bằng space, BIN đệm bằng 0)
        padTo4(&jsonData, with: 0x20)
        padTo4(&bin, with: 0x00)

        let totalLength = 12 + 8 + jsonData.count + 8 + bin.count

        var out = Data()
        out.reserveCapacity(totalLength)
        appendUInt32LE(magic, to: &out)
        appendUInt32LE(version, to: &out)
        appendUInt32LE(UInt32(totalLength), to: &out)
        // Chunk 0: JSON
        appendUInt32LE(UInt32(jsonData.count), to: &out)
        appendUInt32LE(jsonChunkType, to: &out)
        out.append(jsonData)
        // Chunk 1: BIN
        appendUInt32LE(UInt32(bin.count), to: &out)
        appendUInt32LE(binChunkType, to: &out)
        out.append(bin)

        do {
            try out.write(to: glbURL)
        } catch {
            throw ExportError.writeFailed
        }
    }

    // MARK: - Helpers (little-endian; arm64 vốn LE nên bitPattern.littleEndian là chuẩn glTF)

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendFloatLE(_ value: Float, to data: inout Data) {
        appendUInt32LE(value.bitPattern, to: &data)
    }

    /// Đệm cho độ dài là bội số của 4 (yêu cầu của GLB cho từng chunk).
    private static func padTo4(_ data: inout Data, with byte: UInt8) {
        let remainder = data.count % 4
        if remainder != 0 {
            data.append(contentsOf: [UInt8](repeating: byte, count: 4 - remainder))
        }
    }
}
