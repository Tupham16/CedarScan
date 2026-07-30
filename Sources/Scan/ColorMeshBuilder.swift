import Foundation
import ARKit
import simd
// UIKit tường minh cho `UIApplication.didReceiveMemoryWarningNotification` (xem `start()`).
// ARKit kéo UIKit vào gián tiếp, nhưng dựa vào import gián tiếp là thứ chỉ vỡ ra sau 10 phút CI.
import UIKit

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

    /// Có anchor bị TỪ CHỐI ở lượt gom gần nhất (hết chỗ). Anchor bị chặn không có
    /// chữ ký nên tick sau tự thử lại — có chỗ là vào và cờ tự hạ.
    private var blockedNewAnchor = false

    /// Đang đầy NGAY LÚC NÀY — dùng cho banner Mesh mode. KHÁC capReached ("đã từng
    /// chạm trần", sticky, cho report RoomPlan): ARKit gộp anchor có thể giải phóng
    /// chỗ trở lại và banner phải tự hạ. Dựa vào blockedNewAnchor (có dữ liệu THẬT
    /// đang bị bỏ) chứ không chỉ so tổng — trần giờ chặn chặt nên tổng hiếm khi chạm.
    var isFull: Bool {
        blockedNewAnchor || vertexCount >= maxVertices
    }

    // Khung màu: RGB nhỏ (origin trên-trái) + ma trận camera của đúng khung đó
    // + depth map LiDAR đi kèm (nếu phiên bật .sceneDepth) để KIỂM TRA CHE KHUẤT khi gán màu.
    private struct ColorFrame {
        var rgb: [UInt8]        // w*h*3
        var w: Int
        var h: Int
        var srcW: Float         // độ phân giải gốc (khớp với intrinsics)
        var srcH: Float
        var transform: simd_float4x4
        var intrinsics: simd_float3x3
        var depth: [Float]      // dw*dh mét, cùng hướng/FOV với ảnh màu; RỖNG nếu không có depth
        var dw: Int
        var dh: Int
    }
    private var keyframes: [ColorFrame] = []
    private var lastKeyframeTime: TimeInterval = 0
    private let queue = DispatchQueue(label: "com.cedar247.colormesh")
    /// Đăng ký nhận cảnh báo thiếu bộ nhớ của hệ thống — xem `beginMemoryGuard()`.
    private var memoryWarning: NSObjectProtocol?
    /// Mốc thời gian lần xả gần nhất (systemUptime) — chống CHÙM cảnh báo, xem
    /// `relieveMemoryPressure()`. 0 = chưa xả lần nào.
    private var lastMemoryRelief: TimeInterval = 0
    /// Quãng nghỉ giữa hai lần xả. Đủ dài để nuốt trọn một chùm cảnh báo (vài trăm ms), đủ
    /// ngắn để đợt áp lực SAU trong cùng buổi quét vẫn được cứu.
    private static let memoryReliefCooldown: TimeInterval = 20

    /// Các cờ hành vi mặc định TẮT để luồng RoomPlan (ScanSessionController gọi với
    /// default) giữ nguyên hành vi cũ; chế độ quét Mesh nguyên căn bật cả ba:
    /// - strictVertexCap: trần đỉnh chặn cả anchor update phình to (fix mất geometry khi
    ///   ARKit gộp anchor lúc đầy). RoomPlan giữ kiểu cũ — PLY 120k chỉ là tư liệu phụ.
    /// - captureDepthForOcclusion: lưu depth theo keyframe để kiểm tra che khuất khi gán
    ///   màu. KHÔNG suy từ frame.sceneDepth != nil: RoomPlan có thể tự bật depth nội bộ
    ///   tùy phiên bản iOS → suy như vậy sẽ lén đổi màu PLY của luồng RoomPlan.
    /// - refineLargeTriangles: lúc xuất, chia nhỏ tam giác lớn (midpoint 1→4) TRƯỚC khi
    ///   bake màu — ARKit gộp mảng phẳng (tường/sàn) thành tam giác to, vài đỉnh màu bị
    ///   Gouraud kéo nhòe cả mét. Chỉ THÊM đỉnh tại trung điểm cạnh, KHÔNG dịch chuyển
    ///   hình học; đổi bằng bake màu lâu hơn (×2–4) + file to hơn.
    /// - fillUncoloredVertices: cứu đỉnh "xám" (đã quét nhưng không khung màu nào qua
    ///   được bộ lọc chuẩn — khung bị vứt khi kho đầy / góc quá xiên / occlusion loại
    ///   nhầm): lượt vét lỏng tay + vá màu lân cận (kiểu inpainting của app quét thương
    ///   mại). Chỉ đụng đỉnh ĐÃ hỏng, vùng có màu giữ nguyên; thêm ~vài giây lúc xuất.
    private let strictVertexCap: Bool
    private let captureDepthForOcclusion: Bool
    private let refineLargeTriangles: Bool
    private let fillUncoloredVertices: Bool

    init(
        arSession: ARSession,
        // Giá trị mặc định GIỮ NGUYÊN bộ số của mức "Nhẹ" cũ (120k/320px/40 khung). Mức .light
        // đã bị bỏ khỏi MeshQuality (2026-07-19) nhưng luồng RoomPlan vẫn gọi init này không
        // truyền preset — viết thẳng số ra đây để hành vi RoomPlan không đổi một byte nào.
        preset: MeshQuality.Preset = MeshQuality.Preset(
            maxVertices: 120_000, keyframeWidth: 320, maxKeyframes: 40, keyframeIntervalSec: 0.4
        ),
        strictVertexCap: Bool = false,
        captureDepthForOcclusion: Bool = false,
        refineLargeTriangles: Bool = false,
        fillUncoloredVertices: Bool = false
    ) {
        self.arSession = arSession
        maxVertices = preset.maxVertices
        maxKeyframes = preset.maxKeyframes
        keyframeWidth = preset.keyframeWidth
        keyframeIntervalSec = preset.keyframeIntervalSec
        self.strictVertexCap = strictVertexCap
        self.captureDepthForOcclusion = captureDepthForOcclusion
        self.refineLargeTriangles = refineLargeTriangles
        self.fillUncoloredVertices = fillUncoloredVertices
        // Van xả chạy suốt vòng đời đối tượng, KHÔNG theo start()/stop() — xem beginMemoryGuard().
        beginMemoryGuard()
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

    /// VAN XẢ KHI iOS KÊU THIẾU BỘ NHỚ. Kho khung màu là khối lớn nhất app giữ suốt buổi quét
    /// (179MB mức Nét, 358MB mức Siêu nét) và nó nằm cạnh ARKit + bộ mã hoá video + lớp phủ
    /// lưới. Không có đường xả thì cảnh báo của hệ thống trôi qua vô ích rồi app bị giết — mất
    /// trắng buổi quét 10–30 phút, thứ đắt nhất với khách.
    ///
    /// 🔴 ĐĂNG KÝ Ở `init`, GỠ Ở `deinit` — TUYỆT ĐỐI KHÔNG buộc vào `start()`/`stop()`.
    /// `stop()` không có nghĩa "xong": `MeshScanController` gọi nó mỗi lần ARSession bị GIÁN
    /// ĐOẠN (cuộc gọi đến, app khác chiếm camera, app xuống nền) và cả ở đầu `stopAndExport`
    /// trước khi hoàn tất video H.264. Đó CHÍNH LÀ những cửa sổ iOS bắn cảnh báo nhiều nhất và
    /// ra tay jetsam mạnh nhất — mà kho khung thì vẫn còn nguyên trong suốt các cửa sổ đó.
    /// Buộc van vào `stop()` là tắt van đúng lúc cần nó nhất (review đối kháng bắt được).
    /// Handler tự vô hại khi kho đã rỗng nên giữ đăng ký suốt vòng đời là an toàn.
    ///
    /// Thông báo bắn trên main; `tick` (CADisplayLink gắn .main) và `exportColoredPLY`
    /// (@MainActor) cũng trên main → không tranh chấp.
    private func beginMemoryGuard() {
        memoryWarning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.relieveMemoryPressure()
        }
    }

    /// Xả một nấc: bỏ khung XEN KẼ (giữ 0,2,4…) rồi nhân đôi nhịp chụp — đúng cơ chế đã có
    /// lúc kho đầy, nên khung còn lại vẫn TRẢI ĐỀU cả buổi, chỉ thưa hơn.
    ///
    /// 🔴 CHỐNG CHÙM BẰNG THỜI GIAN, KHÔNG BẰNG BỘ ĐẾM TRỌN ĐỜI. iOS bắn cảnh báo theo CHÙM
    /// (nhiều lần trong vài trăm mili giây của cùng một đợt áp lực), nhưng một buổi quét 25
    /// phút có thể gặp NHIỀU đợt. Bản vá đời trước dùng bộ đếm trọn đời chặn ở 2 nấc: chùm
    /// ĐẦU TIÊN nuốt sạch ngân sách trong chưa đầy một giây, rồi kho khung mọc lại đủ 320
    /// (358MB) mà van đã CHẾT VĨNH VIỄN — nên đúng cửa sổ nguy hiểm nhất (hoàn tất video
    /// H.264 ở cuối buổi) thì không còn gì để xả.
    /// Van tự giới hạn nhờ SÀN: từ kho đầy, xả tối đa HAI nấc rồi chạm sàn và dừng hẳn
    /// (Siêu nét 320 → 160 → 80; Nét 160 → 80 → 40). Nấc thứ hai KHÔNG cần kho mọc lại — chỉ
    /// cần qua thời gian chờ — vì 160 vẫn thoả sàn 80. Muốn xả tiếp nữa thì mới phải chờ kho
    /// mọc lại, và ở nhịp chụp đã nhân đôi thì việc đó tốn nhiều phút.
    ///
    /// 🔴 SÀN ĐO Ở TRẠNG THÁI SAU KHI XẢ, KHÔNG PHẢI TRƯỚC. Đời trước kiểm `count > sàn`
    /// rồi mới chia đôi: 81 khung vẫn qua được sàn 80 và tụt còn 41 — thấp hơn chính cái sàn
    /// vừa kiểm. Ở preset RoomPlan (40 khung) nó còn tụt xuống 5, phá luôn cam kết "không
    /// dưới 8 khung".
    private func relieveMemoryPressure() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMemoryRelief >= Self.memoryReliefCooldown else { return }
        // Sàn: sau khi xả vẫn phải còn ít nhất 1/4 hạn mức của mức nét đang chọn, và không
        // dưới 8 khung.
        guard keyframes.count / 2 >= max(8, maxKeyframes / 4) else { return }
        lastMemoryRelief = now
        keyframes = stride(from: 0, to: keyframes.count, by: 2).map { keyframes[$0] }
        keyframeIntervalSec *= 2
    }

    deinit {
        if let memoryWarning {
            NotificationCenter.default.removeObserver(memoryWarning)
        }
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
        var blockedThisPass = false
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
            let oldCount = pieces[mesh.identifier]?.worldVertices.count ?? 0
            if strictVertexCap {
                // TRẦN đỉnh CHẶT — áp cho CẢ anchor mới LẪN anchor phình to khi cập nhật.
                // (Bug cũ: update được vượt trần vô hạn → tổng bị GHIM trên trần → mỗi lần
                // ARKit gộp anchor là mất vĩnh viễn một mảng ĐÃ QUÉT: bản cũ bị dọn ở trên,
                // bản thay thế bị chặn ở đây. Giờ tổng không vượt trần nên chỗ ARKit giải
                // phóng THƯỜNG đủ cho bản thay thế — vẫn có thể hụt nếu bản thay thế dày
                // đặc hơn hẳn phần vừa nhả, khi đó banner + lưới đỏ báo cho người quét.)
                // Anchor bị chặn KHÔNG ghi chữ ký — tick sau tự thử lại, có chỗ là vào ngay;
                // bản cũ (nếu có) giữ nguyên.
                if count > oldCount && vertexTotal - oldCount + count > maxVertices {
                    capReached = true
                    blockedThisPass = true
                    continue
                }
            } else if pieces[mesh.identifier] == nil && vertexTotal >= maxVertices {
                // Luồng RoomPlan: hành vi CŨ nguyên vẹn — chỉ chặn anchor MỚI khi đã đầy,
                // update anchor cũ phình tự do (PLY 120k là tư liệu phụ, cross-check tường
                // và meshCapped của báo cáo chất lượng đã hiệu chỉnh theo ngữ nghĩa này).
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
        blockedNewAnchor = blockedThisPass
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
        guard srcW > 1, srcH > 1, // tap 2×2 cần biên ≥2px
              let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
        let cPtr = cBase.assumingMemoryBound(to: UInt8.self)

        let tw = min(keyframeWidth, srcW)
        let th = max(1, Int((Float(tw) * Float(srcH) / Float(srcW)).rounded()))
        var rgb = [UInt8](repeating: 0, count: tw * th * 3)

        // Hệ số YCbCr→RGB đọc từ attachment của buffer: camera iPhone thường gắn BT.709 —
        // trước đây dùng cứng BT.601 làm màu lệch nhẹ. Không có attachment → giữ 601 như cũ.
        let matrixRef = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil)
        let is709 = matrixRef.map { CFEqual($0, kCVImageBufferYCbCrMatrix_ITU_R_709_2) } ?? false
        let rCr: Float = is709 ? 1.5748 : 1.402
        let gCb: Float = is709 ? 0.1873 : 0.344136
        let gCr: Float = is709 ? 0.4681 : 0.714136
        let bCb: Float = is709 ? 1.8556 : 1.772

        for ty in 0..<th {
            let sy = min(srcH - 2, ty * srcH / th)
            for tx in 0..<tw {
                let sx = min(srcW - 2, tx * srcW / tw)
                // Trung bình 2×2 luma (thay nearest) — 1920→640 kiểu nearest tạo răng
                // cưa/nhiễu hạt trên màu đỉnh; 4 tap là đủ mượt mà vẫn rẻ cho main thread.
                let r0 = sy * yStride + sx
                let r1 = (sy + 1) * yStride + sx
                let ySum = Int(yPtr[r0]) + Int(yPtr[r0 + 1]) + Int(yPtr[r1]) + Int(yPtr[r1 + 1])
                let y = Float(ySum) * 0.25
                let ci = (sy / 2) * cStride + (sx / 2) * 2
                let cb = Float(cPtr[ci]) - 128
                let cr = Float(cPtr[ci + 1]) - 128
                let o = (ty * tw + tx) * 3
                rgb[o] = clampByte(y + rCr * cr)
                rgb[o + 1] = clampByte(y - gCb * cb - gCr * cr)
                rgb[o + 2] = clampByte(y + bCb * cb)
            }
        }

        // Depth LiDAR đi kèm khung màu (cùng hướng/FOV, ~256×192) — nguyên liệu cho kiểm
        // tra che khuất lúc gán màu. Chỉ lấy khi được bật TƯỜNG MINH (mesh mode) — luồng
        // RoomPlan dù có sceneDepth nội bộ cũng không dùng, giữ nguyên hành vi màu cũ.
        var depth: [Float] = []
        var dw = 0
        var dh = 0
        if captureDepthForOcclusion,
           let depthMap = frame.sceneDepth?.depthMap,
           CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32,
           CVPixelBufferLockBaseAddress(depthMap, .readOnly) == kCVReturnSuccess {
            if let dBase = CVPixelBufferGetBaseAddress(depthMap) {
                let w = CVPixelBufferGetWidth(depthMap)
                let h = CVPixelBufferGetHeight(depthMap)
                let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
                if w > 0, h > 0, rowBytes >= w * 4 {
                    var buf = [Float](repeating: 0, count: w * h)
                    buf.withUnsafeMutableBytes { dst in
                        guard let dstBase = dst.baseAddress else { return }
                        for row in 0..<h {
                            memcpy(dstBase + row * w * 4, dBase + row * rowBytes, w * 4)
                        }
                    }
                    depth = buf
                    dw = w
                    dh = h
                }
            }
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }

        let kf = ColorFrame(
            rgb: rgb, w: tw, h: th, srcW: Float(srcW), srcH: Float(srcH),
            transform: frame.camera.transform, intrinsics: frame.camera.intrinsics,
            depth: depth, dw: dw, dh: dh
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

    /// Anchor nào ĐÃ nằm trong dữ liệu xuất, kèm SỐ ĐỈNH đã ghi — MeshOverlayView so với
    /// số đỉnh đang hiển thị để tô lưới trung thực (anchor phình to bị trần chặn có ID
    /// trùng nhưng bản trong file NHỎ hơn bản trên màn → phải tô đỏ chứ không trắng).
    /// Đọc trên main, cùng luồng với tick.
    var recordedAnchorCounts: [UUID: Int] {
        pieces.mapValues { $0.worldVertices.count }
    }

    /// Lượt gom CHỐT SỔ ngay trước khi export: tick chỉ chạy 2–5Hz nên nửa giây mesh cuối
    /// (vùng vừa quét ngay trước khi bấm Dừng & Lưu) có thể chưa vào pieces. CHỈ gom khi
    /// tracking đang normal — frame cuối của phiên lệch tọa độ sẽ phá mesh thay vì cứu nó.
    func ingestFinalFrame() {
        guard let frame = arSession?.currentFrame else { return }
        if case .normal = frame.camera.trackingState {
            ingestMesh(from: frame)
            // Chụp thêm khung màu CHỐT cho đúng khu vực cuối — không thì mesh vừa cứu
            // được dễ ra màu xám/màu mượn từ khung cũ chụp chỗ khác.
            lastKeyframeTime = 0
            maybeCaptureColorFrame(from: frame)
        }
    }

    // MARK: - Xuất PLY màu (gọi khi kết thúc; nặng nên chạy nền)

    /// Trả về URL file .ply (màu) hoặc nil nếu không dựng được (không có lưới / lỗi).
    /// Kho khung màu của MỘT lần xuất, giữ trong một hộp THAM CHIẾU.
    ///
    /// 🔴 PHẢI LÀ `class`, ĐỪNG "DỌN" THÀNH HAI THAM SỐ MẢNG. Bản vá đời đầu (2026-07-29)
    /// truyền thẳng hai mảng vào `buildPLY` rồi gán `[]` ở giữa hàm để "nhả sớm" — VÔ HIỆU
    /// HOÀN TOÀN: closure escaping của `queue.async` bên dưới giữ tham chiếu RIÊNG suốt thời
    /// gian `buildPLY` chạy, nên gán `[]` chỉ hạ số đếm tham chiếu từ 2 xuống 1 và không giải
    /// phóng một byte nào. Nguy hiểm gấp đôi vì comment lúc đó lại KHẲNG ĐỊNH là đã nhả —
    /// người truy jetsam sau này sẽ gạch ColorMeshBuilder khỏi danh sách nghi vấn oan.
    /// Với hộp: closure giữ CON TRỎ hộp, mảng nằm trong trường của hộp, nên dọn trường là số
    /// đếm về 0 thật. (Review đối kháng bắt được, 6 lens độc lập cùng chỉ vào.)
    /// `@unchecked Sendable` là đúng sự thật chứ không phải để bịt cảnh báo: hộp được dựng
    /// trên main rồi TRAO HẲN cho `queue`, và main không đụng lại nó nữa. Từ lúc trao đi, chỉ
    /// một luồng duy nhất đọc/ghi. Ai thêm chỗ đọc hộp này từ main sau khi trao thì lời khai
    /// đó thành sai — phải chuyển sang khoá thật.
    private final class SamplerStore: @unchecked Sendable {
        var geos: [SamplerGeo]
        var samplers: [KeyframeSampler]
        init(geos: [SamplerGeo], samplers: [KeyframeSampler]) {
            self.geos = geos
            self.samplers = samplers
        }
    }

    /// 🔴 `@MainActor` BẮT BUỘC, ĐỪNG GỠ. Đây là hàm `async` nên theo SE-0338 nó KHÔNG thừa
    /// hưởng actor của nơi gọi (`MeshScanController.stopAndExport`, vốn đã là @MainActor) —
    /// không gắn nhãn thì thân hàm chạy trên luồng nền chung. Mà thân hàm này vừa GHI
    /// `self.keyframes` vừa gọi `stop()` (invalidate CADisplayLink đã gắn vào main), trong khi
    /// van xả bộ nhớ (`relieveMemoryPressure`) cũng ghi `self.keyframes` trên main → tranh chấp
    /// dữ liệu thật sự, kiểu chỉ nổ ở máy khách vào đúng lúc iOS kêu thiếu bộ nhớ.
    /// Phần NẶNG không hề chạy trên main: nó nằm trong `queue.async` bên dưới. Phần chạy trên
    /// main chỉ là dựng sampler — O(K) phép nghịch đảo 4×4, cỡ vài chục micro giây.
    ///
    /// `geometryOnly` = ĐƯỜNG LƯU NHANH (chỉ khi buổi quét đã có đủ ảnh texture cho máy
    /// trạm — `MeshScanController.stopAndExport` quyết định). Bỏ TOÀN BỘ phần đắt: chia nhỏ
    /// tam giác, bake màu (400–800 TRIỆU vòng lọc), vá đỉnh xám. Đỉnh vẫn có màu XÁM HẰNG SỐ
    /// chứ không phải mảng rỗng — xem `uncoloredGrey`.
    /// Bonus RAM: không cần kho khung màu nên nó chết NGAY (179MB mức Nét / 358MB Siêu nét)
    /// trước khi cấp phát `Data` của PLY.
    @MainActor
    func exportColoredPLY(geometryOnly: Bool = false) async -> URL? {
        stop()
        let pieces = self.pieces
        let refine = refineLargeTriangles && !geometryOnly
        let fill = fillUncoloredVertices && !geometryOnly
        guard !pieces.isEmpty else { return nil }
        // ✗ đòi keyframes ở đường lưu nhanh: nó KHÔNG đọc kho khung nào. Giữ vế này cho
        // đường cũ thì mất mesh khi mọi khung màu bị van xả RAM dọn sạch.
        guard geometryOnly || !keyframes.isEmpty else { return nil }

        // Dựng sampler NGAY TẠI ĐÂY (rẻ: O(K), một phép nghịch đảo 4×4 mỗi khung) rồi THẢ
        // `self.keyframes`. Mảng `ColorFrame` chết đi, còn bộ nhớ ảnh thật (rgb/depth) vẫn
        // sống vì sampler giữ tham chiếu — đó là thứ vòng bake cần. Kho ảnh này là khối lớn
        // nhất của cả quy trình lưu (179MB mức Nét, 358MB mức Siêu nét) nên nó phải chết
        // TRƯỚC khi cấp phát vùng `Data` của file PLY — xem `SamplerStore` và `buildPLY`.
        let store = geometryOnly
            ? SamplerStore(geos: [], samplers: [])
            : SamplerStore(
                geos: Self.makeGeos(keyframes),
                samplers: Self.makeSamplers(keyframes)
            )
        keyframes = []

        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            queue.async {
                let url = Self.buildPLY(
                    pieces: pieces, store: store,
                    refineLargeTriangles: refine, fillUncoloredVertices: fill,
                    geometryOnly: geometryOnly
                )
                continuation.resume(returning: url)
            }
        }
    }

    /// Dữ liệu chiếu tính sẵn một lần cho mỗi khung (hoist `simd_inverse` + intrinsics ra
    /// khỏi vòng lặp: trước đây bị tính lại cho TỪNG đỉnh × TỪNG khung, hàng chục triệu lần thừa).
    private static func makeSamplers(_ keyframes: [ColorFrame]) -> [KeyframeSampler] {
        keyframes.map { kf in
            KeyframeSampler(
                rgb: kf.rgb, w: kf.w, h: kf.h, srcW: kf.srcW, srcH: kf.srcH,
                camPos: SIMD3(kf.transform.columns.3.x, kf.transform.columns.3.y, kf.transform.columns.3.z),
                worldToCamera: simd_inverse(kf.transform),
                fx: kf.intrinsics.columns.0.x,
                fy: kf.intrinsics.columns.1.y,
                cx: kf.intrinsics.columns.2.x,
                cy: kf.intrinsics.columns.2.y,
                depth: kf.depth, dw: kf.dw, dh: kf.dh
            )
        }
    }

    /// Bản POD song song với `makeSamplers` cho vòng lọc nóng — xem chú ở `SamplerGeo`.
    /// ⚠ PHẢI map trên CÙNG mảng `keyframes` theo CÙNG thứ tự: chỉ số dùng chung giữa hai mảng.
    private static func makeGeos(_ keyframes: [ColorFrame]) -> [SamplerGeo] {
        keyframes.map { kf in
            SamplerGeo(
                srcW: kf.srcW, srcH: kf.srcH,
                camPos: SIMD3(kf.transform.columns.3.x, kf.transform.columns.3.y, kf.transform.columns.3.z),
                worldToCamera: simd_inverse(kf.transform),
                fx: kf.intrinsics.columns.0.x,
                fy: kf.intrinsics.columns.1.y,
                cx: kf.intrinsics.columns.2.x,
                cy: kf.intrinsics.columns.2.y,
                dw: kf.dw, dh: kf.dh
            )
        }
    }

    private static func buildPLY(
        pieces: [UUID: MeshPiece], store: SamplerStore,
        refineLargeTriangles: Bool, fillUncoloredVertices: Bool,
        geometryOnly: Bool = false
    ) -> URL? {
        // Gộp lưới thành 1 mảng đỉnh + mặt (dời chỉ số).
        //
        // Duyệt theo THỨ TỰ ĐÃ SẮP của khoá thay vì `pieces.values`: thứ tự Dictionary của
        // Swift không xác định, nên lưu hai lần cùng một bản quét cho ra hai file khác nhau về
        // thứ tự đỉnh. Sắp vài trăm–vài nghìn UUID tốn dưới 1ms, đổi lại khi so hai bản export
        // thì khác biệt đến từ THAY ĐỔI CODE chứ không từ may rủi — cần đúng cho việc nghiệm
        // thu màu của đợt này. (Thứ tự này cũng quyết định mặt nào được chia trước khi
        // `refineVertexCeiling` chạm trần — hôm nay trần đang ngủ, nhưng ai hạ
        // `refineEdgeThreshold` trong tương lai thì nợ luôn phần ưu tiên chia theo cạnh dài.)
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var faces: [(UInt32, UInt32, UInt32)] = []
        for key in pieces.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let piece = pieces[key] else { continue }
            let base = UInt32(vertices.count)
            vertices.append(contentsOf: piece.worldVertices)
            normals.append(contentsOf: piece.worldNormals)
            for f in piece.faces {
                faces.append((f.0 + base, f.1 + base, f.2 + base))
            }
        }
        guard !vertices.isEmpty, !faces.isEmpty else { return nil }

        // Chia nhỏ tam giác lớn TRƯỚC vòng bake màu (chỉ chế độ Mesh bật cờ): thêm đỉnh
        // = thêm "điểm ảnh" màu trên mảng phẳng lớn. Vòng sampleColor bên dưới chạy
        // Y NGUYÊN trên danh sách đỉnh mới — occlusion test + bilinear áp cho cả đỉnh chia.
        if refineLargeTriangles {
            subdivideLargeTriangles(vertices: &vertices, normals: &normals, faces: &faces)
        }

        // Tô màu trong MỘT LỜI GỌI RIÊNG. Đây không phải chuyện chia nhỏ hàm cho đẹp: mọi tham
        // chiếu TẠM tới kho khung màu chỉ sống trong khung ngăn xếp của `paintColors`, nên khi
        // nó trả về thì `store` là nơi DUY NHẤT còn giữ kho — dọn hai trường ngay sau đó mới
        // thật sự trả bộ nhớ về hệ điều hành.
        // 🔴 ĐƯỜNG LƯU NHANH vẫn phải cấp mảng màu ĐỦ ĐỘ DÀI, không được để rỗng: PLY dưới
        // đây ghi 15 byte/đỉnh (12 vị trí + 3 RGB) và `ColoredMeshPLY.parse` ĐÒI đúng bố cục
        // đó; `ColoredOBJExporter.writeOBJ` thì đọc `mesh.colors[k]` cho MỌI đỉnh → mảng rỗng
        // là CRASH ngoài tầm do/catch, ngay sau buổi quét 10–30 phút. Màu hằng số nén rất tốt
        // nên zip vẫn nhẹ đi nhiều dù OBJ vẫn ghi 6 số mỗi đỉnh.
        let colors = geometryOnly
            ? [SIMD3<UInt8>](repeating: uncoloredGrey, count: vertices.count)
            : paintColors(
                vertices: vertices, normals: normals, faces: faces,
                geos: store.geos, samplers: store.samplers,
                fillUncoloredVertices: fillUncoloredVertices
            )

        // 🔴 NHẢ KHO KHUNG MÀU NGAY TẠI ĐÂY — TRƯỚC khi cấp phát `Data` của PLY (~102MB ở 2,5
        // triệu đỉnh). Đây là đỉnh RAM của cả quy trình lưu, và kho khung là khối lớn nhất
        // trong đó (179MB mức Nét / 358MB mức Siêu nét).
        // ⚠ ĐỪNG đưa hai dòng này vào TRONG `paintColors`: ở đó chúng lại chỉ hạ số đếm tham
        // chiếu chứ không giải phóng, đúng cái bẫy đã tả ở `SamplerStore`.
        store.samplers = []
        store.geos = []

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

    /// Xám của đỉnh CHƯA lấy được màu — và của TOÀN BỘ mesh ở đường lưu nhanh
    /// (`exportColoredPLY(geometryOnly:)`). MỘT hằng số cho cả hai đường để đội vẽ mở file
    /// không phải đoán tông nào là "chưa có màu".
    static let uncoloredGrey = SIMD3<UInt8>(150, 150, 150)

    // MARK: - Chia nhỏ tam giác lớn (cờ refineLargeTriangles — chỉ chế độ Mesh)

    /// Cạnh dài hơn mức này (mét) thì tam giác bị chia. 7cm = giữa khoảng 6–8cm đã chốt,
    /// và TRÊN mật độ mesh thường của ARKit (~4–6cm) để không chia đại trà cả mô hình —
    /// chỉ các mảng phẳng ARKit đã gộp (tường/sàn/mặt bàn) mới dính.
    private static let refineEdgeThreshold: Float = 0.07
    /// Tối đa 2 lượt chia (1 tam giác → tối đa 16): cạnh 28cm về ~7cm là đủ cho màu
    /// per-vertex; sâu hơn chỉ tốn đỉnh + thời gian bake mà mắt không thấy khác.
    private static let refineMaxPasses = 2
    /// Van an toàn RAM + kích thước file: NGỪNG chia khi tổng đỉnh chạm mức này
    /// (giữa khoảng 4–5M đã chốt; PLY trung gian ~200MB, zip OBJ+GLB vẫn <~200MB).
    /// Tam giác chưa kịp chia khi chạm van chỉ kém nét màu cục bộ — hình học không đổi.
    private static let refineVertexCeiling = 4_500_000

    /// Midpoint-subdivide 1→4 các tam giác có cạnh dài quá ngưỡng, để màu per-vertex có
    /// đủ "điểm ảnh" trên mảng phẳng lớn. CHỈ THÊM đỉnh tại TRUNG ĐIỂM cạnh — tuyệt đối
    /// không dịch chuyển/smooth hình học. Trung điểm DÙNG CHUNG giữa 2 tam giác kề
    /// (map cạnh→chỉ số): hai bên cạnh lấy CÙNG một đỉnh màu — không thì nứt màu dọc cạnh.
    /// Chạy trên queue nền của exportColoredPLY (một lần, trước bake màu).
    private static func subdivideLargeTriangles(
        vertices: inout [SIMD3<Float>],
        normals: inout [SIMD3<Float>],
        faces: inout [(UInt32, UInt32, UInt32)]
    ) {
        let thresholdSq = refineEdgeThreshold * refineEdgeThreshold
        for _ in 0..<refineMaxPasses {
            if vertices.count >= refineVertexCeiling { return }
            // Cạnh (min,max) → chỉ số trung điểm đã tạo trong lượt này.
            var midpointForEdge: [UInt64: UInt32] = [:]
            var out: [(UInt32, UInt32, UInt32)] = []
            out.reserveCapacity(faces.count)
            var didSplit = false

            // Nested func gọi tại chỗ (không escape) nên được phép chạm inout ở trên.
            func midpoint(_ a: UInt32, _ b: UInt32) -> UInt32 {
                let key = a < b
                    ? (UInt64(a) << 32) | UInt64(b)
                    : (UInt64(b) << 32) | UInt64(a)
                if let existing = midpointForEdge[key] { return existing }
                let idx = UInt32(vertices.count)
                vertices.append((vertices[Int(a)] + vertices[Int(b)]) * 0.5)
                // Normal trung điểm = trung bình CHUẨN HÓA hai đầu; hai normal gần đối
                // nhau (tổng ~0) thì lấy normal đầu a — không để vector 0/NaN lọt vào
                // facing test của sampleColor.
                let sum = normals[Int(a)] + normals[Int(b)]
                let len = simd_length(sum)
                normals.append(len > 1e-5 ? sum / len : normals[Int(a)])
                midpointForEdge[key] = idx
                return idx
            }

            for f in faces {
                // Chốt chống index rác: trước đây chỉ số mặt chỉ đi thẳng ra file, giờ
                // mới có chỗ dùng nó truy mảng — index hỏng từ buffer ARKit không được
                // phép crash lúc lưu (mất cả bản quét). Đỉnh chia luôn hợp lệ do tự tạo.
                let n = UInt32(vertices.count)
                guard f.0 < n, f.1 < n, f.2 < n else {
                    out.append(f)
                    continue
                }
                let a = vertices[Int(f.0)]
                let b = vertices[Int(f.1)]
                let c = vertices[Int(f.2)]
                let longestSq = max(
                    simd_length_squared(a - b),
                    max(simd_length_squared(b - c), simd_length_squared(c - a))
                )
                if longestSq > thresholdSq, vertices.count + 3 <= refineVertexCeiling {
                    let ab = midpoint(f.0, f.1)
                    let bc = midpoint(f.1, f.2)
                    let ca = midpoint(f.2, f.0)
                    out.append((f.0, ab, ca))
                    out.append((ab, f.1, bc))
                    out.append((ca, bc, f.2))
                    out.append((ab, bc, ca))
                    didSplit = true
                } else {
                    out.append(f)
                }
            }
            faces = out
            if !didSplit { return }
        }
    }

    /// Phần HÌNH HỌC của một khung màu — thuần số, KHÔNG chứa tham chiếu (`Array`).
    ///
    /// 🔴 TÁCH RA LÀM GÌ: vòng lọc trong `sampleColor` chạy V×K lần (2,5 triệu đỉnh × 320
    /// khung = 800 TRIỆU lần ở mức Siêu nét). Nếu vòng đó đọc nguyên `KeyframeSampler` —
    /// struct có 2 tham chiếu Array — thì mỗi lần lặp là một cặp retain/release tiềm tàng,
    /// và 6 luồng `concurrentPerform` sẽ đập atomic lên CÙNG hai bộ đếm tham chiếu. Struct
    /// POD này không thể sinh ARC dù trình tối ưu có làm gì đi nữa. Ảnh (`rgb`/`depth`) chỉ
    /// được chạm khi một khung đã lọt vào tốp — khoảng 12 lần/đỉnh thay vì K lần.
    /// ⚠ `geos[i]` và `samplers[i]` PHẢI cùng thứ tự và cùng độ dài: hai hàm `makeGeos` và
    /// `makeSamplers` cùng `map` trên MỘT mảng `keyframes` nên chỉ số khớp theo cách dựng.
    /// Đừng lọc/sắp/thêm/bớt riêng một mảng — chỉ số lệch là màu lấy từ khung khác.
    private struct SamplerGeo {
        let srcW: Float
        let srcH: Float
        let camPos: SIMD3<Float>
        let worldToCamera: simd_float4x4
        let fx: Float
        let fy: Float
        let cx: Float
        let cy: Float
        let dw: Int
        let dh: Int
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
        let depth: [Float]
        let dw: Int
        let dh: Int
    }

    /// Chiếu đỉnh vào các khung màu, chọn khung tốt nhất (nhìn thẳng + GẦN), lấy RGB.
    /// CÓ KIỂM TRA CHE KHUẤT bằng depth map LiDAR của từng khung (khi phiên bật .sceneDepth):
    /// đỉnh bị vật khác chắn giữa nó và camera sẽ KHÔNG lấy màu từ khung đó — hết cảnh màu
    /// ghế salon "in" lên mặt bàn phía sau. Khung không có depth (luồng RoomPlan) giữ hành vi cũ.
    /// Trả nil khi KHÔNG khung nào qua bộ lọc (caller quyết: xám 150 hoặc đưa vào lượt vá).
    /// relaxed=true (lượt vét cho đỉnh đã hỏng): chấp nhận góc xiên (facing>0) — KHÔNG
    /// dùng cho lượt chuẩn. skipOcclusion=true chỉ dành cho nấc vét CUỐI: bỏ occlusion
    /// test là bất đắc dĩ (khung bị che có thể thắng khung sạch → màu vật chắn in lên
    /// mặt sau), nên nấc 1 luôn GIỮ occlusion, chỉ đỉnh vẫn hỏng mới sang nấc 2.
    private static func sampleColor(
        world: SIMD3<Float>, normal: SIMD3<Float>,
        geos: [SamplerGeo], samplers: [KeyframeSampler],
        relaxed: Bool = false, skipOcclusion: Bool = false
    ) -> SIMD3<UInt8>? {
        // Ba ứng viên tốt nhất thay vì một (xem giải thích ở phần trộn bên dưới).
        var idx0 = -1, idx1 = -1, idx2 = -1
        var s0: Float = -1, s1: Float = -1, s2: Float = -1
        var x0: Float = 0, y0: Float = 0
        var x1: Float = 0, y1: Float = 0
        var x2: Float = 0, y2: Float = 0
        let minFacing: Float = relaxed ? 0 : 0.1

        for k in geos.indices {
            let g = geos[k]
            let toCamRaw = g.camPos - world
            let dist = simd_length(toCamRaw)
            if dist < 0.05 { continue } // trùng vị trí camera → chiếu vô nghĩa
            let facing = simd_dot(normal, toCamRaw / dist)
            if facing <= minFacing { continue } // quay lưng với camera → bỏ
            // Điểm = độ nhìn thẳng / khoảng cách.
            //
            // ĐỔI TỪ `sqrtf(dist)` SANG `dist` (2026-07-29): dấu chân của một pixel trên bề
            // mặt lớn theo BÌNH PHƯƠNG khoảng cách, nên khung ở 4m bệt hơn khung ở 1m gấp 16
            // lần về diện tích — phạt bằng căn (chỉ 2×) là quá nhẹ. Tệ hơn: occlusion test chỉ
            // được tin trong tầm 5m (xem dưới), nên khung XA vừa bệt màu vừa nằm NGOÀI vùng
            // bảo vệ chống che khuất. Dòng này chỉ đổi khung nào THẮNG, không đổi việc đỉnh có
            // lấy được màu hay không (mọi bộ lọc loại/nhận đều nằm ngoài nó) → không thể đẻ
            // thêm một đỉnh xám nào. Nếu so ảnh trên máy thật thấy hồi quy thì đây là dòng
            // ĐẦU TIÊN nên revert, nó cô lập hoàn toàn.
            let score = facing / max(dist, 0.5)
            if score <= s2 { continue } // không lọt nổi tốp 3 → khỏi chiếu

            // Đưa về hệ camera (camera nhìn theo -Z)
            let cs4 = g.worldToCamera * SIMD4<Float>(world.x, world.y, world.z, 1)
            let z = cs4.z
            if z >= -0.05 { continue } // sau lưng hoặc quá sát

            // Ảnh gốc: origin trên-trái, x phải, y xuống
            let xImg = g.cx + g.fx * (cs4.x / -z)
            let yImg = g.cy + g.fy * (cs4.y / z)
            guard xImg >= 0, yImg >= 0, xImg < g.srcW, yImg < g.srcH else { continue }

            // KIỂM TRA CHE KHUẤT: depth map cho biết bề mặt GẦN NHẤT ở pixel này cách camera
            // bao xa; đỉnh nằm sâu hơn mức đó (quá dung sai) tức là có vật chắn → bỏ khung.
            // Chỉ tin depth trong tầm LiDAR (~5m); dung sai nới theo khoảng cách vì depth
            // 256px thô hơn mesh nhiều (mép vật hay lệch vài cm). Chỉ nấc vét CUỐI
            // (skipOcclusion) mới bỏ qua — occlusion loại nhầm ở mép vật gây đỉnh xám.
            if !skipOcclusion, g.dw > 0, g.dh > 0 {
                let dx = min(g.dw - 1, Int(xImg * Float(g.dw) / g.srcW))
                let dy = min(g.dh - 1, Int(yImg * Float(g.dh) / g.srcH))
                let d = samplers[k].depth[dy * g.dw + dx]
                if d.isFinite, d > 0.05, d < 5.0, -z > d + 0.10 + 0.05 * d { continue }
            }

            // Chèn vào tốp 3 (giữ thứ tự giảm dần).
            if score > s0 {
                s2 = s1; idx2 = idx1; x2 = x1; y2 = y1
                s1 = s0; idx1 = idx0; x1 = x0; y1 = y0
                s0 = score; idx0 = k; x0 = xImg; y0 = yImg
            } else if score > s1 {
                s2 = s1; idx2 = idx1; x2 = x1; y2 = y1
                s1 = score; idx1 = k; x1 = xImg; y1 = yImg
            } else {
                s2 = score; idx2 = k; x2 = xImg; y2 = yImg
            }
        }
        guard idx0 >= 0 else { return nil }

        // ---- TRỘN TỐP 3 thay vì lấy trọn khung thắng ----
        //
        // 🔴 BỆNH ĐANG CHỮA: `score` là hàm LIÊN TỤC theo vị trí đỉnh, nên trên một mảng tường
        // phẳng, khung thắng đổi dọc theo một ĐƯỜNG CONG. Hai khung kề nhau chụp cách nhau
        // 6–13 giây từ hai chỗ đứng khác nhau thì phơi sáng/cân bằng trắng tự động của camera
        // đã lệch 1–2 EV → mắt thấy một ĐƯỜNG NỐI SẮC CẠNH nơi màu nhảy bậc. Đó chính là kiểu
        // "loang lổ như vá áo" mà người xem thấy rõ nhất, và nó KHÔNG liên quan gì tới độ nét.
        // Trộn có trọng số làm đường nhảy bậc đó thành chuyển dần. Phụ thu: nhiễu hạt giảm
        // ~√3, và sai lệch do ARKit dời anchor sau loop closure chuyển từ "một mảng màu SAI
        // hẳn" thành "hơi nhoè".
        //
        // 🔴 TRỌNG SỐ TẮT DẦN, TUYỆT ĐỐI KHÔNG DÙNG CỔNG BẬT/TẮT. Bản vá đời đầu dùng hai cổng
        // nhị phân (điểm ≥ 0,6 lần khung nhất VÀ lệch màu ≤ 48/255) và hỏng hai đường cùng lúc
        // — review đối kháng bắt được:
        //  1. Ngưỡng lệch màu 48 rơi ĐÚNG vào biên độ của chính căn bệnh cần chữa. Quy 1 EV ra
        //     giá trị hiển thị: tông xám giữa 128 → 176 (lệch 48, sát trần), tông sáng 180 →
        //     245 (lệch 65 → BỊ LOẠI), 2 EV ở xám giữa → lệch 111 (BỊ LOẠI). Tức nó từ chối
        //     đúng những ca đường nối lộ rõ nhất, chỉ trộn khi hai khung vốn đã gần giống nhau.
        //  2. Cổng nhị phân TỰ ĐẺ một bậc màu MỚI ngay tại đường cắt: một ứng viên vừa đủ điều
        //     kiện nhảy vào với trọng số ~26–50% tức thì, tạo bậc tới ~70/255 trên một kênh,
        //     chạy men theo bóng vật. Dời ngưỡng chỉ dời chỗ nhảy chứ không xoá nó.
        // Nay cả hai đều là dốc mượt (`ramp`), và DẢI TRỘN CỐ Ý HẸP.
        //
        // 🔴 PHẠM VI THẬT — ĐỌC KỸ TRƯỚC KHI CHỈNH HAI MỐC 0,75/0,95. Trên mảng phẳng, tỉ số
        // điểm giữa khung lệch ngang `b` và khung đứng vuông góc cách `d` là 1/(1+(b/d)²).
        // Suy ra: khung tham gia TRỌN VẸN khi b ≤ 0,23·d, và không tham gia gì khi b ≥ 0,58·d.
        // Tức trộn chỉ xảy ra quanh chỗ HAI KHUNG NGANG TÀI — đúng nơi khung thắng đổi và
        // đường nối màu hình thành — chứ không phải cả mô hình.
        // ⚠ Đời đầu của bản vá đặt 0,45/0,80: khi đó khung lệch tới 1,1·d vẫn tham gia, tức
        // gần như MỌI đỉnh đều bị trộn ba khung và khung thắng chỉ còn ~40% trọng số → cả mô
        // hình mềm đi (nhoè theo sai số pose của ARKit sau loop closure), đúng thứ mà mức
        // Siêu nét đang bán thì lại mất. Review đối kháng bắt được bằng cách giải dạng đóng.
        //
        // ⚠ KHÔNG khẳng định "giống hệt bản cũ ở vùng thắng rõ": hàm ĐIỂM cũng đổi trong đợt
        // này (bỏ sqrt), nên ngay cả nơi không trộn, khung THẮNG vẫn có thể là khung khác.
        // Muốn so từng bit thì phải so với chính bản này khi tắt trộn, không phải với bản cũ.
        //
        // ⚠ GIỚI HẠN ĐÃ BIẾT, chấp nhận có chủ đích: chỉ giữ 3 ứng viên nên khung hạng 4 bị cắt
        // CỨNG, và chỗ cắt đó sinh bậc màu (xem khối cảnh báo ở cuối hàm). Mở lên 5 ứng viên
        // chỉ dời chỗ cắt chứ không xoá, mà tốn thêm sổ đăng ký + 2 lần đọc ảnh mỗi đỉnh.
        let c0 = bilinearSample(samplers[idx0], x: x0, y: y0)
        let c0v = SIMD3<Float>(Float(c0.x), Float(c0.y), Float(c0.z))
        // Trọng số THEO ĐIỂM tính trước, và nó rẻ (vài phép toán): ở đại đa số đỉnh nó bằng 0
        // nên chặn luôn được việc đọc ảnh — `bilinearSample` là 4 lần truy cập bộ nhớ ngẫu
        // nhiên vào kho khung hàng trăm MB, đắt hơn nhiều so với phép so sánh này.
        // Khung THẮNG luôn có `ramp(…, 1) = 1` nên trọng số của nó đúng bằng s0².
        let w0 = s0 * s0
        var c1v = SIMD3<Float>(repeating: 0)
        var c2v = SIMD3<Float>(repeating: 0)
        var w1: Float = 0
        var w2: Float = 0
        let sw1 = scoreWeight(score: s1, best: s0)
        if idx1 >= 0, sw1 > 0 {
            let c = bilinearSample(samplers[idx1], x: x1, y: y1)
            c1v = SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z))
            w1 = sw1
        }
        let sw2 = scoreWeight(score: s2, best: s0)
        if idx2 >= 0, sw2 > 0 {
            let c = bilinearSample(samplers[idx2], x: x2, y: y2)
            c2v = SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z))
            w2 = sw2
        }

        // 🔴 KHÔNG CÓ CỔNG LỌC "LỆCH MÀU". ĐỪNG THÊM LẠI — ĐÃ THỬ BA KIỂU, CẢ BA ĐỀU HỎNG:
        //  1. Cổng nhị phân "lệch ≤ 48/255 mới được trộn": ngưỡng rơi đúng vào biên độ chênh
        //     phơi sáng 1–2 EV (48–111) tức từ chối đúng ca cần chữa, và tự đẻ bậc màu mới tại
        //     đường cắt.
        //  2. Dốc mượt nhưng đo lệch so với màu khung THẮNG, chỉ áp cho khung THUA: bất đối
        //     xứng, nên tại đường khung thắng đổi vai bộ trọng số nhảy từ (1,g) sang (g,1) —
        //     màu vẫn nhảy bậc ~47/255, chỉ giảm chứ không hết.
        //  3. Đo lệch so với TRUNG BÌNH có trọng số: đối xứng và liên tục thật, nhưng trung
        //     bình đó CHỨA chính ứng viên đang đo nên độ lệch đo được chỉ bằng một phần độ
        //     lệch thật → ngưỡng loại 150 thành bất khả đạt đúng trong dải trộn nặng. Tệ hơn:
        //     ba khung ngang tài mà HAI khung cùng sai (loá) thì mốc bị kéo theo phe đông, và
        //     khung ĐÚNG (điểm cao nhất) là kẻ bị loại — cơ chế chống ngoại lai tự lật ngược.
        // Nên bỏ hẳn. Lý lẽ: ứng viên chỉ vào được cuộc khi điểm của nó ≥ 0,75 lần khung thắng,
        // mà điểm đã gộp cả góc nhìn lẫn khoảng cách, và khung bị vật khác che đã bị loại từ
        // vòng kiểm che khuất phía trên. Ca xấu còn lại — một khung ngang tài nhìn trúng vật
        // khác — thì trộn vẫn ĐỠ HƠN bản gốc: trước đợt này nó thắng tuyệt đối ở khoảng nửa số
        // đỉnh quanh đó và in nguyên màu sai; giờ nó chỉ kéo màu đi một phần.
        //
        // ⚠ NÓI CHO ĐÚNG, ĐỪNG ĐỌC THÀNH "HẾT VIỀN": trọng số thì liên tục, nhưng TƯ CÁCH ứng
        // viên vẫn do các cổng NHỊ PHÂN quyết (facing, z, biên ảnh, kiểm che khuất) cộng phép
        // cắt cứng ở hạng 3. Băng qua bất kỳ cổng nào, một ứng viên rơi từ trọng số đầy xuống
        // 0 tức thì → vẫn còn bậc màu, chỉ nhỏ hơn (một phần ba tới một nửa) so với bậc 100%
        // của winner-take-all. Đổi lại, số ĐƯỜNG có bậc nhiều hơn vì nay cả ba ứng viên đều
        // có thể vào/ra. Tóm lại: NHIỀU VIỀN MỜ thay cho ÍT VIỀN SẮC — đó là đánh đổi có chủ
        // đích, không phải xoá sạch.
        //
        // ⚠ Phép cắt ở hạng 3 đẻ ra một họ bậc màu MỚI mà winner-take-all không có: khi khung
        // hạng 3 và hạng 4 hoán chỗ, trọng số slot đó KHÔNG tụt về 0 (hai điểm bằng nhau tại
        // chỗ hoán) mà chỉ đổi sang một khung màu khác → bậc bằng lệch màu chia 3. Đừng bào
        // chữa bằng câu "lúc đó ba khung đầu đã đủ giống nhau": giống về ĐIỂM (góc/khoảng cách)
        // không suy ra giống về MÀU — chênh phơi sáng 1–2 EV giữa hai khung cùng nhìn một chỗ
        // chính là tiền đề của cả cơ chế này. Ở mức Siêu nét (320 khung), đứng lại vài chục
        // giây trước một mảng tường là có ngay 5+ khung gần cùng tư thế, nên ca này KHÔNG hiếm.
        let wSum = w0 + w1 + w2      // > 0 vì w0 = s0² > 0
        let mixed = (c0v * w0 + c1v * w1 + c2v * w2) / wSum
        return SIMD3<UInt8>(
            UInt8(max(0, min(255, mixed.x.rounded()))),
            UInt8(max(0, min(255, mixed.y.rounded()))),
            UInt8(max(0, min(255, mixed.z.rounded())))
        )
    }

    /// Trọng số của một khung phụ khi trộn — CHỈ theo điểm, không xét màu (xem `sampleColor`).
    /// 0 = không tham gia; tính được mà KHÔNG cần đọc ảnh nên dùng làm cổng chặn
    /// `bilinearSample`, thứ đắt nhất trong hàm.
    private static func scoreWeight(score: Float, best: Float) -> Float {
        guard best > 0, score > 0 else { return 0 }
        return score * score * ramp(0.75, 0.95, score / best)
    }

    // `gapWeight` và `colorGap` ĐÃ GỠ (2026-07-29) — xem khối chú thích trong `sampleColor`
    // giải thích vì sao mọi kiểu cổng lọc lệch màu đều hỏng ở đây. Đừng dựng lại.

    /// Nội suy mượt Hermite: 0 dưới `a`, 1 trên `b`, không có bậc nhảy ở hai đầu.
    ///
    /// ⚠ TÊN CỐ Ý KHÔNG PHẢI `smoothstep`: module `simd` (đã import ở đầu file) xuất sẵn
    /// `smoothstep(_:_:_:)` với ĐÚNG ba tham số Float không nhãn. Khai một hàm trùng khuôn
    /// trong cùng file là đặt bẫy nhập nhằng cho người sửa sau — và ở repo này lỗi kiểu đó
    /// chỉ lộ ra sau 10 phút CI.
    private static func ramp(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }


    // MARK: - Tô màu toàn bộ đỉnh (bake + vá) — TÁCH HÀM CÓ CHỦ ĐÍCH

    /// Trả về mảng màu đã tô xong cho `vertices`.
    ///
    /// 🔴 VÌ SAO LÀ HÀM RIÊNG chứ không viết thẳng trong `buildPLY`: hai tham số `geos`/
    /// `samplers` được truyền theo kiểu MƯỢN, nên mọi tham chiếu tạm tới kho khung màu chết
    /// đúng lúc hàm này trả về. Nhờ vậy `buildPLY` dọn `store` ngay sau đó là giải phóng THẬT.
    /// Viết thẳng vào `buildPLY` thì các biến cục bộ sống tới cuối hàm và kho khung 179–358MB
    /// nằm lì qua bước cấp phát `Data` của PLY — đúng đỉnh RAM mà cả đợt này muốn hạ.
    private static func paintColors(
        vertices: [SIMD3<Float>], normals: [SIMD3<Float>],
        faces: [(UInt32, UInt32, UInt32)],
        geos: [SamplerGeo], samplers: [KeyframeSampler],
        fillUncoloredVertices: Bool
    ) -> [SIMD3<UInt8>] {
        var colors = [SIMD3<UInt8>](repeating: uncoloredGrey, count: vertices.count)
        // Đỉnh không lấy được màu (mọi khung bị bộ lọc chuẩn loại) — để 2 lượt vá cứu sau.
        var uncolored = [Bool](repeating: false, count: vertices.count)
        // Song song hóa theo chunk: mỗi chunk ghi một dải chỉ số RIÊNG (không giao nhau),
        // dữ liệu đọc (vertices/normals/geos/samplers) bất biến → an toàn. Nguyên căn sau khi
        // chia nhỏ tam giác là ~2,5 triệu đỉnh; nhân 160 khung (mức Nét) = 400 TRIỆU vòng lọc,
        // nhân 320 khung (mức Siêu nét) = 800 triệu — tuần tự sẽ bắt chờ rất lâu.
        let total = vertices.count
        let chunkSize = 16_384
        let chunkCount = (total + chunkSize - 1) / chunkSize
        vertices.withUnsafeBufferPointer { vBuf in
            normals.withUnsafeBufferPointer { nBuf in
                colors.withUnsafeMutableBufferPointer { cBuf in
                    uncolored.withUnsafeMutableBufferPointer { uBuf in
                        DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                            let start = chunk * chunkSize
                            let end = min(start + chunkSize, total)
                            for i in start..<end {
                                if let c = sampleColor(
                                    world: vBuf[i], normal: nBuf[i],
                                    geos: geos, samplers: samplers
                                ) {
                                    cBuf[i] = c
                                } else {
                                    uBuf[i] = true // giữ xám 150 tạm — vá bên dưới
                                }
                            }
                        }
                    }
                }
            }
        }

        // Cứu đỉnh xám (chỉ chế độ Mesh bật cờ — RoomPlan giữ hành vi cũ: xám 150 như trước)
        if fillUncoloredVertices {
            fillUncolored(
                colors: &colors, uncolored: &uncolored,
                vertices: vertices, normals: normals, faces: faces,
                geos: geos, samplers: samplers
            )
        }
        return colors
    }

    // MARK: - Vá đỉnh không màu (cờ fillUncoloredVertices — chỉ chế độ Mesh)

    /// Hai lượt cứu đỉnh "xám" (đã quét nhưng mọi khung màu bị bộ lọc chuẩn loại):
    /// 1) LƯỢT VÉT LỎNG TAY 2 NẤC — thử lại với sampleColor(relaxed:): nấc 1 chấp nhận
    ///    góc xiên nhưng GIỮ occlusion, nấc 2 (vẫn hỏng) mới bỏ occlusion. Ưu tiên chạy
    ///    TRƯỚC vì lấy được MÀU THẬT từ ảnh (vd cả mảng tường chỉ được thấy ở góc chéo
    ///    gắt); chỉ chạy cho đỉnh đã hỏng nên không đụng vùng đang đẹp.
    /// 2) VÁ LÂN CẬN — đỉnh vẫn không màu nhận trung bình màu các đỉnh kề trên lưới,
    ///    lan từng vòng (kiểu inpainting của app quét thương mại): mảng xám "mượn" màu
    ///    xung quanh — hơi mờ đều nhưng đẹp hơn xám chết rất nhiều.
    /// Đỉnh thuộc đảo cô lập không nối tới đỉnh màu nào (mảnh vụn rời) giữ xám 150.
    private static func fillUncolored(
        colors: inout [SIMD3<UInt8>], uncolored: inout [Bool],
        vertices: [SIMD3<Float>], normals: [SIMD3<Float>],
        faces: [(UInt32, UInt32, UInt32)],
        geos: [SamplerGeo], samplers: [KeyframeSampler]
    ) {
        // ---- Lượt 1: vét lỏng tay 2 NẤC (song song, chỉ trên danh sách đỉnh hỏng) ----
        // Nấc 1 nới facing nhưng GIỮ occlusion: cứu đúng nhóm đỉnh chỉ hỏng vì góc
        // xiên/kho khung bị vứt, KHÔNG cho khung bị che thắng khung sạch (bỏ occlusion
        // ngay từ đầu sẽ in màu mặt bàn xuống sàn dưới gầm — đúng bug cũ đã trị).
        // Nấc 2 (đỉnh vẫn hỏng) mới bất đắc dĩ bỏ occlusion — thà màu hơi lệch hơn xám.
        let missing = uncolored.indices.filter { uncolored[$0] }
        guard !missing.isEmpty else { return }
        let still = rescuePass(
            missing, skipOcclusion: false,
            vertices: vertices, normals: normals, geos: geos, samplers: samplers,
            colors: &colors, uncolored: &uncolored
        )
        _ = rescuePass(
            still, skipOcclusion: true,
            vertices: vertices, normals: normals, geos: geos, samplers: samplers,
            colors: &colors, uncolored: &uncolored
        )

        // ---- Lượt 2: vá lân cận (lan màu qua cạnh lưới, 2 pha mỗi vòng) ----
        // Chỉ mặt chứa đỉnh còn hỏng mới tham gia — thường là phần nhỏ của lưới.
        // GUARD chỉ số mặt < số đỉnh: index rác từ buffer ARKit không được phép crash
        // lúc lưu (mất cả bản quét) — cùng invariant với guard trong subdivideLargeTriangles;
        // mặt hỏng bị BỎ QUA (không lan màu qua nó). Chỗ này truy mảng bằng chỉ số mặt
        // (subdivide có guard riêng nhưng PASS THROUGH mặt hỏng) nên phải tự kiểm.
        let n = colors.count
        var active = faces.filter {
            Int($0.0) < n && Int($0.1) < n && Int($0.2) < n &&
                (uncolored[Int($0.0)] || uncolored[Int($0.1)] || uncolored[Int($0.2)])
        }
        guard !active.isEmpty else { return }
        var sum = [SIMD3<Float>](repeating: .zero, count: colors.count)
        var cnt = [Int32](repeating: 0, count: colors.count)
        // Trần 128 vòng ≈ lan tối đa ~2.5–4.5m (đỉnh cách 2–3.5cm) — mảng xám xa hơn thế
        // không dính đỉnh màu nào coi như đảo cô lập, giữ xám.
        for _ in 0..<128 {
            // Pha 1: đỉnh MÀU cộng dồn màu sang đỉnh HỎNG cùng mặt (trạng thái đầu vòng).
            func floatColor(_ i: Int) -> SIMD3<Float> {
                SIMD3<Float>(Float(colors[i].x), Float(colors[i].y), Float(colors[i].z))
            }
            for f in active {
                let ia = Int(f.0), ib = Int(f.1), ic = Int(f.2)
                let ca = !uncolored[ia], cb = !uncolored[ib], cc = !uncolored[ic]
                if ca == cb, cb == cc { continue } // cả 3 cùng màu/cùng hỏng → không có gì lan
                if ca { let s = floatColor(ia)
                    if !cb { sum[ib] += s; cnt[ib] += 1 }
                    if !cc { sum[ic] += s; cnt[ic] += 1 } }
                if cb { let s = floatColor(ib)
                    if !ca { sum[ia] += s; cnt[ia] += 1 }
                    if !cc { sum[ic] += s; cnt[ic] += 1 } }
                if cc { let s = floatColor(ic)
                    if !ca { sum[ia] += s; cnt[ia] += 1 }
                    if !cb { sum[ib] += s; cnt[ib] += 1 } }
            }
            // Pha 2: áp trung bình + đánh dấu đã màu + reset bộ đếm (cnt=0 chặn áp trùng).
            var changed = false
            func applyAvg(_ i: Int) {
                guard cnt[i] > 0 else { return }
                let c = sum[i] / Float(cnt[i])
                colors[i] = SIMD3(
                    UInt8(max(0, min(255, c.x + 0.5))),
                    UInt8(max(0, min(255, c.y + 0.5))),
                    UInt8(max(0, min(255, c.z + 0.5)))
                )
                uncolored[i] = false
                sum[i] = .zero
                cnt[i] = 0
                changed = true
            }
            for f in active {
                applyAvg(Int(f.0)); applyAvg(Int(f.1)); applyAvg(Int(f.2))
            }
            if !changed { break } // không lan thêm được — phần còn lại là đảo cô lập
            // Co tập active: mặt đã đủ màu cả 3 đỉnh không còn gì để lan — bỏ khỏi các
            // vòng sau (không co thì O(active × vòng), mảng xám lớn tốn hàng chục giây).
            active = active.filter {
                uncolored[Int($0.0)] || uncolored[Int($0.1)] || uncolored[Int($0.2)]
            }
            if active.isEmpty { break }
        }
    }

    /// Một lượt vét song song trên danh sách đỉnh hỏng (chỉ số LUÔN < số đỉnh — lấy từ
    /// uncolored.indices); trả về danh sách đỉnh VẪN hỏng sau lượt này.
    private static func rescuePass(
        _ missing: [Int], skipOcclusion: Bool,
        vertices: [SIMD3<Float>], normals: [SIMD3<Float>],
        geos: [SamplerGeo], samplers: [KeyframeSampler],
        colors: inout [SIMD3<UInt8>], uncolored: inout [Bool]
    ) -> [Int] {
        guard !missing.isEmpty else { return [] }
        let mCount = missing.count
        let mChunk = 4_096
        let mChunks = (mCount + mChunk - 1) / mChunk
        missing.withUnsafeBufferPointer { mBuf in
            vertices.withUnsafeBufferPointer { vBuf in
                normals.withUnsafeBufferPointer { nBuf in
                    colors.withUnsafeMutableBufferPointer { cBuf in
                        uncolored.withUnsafeMutableBufferPointer { uBuf in
                            DispatchQueue.concurrentPerform(iterations: mChunks) { chunk in
                                let start = chunk * mChunk
                                let end = min(start + mChunk, mCount)
                                for j in start..<end {
                                    let i = mBuf[j]
                                    if let c = sampleColor(
                                        world: vBuf[i], normal: nBuf[i],
                                        geos: geos, samplers: samplers,
                                        relaxed: true, skipOcclusion: skipOcclusion
                                    ) {
                                        cBuf[i] = c
                                        uBuf[i] = false
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return missing.filter { uncolored[$0] }
    }

    /// Màu NỘI SUY 2 CHIỀU trên khung nhỏ (thay nearest) — bớt "vỡ pixel" khi khung 640px
    /// trải lên bề mặt lớn.
    /// ⚠ TỪ 2026-07-29 CHẠY TỐI ĐA 3 LẦN/ĐỈNH, không còn 1 lần như đời trước: `sampleColor`
    /// trộn tốp 3 nên mỗi ứng viên có trọng số dương đều phải đọc ảnh. Mỗi lần là 4 truy cập
    /// bộ nhớ NGẪU NHIÊN vào kho khung 179–358MB. Khi bấm giờ màn "Đang dựng mô hình 3D…" trên
    /// máy thật mà thấy bake chậm hơn dự kiến thì đây là chỗ nhìn ĐẦU TIÊN — `scoreWeight`
    /// chặn được kha khá lượt đọc, nhưng ở chỗ người quét đứng lại lâu (nhiều khung gần cùng
    /// tư thế) thì thường có đủ cả 3 ứng viên.
    private static func bilinearSample(_ kf: KeyframeSampler, x: Float, y: Float) -> SIMD3<UInt8> {
        let gx = max(0, min(Float(kf.w - 1), x * Float(kf.w) / kf.srcW - 0.5))
        let gy = max(0, min(Float(kf.h - 1), y * Float(kf.h) / kf.srcH - 0.5))
        let x0 = Int(gx)
        let y0 = Int(gy)
        let x1 = min(kf.w - 1, x0 + 1)
        let y1 = min(kf.h - 1, y0 + 1)
        let fx = gx - Float(x0)
        let fy = gy - Float(y0)

        func texel(_ px: Int, _ py: Int) -> SIMD3<Float> {
            let o = (py * kf.w + px) * 3
            return SIMD3(Float(kf.rgb[o]), Float(kf.rgb[o + 1]), Float(kf.rgb[o + 2]))
        }
        let top = texel(x0, y0) * (1 - fx) + texel(x1, y0) * fx
        let bottom = texel(x0, y1) * (1 - fx) + texel(x1, y1) * fx
        let c = top * (1 - fy) + bottom * fy
        let r = UInt8(max(0, min(255, c.x + 0.5)))
        let g = UInt8(max(0, min(255, c.y + 0.5)))
        let b = UInt8(max(0, min(255, c.z + 0.5)))
        return SIMD3(r, g, b)
    }
}
