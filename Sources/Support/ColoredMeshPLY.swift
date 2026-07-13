import Foundation

/// Đọc file .ply nhị phân CÓ MÀU do ColorMeshBuilder xuất (binary_little_endian:
/// vị trí float x/y/z + màu uchar r/g/b, mặt = list uchar/uint gồm 3 đỉnh).
/// Dùng chung cho các bộ xuất OBJ và GLB để không lặp lại phần đọc byte dễ sai.
enum ColoredMeshPLY {
    enum ParseError: Error { case unreadable, badHeader, truncated }

    struct Mesh {
        var positions: [(x: Float, y: Float, z: Float)]
        var colors: [(r: UInt8, g: UInt8, b: UInt8)]
        var indices: [UInt32]   // chỉ số tam giác dạng phẳng, 3 số mỗi mặt
    }

    static func parse(_ url: URL) throws -> Mesh {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw ParseError.unreadable
        }
        // Tách header (kết thúc ở "end_header\n")
        let marker = Data("end_header\n".utf8)
        guard let headerRange = data.range(of: marker),
              let header = String(data: data.subdata(in: 0..<headerRange.upperBound), encoding: .ascii)
        else { throw ParseError.badHeader }
        let bodyStart = headerRange.upperBound

        // Chỉ nhận đúng bố cục ta tự ghi; sai bố cục thì THÔI để không sinh file rác.
        guard header.contains("format binary_little_endian"),
              header.contains("property float x"),
              header.contains("property uchar red"),
              header.contains("property list uchar uint")
        else { throw ParseError.badHeader }

        var vertexCount = 0
        var faceCount = 0
        for line in header.split(separator: "\n") {
            let p = line.split(separator: " ")
            guard p.count == 3, p[0] == "element" else { continue }
            if p[1] == "vertex" { vertexCount = Int(p[2]) ?? 0 }
            else if p[1] == "face" { faceCount = Int(p[2]) ?? 0 }
        }
        guard vertexCount > 0, faceCount > 0 else { throw ParseError.badHeader }

        let vertexStride = 15   // 3×float (12) + 3×uchar (3)
        let faceStride = 13     // 1×uchar (1) + 3×uint (12)
        let needed = bodyStart + vertexCount * vertexStride + faceCount * faceStride
        guard data.count >= needed else { throw ParseError.truncated }

        var positions = [(x: Float, y: Float, z: Float)](); positions.reserveCapacity(vertexCount)
        var colors = [(r: UInt8, g: UInt8, b: UInt8)](); colors.reserveCapacity(vertexCount)
        var indices = [UInt32](); indices.reserveCapacity(faceCount * 3)

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
                positions.append((x, y, z))
                colors.append((r, g, b))
                off += vertexStride
            }
            for _ in 0..<faceCount {
                let count = base.loadUnaligned(fromByteOffset: off, as: UInt8.self)
                off += 1
                if count == 3 {
                    indices.append(base.loadUnaligned(fromByteOffset: off, as: UInt32.self))
                    indices.append(base.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self))
                    indices.append(base.loadUnaligned(fromByteOffset: off + 8, as: UInt32.self))
                }
                off += Int(count) * 4
            }
        }
        return Mesh(positions: positions, colors: colors, indices: indices)
    }
}
