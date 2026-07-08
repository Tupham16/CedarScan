import Foundation
import ARKit
import simd

/// Dựng mô hình 3D CÓ MÀU (thấp phân giải, file nhẹ) từ lưới LiDAR + màu lấy từ khung hình camera.
/// Xuất ra file PLY nhị phân với màu theo từng đỉnh. Đây là NGUYÊN LIỆU NỘI BỘ cho đội xử lý.
///
/// Cách hoạt động (chạy trên nhánh riêng, không bao giờ làm hỏng luồng quét chính):
///  - Định kỳ đọc arSession.currentFrame: gom lưới (ARMeshAnchor) + lưu vài "khung màu" nhỏ.
///  - Khi kết thúc: chiếu từng đỉnh lưới vào khung màu nhìn thẳng nhất → lấy RGB → ghi PLY.
final class ColorMeshBuilder {
    // Giới hạn để file nhẹ + không tốn RAM
    private static let maxVertices = 120_000
    private static let maxKeyframes = 40
    private static let keyframeIntervalSec = 0.4
    private static let keyframeWidth = 320

    private weak var arSession: ARSession?
    private var displayLink: CADisplayLink?

    // Lưới gom theo từng anchor (cập nhật đè khi anchor tinh chỉnh lại)
    private struct MeshPiece {
        var worldVertices: [SIMD3<Float>]
        var worldNormals: [SIMD3<Float>]
        var faces: [(UInt32, UInt32, UInt32)]
    }
    private var pieces: [UUID: MeshPiece] = [:]

    /// Đã chạm trần 120k đỉnh → anchor mới (phòng quét sau) không được gom nữa.
    /// Cross-check tường dùng cờ này để KHÔNG trừ điểm "tường thiếu dữ liệu" oan cho khách.
    private(set) var capReached = false

    // Khung màu: RGB nhỏ (origin trên-trái) + ma trận camera của đúng khung đó
    private struct ColorFrame {
        var rgb: [UInt8]        // w*h*3
        var w: Int
        var h: Int
        var srcW: Float         // độ phân giải gốc (khớp với intrinsics)
        var srcH: Float
        var transform: simd_float4x4
        var intrinsics: simd_float3x3
    }
    private var keyframes: [ColorFrame] = []
    private var lastKeyframeTime: TimeInterval = 0
    private let queue = DispatchQueue(label: "com.cedar247.colormesh")

