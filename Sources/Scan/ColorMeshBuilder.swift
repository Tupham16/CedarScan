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
    // Giới hạn để file nhẹ + không tốn RAM — theo mức độ nét đã chọn (MeshQuality)
    private let maxVertices: Int
    private let maxKeyframes: Int
    private let keyframeWidth: Int
    /// Nhịp chụp khung màu — TỰ NHÂN ĐÔI mỗi khi buffer đầy (xem maybeCaptureColorFrame)
    /// để khung màu luôn trải ĐỀU cả buổi quét dài bất kỳ với RAM cố định.
    private var keyframeIntervalSec: Double

    private weak var arSession: ARSession?
    private var displayLink: CADisplayLink?

    // Lưới gom theo từng anchor (cập nhật đè khi anchor tinh chỉnh lại)
    private struct MeshPiece {
        var worldVertices: [SIMD3<Float>]
        var worldNormals: [SIMD3<Float>]
        var faces: [(UInt32, UInt32, UInt32)]
    }
    private var pieces: [UUID: MeshPiece] = [:]

    /// Chữ ký để BỎ QUA anchor không đổi giữa hai tick (đa số anchor đứng yên đa số thời
    /// gian — bỏ qua chúng cắt ~95% việc copy trên main thread). PHẢI so cả transform:
    /// đỉnh được bake sang world-space, nên anchor chỉ tinh chỉnh pose (số đỉnh giữ nguyên)
    /// mà bị bỏ qua sẽ để lại tọa độ world cũ sai.
    private struct AnchorSig {
        var vertexCount: Int
        var faceCount: Int
        var transform: simd_float4x4
    }
    private var anchorSigs: [UUID: AnchorSig] = [:]

    /// Đã chạm trần đỉnh → anchor mới (khu quét sau) không được gom nữa.
    /// RoomPlan mode: cross-check tường dùng cờ này để không trừ điểm oan.
    /// Mesh mode: controller đọc cờ này để hiện banner "mô hình đã đầy".
    private(set) var capReached = false

    /// Tổng số đỉnh đang giữ — Mesh mode dùng để chặn lưu bản quét rỗng.
    /// Chỉ đọc trên main (cùng luồng với CADisplayLink tick).
    var vertexCount: Int {
        pieces.values.reduce(0) { $0 + $1.worldVertices.count }
    }

    /// Đang đầy NGAY LÚC NÀY — dùng cho banner Mesh mode. KHÁC capReached ("đã từng
    /// chạm trần", sticky, cho report RoomPlan): sau khi dọn anchor bị ARKit xóa,
    /// có thể còn chỗ trở lại và banner phải tự hạ.
    var isFull: Bool {
        vertexCount >= maxVertices
    }

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

    init(arSession: ARSession, preset: MeshQuality.Preset = MeshQuality.light.preset) {
        self.arSession = arSession
        maxVertices = preset.maxVertices
        maxKeyframes = preset.maxKeyframes
        keyframeWidth = preset.keyframeWidth
        keyframeIntervalSec = preset.keyframeIntervalSec
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
        // Dọn anchor bị ARKit xóa TRƯỚC khi đếm: ARKit gộp/tách chunk mesh liên tục
        // (nhiều nhất ở phút đầu). Không dọn thì đỉnh "ma" của anchor chết tích lại —
        // vừa phình vertexTotal (báo "mô hình đầy" oan chỉ sau ~10 giây quét), vừa để
        // hình học cũ đã bị thay thế nằm sai chỗ trong file xuất.
        var present = Set<UUID>()
        present.reserveCapacity(frame.anchors.count)
        for anchor in frame.anchors {
            if let mesh = anchor as? ARMeshAnchor {
                present.insert(mesh.identifier)
            }
        }
        for id in Array(pieces.keys) where !present.contains(id) {
            pieces.removeValue(forKey: id)
            anchorSigs.removeValue(forKey: id)
        }

        var vertexTotal = pieces.values.reduce(0) { $0 + $1.worldVertices.count }
        for anchor in frame.anchors {
            guard let mesh = anchor as? ARMeshAnchor else { continue }
            let geometry = mesh.geometry
            let vSource = geometry.vertices
            let nSource = geometry.normals
            let faceElement = geometry.faces
            let count = vSource.count
            let transform = mesh.transform

            // Anchor KHÔNG ĐỔI từ tick trước → bỏ qua (đỡ copy lại cả phiên mỗi tick).
            if let old = anchorSigs[mesh.identifier],
               old.vertexCount == count, old.faceCount == faceElement.count,
               old.transform == transform {
                continue
            }
            if pieces[mesh.identifier] == nil && vertexTotal >= maxVertices {
                capReached = true
                continue
            }
            // Chặn đọc lấn buffer: vertices/normals là float3 PACKED stride 12 —
            // đọc 3 Float rời bằng loadUnaligned, tuyệt đối không ép SIMD3<Float> (16 byte).
            guard count > 0,
                  vSource.offset + vSource.stride * count <= vSource.buffer.length,
                  nSource.count >= count,
                  nSource.offset + nSource.stride * count <= nSource.buffer.length
            else { continue }

            let normalMatrix = simd_float3x3(
                SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            )

            let vBase = vSource.buffer.contents().advanced(by: vSource.offset)
            let nBase = nSource.buffer.contents().advanced(by: nSource.offset)
            var worldVertices = [SIMD3<Float>](); worldVertices.reserveCapacity(count)
            var worldNormals = [SIMD3<Float>](); worldNormals.reserveCapacity(count)
            for i in 0..<count {
                let vOff = vSource.stride * i
                let lx = vBase.loadUnaligned(fromByteOffset: vOff, as: Float.self)
                let ly = vBase.loadUnaligned(fromByteOffset: vOff + 4, as: Float.self)
                let lz = vBase.loadUnaligned(fromByteOffset: vOff + 8, as: Float.self)
                let world = transform * SIMD4<Float>(lx, ly, lz, 1)
                worldVertices.append(SIMD3(world.x, world.y, world.z))

                let nOff = nSource.stride * i
                let nx = nBase.loadUnaligned(fromByteOffset: nOff, as: Float.self)
                let ny = nBase.loadUnaligned(fromByteOffset: nOff + 4, as: Float.self)
                let nz = nBase.loadUnaligned(fromByteOffset: nOff + 8, as: Float.self)
                worldNormals.append(simd_normalize(normalMatrix * SIMD3(nx, ny, nz)))
            }

            var faces = [(UInt32, UInt32, UInt32)]()
            if faceElement.bytesPerIndex == 4, faceElement.indexCountPerPrimitive == 3,
               faceElement.count * 3 * 4 <= faceElement.buffer.length {
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
            anchorSigs[mesh.identifier] = AnchorSig(
                vertexCount: count, faceCount: faceElement.count, transform: transform
            )
            vertexTotal += worldVertices.count
        }
    }

    // MARK: - Khung màu

    private func maybeCaptureColorFrame(from frame: ARFrame) {
        guard frame.timestamp - lastKeyframeTime >= keyframeIntervalSec else { return }
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

        let tw = min(keyframeWidth, srcW)
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
        if keyframes.count >= maxKeyframes {
            // Buffer đầy: BỎ 1 KHUNG XEN KẼ (giữ 0,2,4,…) rồi nhân đôi nhịp chụp — khung màu
            // luôn trải ĐỀU cả buổi quét dài bất kỳ với RAM cố định.
            // (Fix bug cũ: `count % max` luôn = 0 khi đầy → chỉ đè slot 0, slot 1..39 đóng
            // băng ở ~16 giây đầu → quét dài ra màu xám/sai ở mọi thứ quét sau đó.)
            keyframes = stride(from: 0, to: keyframes.count, by: 2).map { keyframes[$0] }
            keyframeIntervalSec *= 2
        }
        keyframes.append(kf)
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

        // Màu từng đỉnh — dữ liệu chiếu của mỗi khung màu tính SẴN 1 lần (hoist simd_inverse
        // + intrinsics khỏi vòng lặp: trước đây bị tính lại cho TỪNG đỉnh × TỪNG khung,
        // hàng chục triệu lần thừa ở mức Nét → save lâu vô lý).
        let samplers = keyframes.map { kf in
            KeyframeSampler(
                rgb: kf.rgb, w: kf.w, h: kf.h, srcW: kf.srcW, srcH: kf.srcH,
                camPos: SIMD3(kf.transform.columns.3.x, kf.transform.columns.3.y, kf.transform.columns.3.z),
                worldToCamera: simd_inverse(kf.transform),
                fx: kf.intrinsics.columns.0.x,
                fy: kf.intrinsics.columns.1.y,
                cx: kf.intrinsics.columns.2.x,
                cy: kf.intrinsics.columns.2.y
            )
        }
        var colors = [SIMD3<UInt8>](repeating: SIMD3(150, 150, 150), count: vertices.count)
        // Song song hóa theo chunk: mỗi chunk ghi một dải chỉ số RIÊNG (không giao nhau),
        // dữ liệu đọc (vertices/normals/samplers) bất biến → an toàn. Nguyên căn ở trần
        // 2M đỉnh × 64 khung màu là ~128 triệu phép chiếu — tuần tự sẽ bắt chờ rất lâu.
        let total = vertices.count
        let chunkSize = 16_384
        let chunkCount = (total + chunkSize - 1) / chunkSize
        vertices.withUnsafeBufferPointer { vBuf in
            normals.withUnsafeBufferPointer { nBuf in
                colors.withUnsafeMutableBufferPointer { cBuf in
                    DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                        let start = chunk * chunkSize
                        let end = min(start + chunkSize, total)
                        for i in start..<end {
                            cBuf[i] = sampleColor(world: vBuf[i], normal: nBuf[i], samplers: samplers)
                        }
                    }
                }
            }
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

    /// Khung màu + dữ liệu chiếu đã tính sẵn (1 lần/khung, dùng cho mọi đỉnh).
    private struct KeyframeSampler {
        let rgb: [UInt8]
        let w: Int
        let h: Int
        let srcW: Float
        let srcH: Float
        let camPos: SIMD3<Float>
        let worldToCamera: simd_float4x4
        let fx: Float
        let fy: Float
        let cx: Float
        let cy: Float
    }

    /// Chiếu đỉnh vào các khung màu, chọn khung nhìn thẳng nhất, lấy RGB.
    /// Lưu ý đã biết: KHÔNG có occlusion test — đỉnh tầng 2 có normal tình cờ hướng về camera
    /// tầng 1 có thể lấy màu xuyên sàn; nhiều khung màu trải đều làm giảm chứ không loại hẳn.
    private static func sampleColor(
        world: SIMD3<Float>, normal: SIMD3<Float>, samplers: [KeyframeSampler]
    ) -> SIMD3<UInt8> {
        var best: SIMD3<UInt8>? = nil
        var bestScore: Float = -1

        for kf in samplers {
            let toCam = simd_normalize(kf.camPos - world)
            let facing = simd_dot(normal, toCam)
            if facing <= 0.1 { continue } // quay lưng với camera → bỏ
            if facing <= bestScore { continue } // không thể thắng khung tốt nhất → khỏi chiếu

            // Đưa về hệ camera (camera nhìn theo -Z)
            let cs4 = kf.worldToCamera * SIMD4<Float>(world.x, world.y, world.z, 1)
            let z = cs4.z
            if z >= -0.05 { continue } // sau lưng hoặc quá sát

            // Ảnh gốc: origin trên-trái, x phải, y xuống
            let xImg = kf.cx + kf.fx * (cs4.x / -z)
            let yImg = kf.cy + kf.fy * (cs4.y / z)
            guard xImg >= 0, yImg >= 0, xImg < kf.srcW, yImg < kf.srcH else { continue }

            let kx = min(kf.w - 1, Int(xImg * Float(kf.w) / kf.srcW))
            let ky = min(kf.h - 1, Int(yImg * Float(kf.h) / kf.srcH))
            let o = (ky * kf.w + kx) * 3

            bestScore = facing
            best = SIMD3(kf.rgb[o], kf.rgb[o + 1], kf.rgb[o + 2])
        }
        return best ?? SIMD3(150, 150, 150)
    }
}