    init(arSession: ARSession) {
        self.arSession = arSession
    }

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 2, maximum: 5, preferred: 3)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        guard let frame = arSession?.currentFrame else { return }
        ingestMesh(from: frame)
        maybeCaptureColorFrame(from: frame)
    }

    // MARK: - Gom lưới

    private func ingestMesh(from frame: ARFrame) {
        var vertexTotal = pieces.values.reduce(0) { $0 + $1.worldVertices.count }
        for anchor in frame.anchors {
            guard let mesh = anchor as? ARMeshAnchor else { continue }
            if pieces[mesh.identifier] == nil && vertexTotal >= Self.maxVertices {
                capReached = true
                continue
            }

            let geometry = mesh.geometry
            let transform = mesh.transform
            let normalMatrix = simd_float3x3(
                SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            )

            let vSource = geometry.vertices
            let nSource = geometry.normals
            let count = vSource.count
            var worldVertices = [SIMD3<Float>](); worldVertices.reserveCapacity(count)
            var worldNormals = [SIMD3<Float>](); worldNormals.reserveCapacity(count)
            for i in 0..<count {
                let vPtr = vSource.buffer.contents()
                    .advanced(by: vSource.offset + vSource.stride * i)
                    .assumingMemoryBound(to: SIMD3<Float>.self)
                let local = vPtr.pointee
                let world = transform * SIMD4<Float>(local.x, local.y, local.z, 1)
                worldVertices.append(SIMD3(world.x, world.y, world.z))

                let nPtr = nSource.buffer.contents()
                    .advanced(by: nSource.offset + nSource.stride * i)
                    .assumingMemoryBound(to: SIMD3<Float>.self)
                worldNormals.append(simd_normalize(normalMatrix * nPtr.pointee))
            }

            let faceElement = geometry.faces
            var faces = [(UInt32, UInt32, UInt32)]()
            if faceElement.bytesPerIndex == 4 && faceElement.indexCountPerPrimitive == 3 {
                faces.reserveCapacity(faceElement.count)
                let base = faceElement.buffer.contents()
                for f in 0..<faceElement.count {
                    let idx = base.advanced(by: f * 3 * 4).assumingMemoryBound(to: UInt32.self)
                    faces.append((idx[0], idx[1], idx[2]))
                }
            }

            if let old = pieces[mesh.identifier] {
                vertexTotal -= old.worldVertices.count
            }
            pieces[mesh.identifier] = MeshPiece(
                worldVertices: worldVertices, worldNormals: worldNormals, faces: faces
            )
            vertexTotal += worldVertices.count
        }
    }

    // MARK: - Khung màu

    private func maybeCaptureColorFrame(from frame: ARFrame) {
        guard frame.timestamp - lastKeyframeTime >= Self.keyframeIntervalSec else { return }
        lastKeyframeTime = frame.timestamp

        let pixelBuffer = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        guard srcW > 0, srcH > 0,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
        let cPtr = cBase.assumingMemoryBound(to: UInt8.self)

        let tw = min(Self.keyframeWidth, srcW)
        let th = max(1, Int((Float(tw) * Float(srcH) / Float(srcW)).rounded()))
        var rgb = [UInt8](repeating: 0, count: tw * th * 3)

        for ty in 0..<th {
            let sy = min(srcH - 1, ty * srcH / th)
            for tx in 0..<tw {
                let sx = min(srcW - 1, tx * srcW / tw)
                let y = Float(yPtr[sy * yStride + sx])
                let ci = (sy / 2) * cStride + (sx / 2) * 2
                let cb = Float(cPtr[ci]) - 128
                let cr = Float(cPtr[ci + 1]) - 128
                let o = (ty * tw + tx) * 3
                rgb[o] = clampByte(y + 1.402 * cr)
                rgb[o + 1] = clampByte(y - 0.344136 * cb - 0.714136 * cr)
                rgb[o + 2] = clampByte(y + 1.772 * cb)
            }
        }

        let kf = ColorFrame(
            rgb: rgb, w: tw, h: th, srcW: Float(srcW), srcH: Float(srcH),
            transform: frame.camera.transform, intrinsics: frame.camera.intrinsics
        )
        if keyframes.count >= Self.maxKeyframes {
            // Giữ đều: thay 1 khung cũ ngẫu-nhiên-theo-vị-trí để trải khắp buổi quét
            keyframes[keyframes.count % Self.maxKeyframes] = kf
        } else {
            keyframes.append(kf)
        }
    }

    private func clampByte(_ v: Float) -> UInt8 {
        UInt8(max(0, min(255, v)))
    }

    /// Bản chụp các đỉnh world-space cho cross-check tường (gọi trên main, TRƯỚC exportColoredPLY).
    func snapshotWorldVertices() -> [[SIMD3<Float>]] {
        pieces.values.map(\.worldVertices)
    }

    // MARK: - Xuất PLY màu (gọi khi kết thúc; nặng nên chạy nền)

    /// Trả về URL file .ply (màu) hoặc nil nếu không dựng được (không có lưới / lỗi).
    func exportColoredPLY() async -> URL? {
        stop()
        let pieces = self.pieces
        let keyframes = self.keyframes
        guard !pieces.isEmpty, !keyframes.isEmpty else { return nil }

        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            queue.async {
                let url = Self.buildPLY(pieces: pieces, keyframes: keyframes)
                continuation.resume(returning: url)
            }
        }
    }

    private static func buildPLY(pieces: [UUID: MeshPiece], keyframes: [ColorFrame]) -> URL? {
        // Gộp lưới thành 1 mảng đỉnh + mặt (dời chỉ số)
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var faces: [(UInt32, UInt32, UInt32)] = []
        for piece in pieces.values {
            let base = UInt32(vertices.count)
            vertices.append(contentsOf: piece.worldVertices)
            normals.append(contentsOf: piece.worldNormals)
            for f in piece.faces {
                faces.append((f.0 + base, f.1 + base, f.2 + base))
            }
        }
        guard !vertices.isEmpty, !faces.isEmpty else { return nil }

        // Màu từng đỉnh
        var colors = [SIMD3<UInt8>](repeating: SIMD3(150, 150, 150), count: vertices.count)
        for i in vertices.indices {
            colors[i] = sampleColor(world: vertices[i], normal: normals[i], keyframes: keyframes)
        }

        // Ghi PLY nhị phân little-endian (KHÔNG dùng ModelIO — lỗi màu trên iOS)
        var header = "ply\n"
        header += "format binary_little_endian 1.0\n"
        header += "comment CedarScan colored LiDAR mesh\n"
        header += "element vertex \(vertices.count)\n"
        header += "property float x\nproperty float y\nproperty float z\n"
        header += "property uchar red\nproperty uchar green\nproperty uchar blue\n"
        header += "element face \(faces.count)\n"
        header += "property list uchar uint vertex_indices\n"
        header += "end_header\n"

        var data = Data(header.utf8)
        data.reserveCapacity(header.count + vertices.count * 15 + faces.count * 13)
        for i in vertices.indices {
            var x = vertices[i].x, y = vertices[i].y, z = vertices[i].z
            withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &y) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &z) { data.append(contentsOf: $0) }
            data.append(colors[i].x); data.append(colors[i].y); data.append(colors[i].z)
        }
        for f in faces {
            data.append(3)
            var a = f.0, b = f.1, c = f.2
            withUnsafeBytes(of: &a) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &b) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &c) { data.append(contentsOf: $0) }
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("colored-mesh-\(UUID().uuidString.prefix(8)).ply")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Chiếu đỉnh vào các khung màu, chọn khung nhìn thẳng nhất, lấy RGB.
    private static func sampleColor(
        world: SIMD3<Float>, normal: SIMD3<Float>, keyframes: [ColorFrame]
    ) -> SIMD3<UInt8> {
        var best: SIMD3<UInt8>? = nil
        var bestScore: Float = -1

        for kf in keyframes {
            let camPos = SIMD3(kf.transform.columns.3.x, kf.transform.columns.3.y, kf.transform.columns.3.z)
            let toCam = simd_normalize(camPos - world)
            let facing = simd_dot(normal, toCam)
            if facing <= 0.1 { continue } // quay lưng với camera → bỏ

            // Đưa về hệ camera (camera nhìn theo -Z)
            let inv = simd_inverse(kf.transform)
            let cs4 = inv * SIMD4<Float>(world.x, world.y, world.z, 1)
            let z = cs4.z
            if z >= -0.05 { continue } // sau lưng hoặc quá sát

            let fx = kf.intrinsics.columns.0.x
            let fy = kf.intrinsics.columns.1.y
            let cx = kf.intrinsics.columns.2.x
            let cy = kf.intrinsics.columns.2.y
            // Ảnh gốc: origin trên-trái, x phải, y xuống
            let xImg = cx + fx * (cs4.x / -z)
            let yImg = cy + fy * (cs4.y / z)
            guard xImg >= 0, yImg >= 0, xImg < kf.srcW, yImg < kf.srcH else { continue }

            let kx = min(kf.w - 1, Int(xImg * Float(kf.w) / kf.srcW))
            let ky = min(kf.h - 1, Int(yImg * Float(kf.h) / kf.srcH))
            let o = (ky * kf.w + kx) * 3

            if facing > bestScore {
                bestScore = facing
                best = SIMD3(kf.rgb[o], kf.rgb[o + 1], kf.rgb[o + 2])
            }
        }
        return best ?? SIMD3(150, 150, 150)
    }
}
