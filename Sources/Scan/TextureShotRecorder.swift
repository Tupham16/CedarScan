import Foundation
import ARKit
import CoreImage
import CoreVideo
import ImageIO
import simd

/// Lưới voxel THÔ (0.25m) đánh dấu "chỗ này đã có ẢNH TEXTURE ĐÃ LƯU" — nguồn sự thật cho
/// lưới quét đổi nghĩa TRẮNG (PLAN-PHU-DU-DO-DUNG item 2, chủ app chốt 03/08: trắng =
/// "bản GIAO chỗ này sẽ CÓ ẢNH", không thêm màu mới; trước đây trắng chỉ nói mesh ARKit
/// đã vào file — người quét tưởng đủ mà bản giao bị thủng texture ở chỗ lia nhanh).
///
/// Ghi: ioQueue của TextureShotRecorder, SAU khi JPEG đã nằm trên đĩa (một khung được
/// "đếm" đúng lúc nó chắc chắn đi theo zip). Đọc: main (MeshOverlayRenderer, nhịp 0.5s).
/// NSLock — critical section vài µs, ~2 lần khoá mỗi giây khi quét + ~600 lần đọc/0.5s
/// lúc đầu buổi (giảm dần vì renderer memo anchor đã phủ — tập voxel CHỈ PHÌNH).
/// ⚠ thinOnDisk KHÔNG gỡ voxel của ảnh bị thưa: ảnh giữ lại (xen kẽ trên cùng đường đi)
/// phủ gần y vùng đó, và gỡ cần sổ voxel-theo-shot — không đáng độ phức tạp.
final class TextureCoverageGrid {
    static let voxelSize: Float = 0.25
    private let lock = NSLock()
    private var voxels = Set<Int64>()

    /// Pack toạ độ voxel 21 bit/trục (offset giữa dải) — ±262km quanh gốc phiên là thừa.
    /// MỘT nguồn sự thật cho cả bên ghi (recorder) lẫn bên đọc (overlay) — lệch công thức
    /// là coverage sai IM LẶNG.
    static func key(_ p: SIMD3<Float>) -> Int64 {
        let x = Int64((p.x / voxelSize).rounded(.down)) &+ 0x1000_00
        let y = Int64((p.y / voxelSize).rounded(.down)) &+ 0x1000_00
        let z = Int64((p.z / voxelSize).rounded(.down)) &+ 0x1000_00
        return (x & 0x1F_FFFF) | ((y & 0x1F_FFFF) << 21) | ((z & 0x1F_FFFF) << 42)
    }

    /// Voxel chứa điểm + 6 voxel kề mặt — nới lúc GHI để mẫu đỉnh mesh rơi sát vách voxel
    /// không trượt oan; nhờ vậy bên đọc chỉ cần 1 lookup/mẫu.
    private static let dilation: [SIMD3<Float>] = [
        SIMD3(0, 0, 0),
        SIMD3(voxelSize, 0, 0), SIMD3(-voxelSize, 0, 0),
        SIMD3(0, voxelSize, 0), SIMD3(0, -voxelSize, 0),
        SIMD3(0, 0, voxelSize), SIMD3(0, 0, -voxelSize),
    ]

    /// Đánh dấu vùng một khung ĐÃ LƯU nhìn thấy: chiếu lưới thưa ~32×24 của depth map
    /// (256×192) ra world rồi cắm voxel. Chạy trên ioQueue (~vài trăm µs), KHÔNG đụng main.
    /// Depth không hữu hạn / ngoài 0.25–3.5m (dải tin được của LiDAR, cùng fuse.py) thì bỏ.
    /// fx/fy/cx/cy là intrinsics THEO ẢNH LƯU (đúng thứ nằm trong ShotMeta) — scale về lưới
    /// depth bằng dw/w, dh/h y như ghi chú shots.json dạy máy trạm.
    func markShot(depthRaw: Data, dw: Int, dh: Int, cam2world m: simd_float4x4,
                  fx: Float, fy: Float, cx: Float, cy: Float, imgW: Int, imgH: Int) {
        guard dw > 0, dh > 0, imgW > 0, imgH > 0, depthRaw.count >= dw * dh * 4 else { return }
        let sx = Float(dw) / Float(imgW)
        let sy = Float(dh) / Float(imgH)
        let dfx = fx * sx
        let dfy = fy * sy
        let dcx = cx * sx
        let dcy = cy * sy
        guard dfx > 0, dfy > 0 else { return }
        var keys: [Int64] = []
        keys.reserveCapacity((32 + 1) * (24 + 1) * Self.dilation.count)
        depthRaw.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: Float32.self) else { return }
            let stepU = max(1, dw / 32)
            let stepV = max(1, dh / 24)
            var v = stepV / 2
            while v < dh {
                var u = stepU / 2
                while u < dw {
                    let d = base[v * dw + u]
                    // Quy ước chiếu = note trong shots.json: camera nhìn -Z, +u phải, +v xuống.
                    if d.isFinite, d > 0.25, d < 3.5 {
                        let qc = SIMD4<Float>((Float(u) - dcx) * d / dfx,
                                              -(Float(v) - dcy) * d / dfy,
                                              -d, 1)
                        let pw = m * qc
                        if pw.x.isFinite, pw.y.isFinite, pw.z.isFinite {
                            let p = SIMD3(pw.x, pw.y, pw.z)
                            for off in Self.dilation {
                                keys.append(Self.key(p + off))
                            }
                        }
                    }
                    u += stepU
                }
                v += stepV
            }
        }
        guard !keys.isEmpty else { return }
        lock.lock()
        voxels.formUnion(keys)
        lock.unlock()
    }

    /// Đếm bao nhiêu key nằm trong tập phủ — MỘT lần khoá cho cả anchor (✗ khoá từng mẫu).
    func containedCount(of keys: [Int64]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var n = 0
        for k in keys where voxels.contains(k) { n += 1 }
        return n
    }
}

/// Chụp ảnh JPEG 1440×1080 + depth thô + pose camera trong lúc quét — NGUYÊN LIỆU cho bước bake texture
/// CHIẾU-1-KHUNG (kiểu CubiCasa) chạy trên máy trạm, KHÔNG phải trên máy khách (chủ app
/// chốt 2026-07-29). Đầu ra: thư mục `texture-shots/` (shot-NNNN.jpg + shots.json) được
/// `ScanStore.saveMeshScan` đóng KÈM VÀO model-colored.zip — nằm TRONG zip nên không đụng
/// `ScanUploader.fileKinds`, server không phải đổi gì.
///
/// Vì sao không dùng lại ảnh sẵn có:
///  - Video walkthrough chỉ 360×480 @ 700kbps — H.264 nghiền nát chi tiết, chiếu lên tường
///    ra vân khối vuông. Tăng chất lượng video thì zip phình ~10 lần (chết upload 4G).
///  - Khung màu của ColorMeshBuilder (640×480 trong RAM) bị van xả RAM + cơ chế thưa-dần
///    đụng vào, và nhịp chụp của nó TỰ GIÃN ĐÔI vì trần RAM cố định — ảnh trên ĐĨA không có
///    trần đó nên tách hẳn ra để giữ mật độ ảnh ĐỀU suốt buổi.
///
/// Cách chạy (cùng khuôn ScanVideoRecorder/ColorMeshBuilder — CADisplayLink nhịp thấp đọc
/// `arSession.currentFrame`, không chiếm delegate):
///  - tick 3Hz: qua các CỔNG (tracking normal → không lia quá nhanh → đủ giãn cách thời
///    gian → đã DI CHUYỂN đủ xa so với ảnh trước) rồi thu nhỏ khung camera về 1440 ngang
///    + chép depth thô 256×192 NGAY TRÊN MAIN vào buffer RIÊNG (không giữ CVPixelBuffer
///    của ARKit qua async — pool của ARKit rất nhỏ, giữ lâu là tracking sụt), nén JPEG
///    + DEFLATE depth + ghi đĩa ở queue nền.
///  - Kho đầy (480 ảnh ≈ 90–100MB + depth ~15–25MB): BỎ 1 ẢNH XEN KẼ TRÊN ĐĨA (kèm file
///    depth của nó) rồi nhân đôi giãn cách — đúng cơ chế trải-đều của kho khung màu,
///    nhưng trả giá bằng đĩa (rẻ) thay vì RAM.
///  - Ảnh giữ NGUYÊN HƯỚNG CẢM BIẾN (landscape) — không xoay pixel, không gắn EXIF:
///    intrinsics của ARKit tham chiếu đúng lưới pixel đó, xoay ảnh là phải xoay cả
///    intrinsics (chỗ sai kinh điển, lộ ra thành texture lệch toàn bộ mà không ai bắt được
///    bằng mắt thường). Máy trạm tự lo chuyện hướng — mở file thấy ảnh nằm ngang là ĐÚNG.
final class TextureShotRecorder {
    // MARK: - Hằng số (chỉnh ở đây khi máy trạm đòi khác)
    /// Bề ngang ảnh lưu (px). 1440 trên khung 1920×1440 = 3/4 → ~2.7mm/px ở khoảng cách
    /// 2.5m (mục 1 PLAN-NANG-NET, chủ app duyệt 30/07: "cần KHÔNG BỊ NHÒE").
    /// Intrinsics tự scale theo (xem `s` dưới) nên máy trạm KHÔNG phải sửa gì.
    private static let targetWidth = 1440
    /// Chất lượng JPEG — hạ 0.62 → 0.55 làm đối trọng cho 2.25× pixel của mức 1440:
    /// kho 480 ảnh ~50MB (960/q0.62) → ~90–100MB thay vì ~110MB, nằm trong mức
    /// "+50–60MB zip" chủ app duyệt. Độ nét ăn theo RESOLUTION, không theo nấc q này.
    private static let jpegQuality: Double = 0.55
    /// Giãn cách TỐI THIỂU giữa hai ảnh (giây) — nhân đôi mỗi lần kho đầy.
    private static let startInterval: TimeInterval = 1.2
    /// Ngưỡng "đã sang góc nhìn mới": dịch ≥ 0.4m HOẶC xoay ≥ 25°. Đứng yên một chỗ thì
    /// một ảnh là đủ cho texture — không tốn thêm.
    private static let minTravel: Float = 0.4
    private static let minTurnDeg: Float = 25
    /// Đang lia nhanh hơn mức này (độ/giây) thì khung gần như chắc chắn nhoè → nhịn, chờ
    /// tick sau. 30°/s chỉ chặn cú vụt mạnh; nhoè nhẹ là "noise chấp nhận được" của lối
    /// texture này (chính chủ app mô tả CubiCasa y hệt).
    private static let maxTurnRateDegPerSec: Float = 30
    /// Trần số ảnh trên đĩa. Chạm là bỏ xen kẽ còn một nửa + nhân đôi giãn cách —
    /// buổi quét dài bao nhiêu cũng hội tụ dưới ~480 ảnh ≈ 90–100MB (mức 1440/q0.55)
    /// + depth thô ~15–25MB. ⚠ Trần này GẮN với nhịp giãn-đôi — muốn giảm dung lượng
    /// thì hạ jpegQuality, ✗ hạ trần (buổi dài sẽ dồn hết ảnh vào phút đầu).
    private static let maxShots = 480
    /// Còn quá nhiều ảnh chờ nén thì bỏ lượt này (I/O nghẽn) — không xếp hàng vô hạn.
    private static let maxPendingEncodes = 3

    /// Thư mục chứa ảnh + shots.json. Bọc trong thư mục cha `texshots-<uuid>` để
    /// lastPathComponent luôn là "texture-shots" sạch sẽ khi được copy vào zip.
    /// HỢP ĐỒNG với ScanStore: dọn dẹp = xoá THƯ MỤC CHA (deletingLastPathComponent).
    let shotsDirURL: URL

    /// Vùng ĐÃ CÓ ẢNH LƯU (item 2) — MeshOverlayRenderer đọc để quyết lưới trắng.
    /// Sống cùng recorder; khung không có sceneDepth thì không đánh dấu được (hiếm trên
    /// máy LiDAR, ngưỡng % bên overlay hấp thụ).
    let coverage = TextureCoverageGrid()

    private weak var arSession: ARSession?
    private var displayLink: CADisplayLink?
    private let ciContext = CIContext()
    /// Queue NỐI TIẾP: mọi việc đĩa (nén, ghi, thưa bớt, chốt sổ) xếp hàng ở đây,
    /// nên `metas` chỉ được đụng từ queue này — không cần khoá.
    private let ioQueue = DispatchQueue(label: "com.cedar247.texshots", qos: .utility)

    private struct ShotMeta: Encodable {
        let file: String
        /// frame.timestamp của ARKit (đồng hồ máy, giây) — KHÔNG khớp PTS video, chỉ để
        /// máy trạm biết thứ tự/giãn cách thời gian.
        let t: Double
        /// camera→world, 16 số THEO CỘT (column-major), quy ước ARKit: +X phải, +Y lên,
        /// ống kính nhìn theo -Z.
        let m: [Float]
        /// Intrinsics ĐÃ NHÂN THEO TỈ LỆ ảnh lưu (không phải khung 1920 gốc).
        let fx: Float
        let fy: Float
        let cx: Float
        let cy: Float
        let w: Int
        let h: Int
        /// exposureOffset (EV) của ARKit — cho bước san phơi sáng giữa các mảng (nếu làm).
        let ev: Float
        /// Mục 4 PLAN-NANG-NET — file depth thô đi kèm (shot-NNNN.depth), nil nếu khung
        /// này không chụp được sceneDepth / ghi lỗi. String/Int nên MIỄN câu hỏi NaN
        /// (luật ShotMeta: field mới phải tự trả lời câu NaN — JSONEncoder throw là
        /// finish() vứt CẢ GÓI). Baker hiện BỎ QUA field lạ — dữ liệu gieo hạt cho
        /// fusion/pose-refinement, chưa ai dùng.
        var depth: String?
        var dw: Int?
        var dh: Int?
    }
    private struct ShotsFile: Encodable {
        let version: Int
        let note: String
        let shots: [ShotMeta]
    }

    // Trạng thái CHỈ đụng trên ioQueue
    private var metas: [ShotMeta] = []
    // Trạng thái CHỈ đụng trên main (tick + finish/cancel đều main)
    private var minInterval = TextureShotRecorder.startInterval
    private var approxShotCount = 0
    private var shotIndex = 0
    private var pendingEncodes = 0
    private var lastShotTime: TimeInterval = 0
    private var lastShotPosition: SIMD3<Float>?
    private var lastShotQuat: simd_quatf?
    private var lastSeenFrameTime: TimeInterval = 0
    private var prevTickTime: TimeInterval = 0
    private var prevTickQuat: simd_quatf?
    private var isFinishing = false

    init(arSession: ARSession) {
        self.arSession = arSession
        shotsDirURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("texshots-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("texture-shots", isDirectory: true)
    }

    func start() {
        guard displayLink == nil, !isFinishing else { return }
        try? FileManager.default.createDirectory(
            at: shotsDirURL, withIntermediateDirectories: true
        )
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 2, maximum: 5, preferred: 3)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        let perfT0 = ScanPerfProfiler.tickBegin()
        defer { ScanPerfProfiler.tickEnd(.texShot, perfT0) }
        guard !isFinishing, let frame = arSession?.currentFrame else { return }
        // Phiên pause/gián đoạn thì currentFrame lặp lại khung cũ — bỏ qua ngay cho rẻ.
        guard frame.timestamp != lastSeenFrameTime else { return }
        lastSeenFrameTime = frame.timestamp
        // Tracking chưa normal = pose không tin được → ảnh chiếu sẽ lệch, bỏ.
        guard case .normal = frame.camera.trackingState else { return }

        let tf = frame.camera.transform
        let pos = SIMD3(tf.columns.3.x, tf.columns.3.y, tf.columns.3.z)
        guard pos.x.isFinite, pos.y.isFinite, pos.z.isFinite else { return }
        let quat = simd_normalize(simd_quatf(tf))
        guard quat.vector.x.isFinite else { return }
        // Intrinsics NaN = phép chiếu vô nghĩa → bỏ shot. Mọi Float vào shots.json PHẢI
        // hữu hạn: JSONEncoder mặc định THROW với NaN/Inf, mà finish() xử lý throw bằng
        // cách vứt CẢ GÓI — một khung hỏng không được phép giết 480 khung tốt.
        // (Cùng triết lý guard NaN của ScanVideoRecorder.appendTrackSample.)
        let k = frame.camera.intrinsics
        guard k.columns.0.x.isFinite, k.columns.1.y.isFinite,
              k.columns.2.x.isFinite, k.columns.2.y.isFinite else { return }

        // Cổng "đang lia quá nhanh": đo tốc độ xoay giữa hai tick liên tiếp.
        // Cập nhật mốc tick TRƯỚC khi qua các cổng sau — mốc phải mới ở MỌI tick normal.
        var turnRate: Float = 0
        if let prevQuat = prevTickQuat, frame.timestamp > prevTickTime,
           frame.timestamp - prevTickTime <= 1.0 {
            let dt = Float(frame.timestamp - prevTickTime)
            turnRate = Self.angleDeg(prevQuat, quat) / dt
        }
        prevTickQuat = quat
        prevTickTime = frame.timestamp
        guard turnRate <= Self.maxTurnRateDegPerSec else { return }

        guard frame.timestamp - lastShotTime >= minInterval else { return }

        if let lastPos = lastShotPosition, let lastQuat = lastShotQuat {
            let moved = simd_distance(pos, lastPos)
            let turned = Self.angleDeg(lastQuat, quat)
            guard moved >= Self.minTravel || turned >= Self.minTurnDeg else { return }
        }

        guard pendingEncodes < Self.maxPendingEncodes else { return }

        // Thu nhỏ về buffer RIÊNG ngay trên main (GPU, ~vài ms) — sau dòng render này
        // không còn đụng gì tới buffer của ARKit nữa.
        let srcBuffer = frame.capturedImage
        let srcW = CVPixelBufferGetWidth(srcBuffer)
        let srcH = CVPixelBufferGetHeight(srcBuffer)
        guard srcW > 0, srcH > 0 else { return }
        let scale = min(1, CGFloat(Self.targetWidth) / CGFloat(srcW))
        let outW = Int((CGFloat(srcW) * scale).rounded())
        let outH = Int((CGFloat(srcH) * scale).rounded())

        var outBuffer: CVPixelBuffer?
        let bufferAttrs = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ] as CFDictionary
        CVPixelBufferCreate(
            kCFAllocatorDefault, outW, outH, kCVPixelFormatType_32BGRA,
            bufferAttrs, &outBuffer
        )
        guard let outBuffer else { return }
        var image = CIImage(cvPixelBuffer: srcBuffer)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        image = image.transformed(by: CGAffineTransform(
            translationX: -image.extent.origin.x, y: -image.extent.origin.y
        ))
        ciContext.render(
            image, to: outBuffer,
            bounds: CGRect(x: 0, y: 0, width: outW, height: outH),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        // Mục 4 PLAN-NANG-NET: chép depth thô (~256×192 Float32) NGAY TRÊN MAIN vào
        // buffer RIÊNG — 🔴 ✗ giữ CVPixelBuffer của ARKit qua async (pool nhỏ, giữ lâu
        // là tracking sụt). Cùng khuôn chép-rồi-nhả của ColorMeshBuilder. ~196KB/shot,
        // memcpy vài chục µs. Thiếu depth thì shot vẫn ghi bình thường (chỉ ảnh).
        var depthRaw: Data?
        var depthW = 0
        var depthH = 0
        if let depthMap = frame.sceneDepth?.depthMap,
           CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32,
           CVPixelBufferLockBaseAddress(depthMap, .readOnly) == kCVReturnSuccess {
            if let dBase = CVPixelBufferGetBaseAddress(depthMap) {
                let dw = CVPixelBufferGetWidth(depthMap)
                let dh = CVPixelBufferGetHeight(depthMap)
                let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
                if dw > 0, dh > 0, rowBytes >= dw * 4 {
                    var buf = Data(count: dw * dh * 4)
                    buf.withUnsafeMutableBytes { dst in
                        guard let dstBase = dst.baseAddress else { return }
                        for row in 0..<dh {
                            memcpy(dstBase + row * dw * 4, dBase + row * rowBytes, dw * 4)
                        }
                    }
                    depthRaw = buf
                    depthW = dw
                    depthH = dh
                }
            }
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }

        // Chốt meta NGAY LÚC BẤM (main) — không đọc lại frame trong closure nền.
        let s = Float(scale)
        // ev chỉ là dữ liệu PHỤ (san phơi sáng) — non-finite thì thay 0 (giá trị ARKit
        // trả khi tắt light estimation) chứ không bỏ shot; xem chú thích NaN ở guard trên.
        let evRaw = frame.camera.exposureOffset
        shotIndex += 1
        let meta = ShotMeta(
            file: String(format: "shot-%04d.jpg", shotIndex),
            t: frame.timestamp,
            m: Self.columnMajor(tf),
            fx: k.columns.0.x * s, fy: k.columns.1.y * s,
            cx: k.columns.2.x * s, cy: k.columns.2.y * s,
            w: outW, h: outH,
            ev: evRaw.isFinite ? evRaw : 0,
            depth: depthRaw != nil ? String(format: "shot-%04d.depth", shotIndex) : nil,
            dw: depthRaw != nil ? depthW : nil,
            dh: depthRaw != nil ? depthH : nil
        )
        lastShotTime = frame.timestamp
        lastShotPosition = pos
        lastShotQuat = quat
        pendingEncodes += 1
        approxShotCount += 1

        let dirURL = shotsDirURL
        let context = ciContext
        ioQueue.async { [weak self] in
            let ci = CIImage(cvPixelBuffer: outBuffer)
            let quality = CIImageRepresentationOption(
                rawValue: kCGImageDestinationLossyCompressionQuality as String
            )
            let data = context.jpegRepresentation(
                of: ci,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
                    ?? CGColorSpaceCreateDeviceRGB(),
                options: [quality: Self.jpegQuality]
            )
            var written = false
            if let data {
                // .atomic: ghi lỗi giữa chừng (đĩa đầy — ca thật số 1 của buổi quét dài)
                // thì KHÔNG để lại file cụt; file cụt không ai tham chiếu vẫn bị copyItem
                // đệ quy đóng vào zip (review 30/07 bắt trên nhánh depth, JPEG cùng khuôn).
                written = (try? data.write(
                    to: dirURL.appendingPathComponent(meta.file), options: [.atomic]
                )) != nil
            }
            if written {
                var m = meta
                // Depth ghi SAU ảnh và CHỈ khi ảnh đã nằm trên đĩa — chiều ngược lại
                // (depth có, ảnh không) là file mồ côi. Nén DEFLATE thô (NSData .zlib
                // không header — Python: zlib.decompress(data, -15)). Nén/ghi lỗi thì
                // shot vẫn giữ, chỉ rụng phần depth (meta phải nói thật là không có).
                if let depthRaw, let depthFile = m.depth {
                    let packed = try? (depthRaw as NSData).compressed(using: .zlib) as Data
                    let okDepth = packed.map {
                        (try? $0.write(
                            to: dirURL.appendingPathComponent(depthFile), options: [.atomic]
                        )) != nil
                    } ?? false
                    if !okDepth {
                        m.depth = nil
                        m.dw = nil
                        m.dh = nil
                    }
                } else {
                    m.depth = nil
                    m.dw = nil
                    m.dh = nil
                }
                self?.metas.append(m)
                // Item 2: ảnh đã chắc chắn theo zip → đánh dấu vùng nó thấy vào lưới
                // coverage (lưới quét đổi TRẮNG theo đây). Dùng depthRaw trong RAM —
                // KHÔNG phụ thuộc file .depth ghi được hay không (ảnh mới là thứ bake
                // cần). Không có sceneDepth thì thôi (hiếm; ngưỡng % overlay hấp thụ).
                if let depthRaw {
                    self?.coverage.markShot(
                        depthRaw: depthRaw, dw: depthW, dh: depthH, cam2world: tf,
                        fx: meta.fx, fy: meta.fy, cx: meta.cx, cy: meta.cy,
                        imgW: meta.w, imgH: meta.h
                    )
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingEncodes -= 1
                // Ghi hỏng (đĩa đầy…) thì trả lại suất đếm — không thì trần 480 mòn ảo.
                if !written { self.approxShotCount -= 1 }
            }
        }

        // Kho đầy: thưa bớt trên ĐĨA + nhân đôi giãn cách. Đếm ở main chỉ là ước lượng
        // để BẤM NÚT; danh sách thật nằm trên ioQueue (queue nối tiếp nên lệnh thưa xếp
        // sau mọi lệnh ghi đang chờ — thấy đủ ảnh).
        if approxShotCount >= Self.maxShots {
            approxShotCount = (approxShotCount + 1) / 2
            minInterval *= 2
            ioQueue.async { [weak self] in
                self?.thinOnDisk()
            }
        }
    }

    /// Bỏ 1 ảnh xen kẽ (giữ 0,2,4…) — chạy trên ioQueue.
    private func thinOnDisk() {
        var kept: [ShotMeta] = []
        kept.reserveCapacity((metas.count + 1) / 2)
        for (i, meta) in metas.enumerated() {
            if i % 2 == 0 {
                kept.append(meta)
            } else {
                try? FileManager.default.removeItem(
                    at: shotsDirURL.appendingPathComponent(meta.file)
                )
                // 🔴 depth ĐI KÈM ảnh — xoá CÙNG LÚC: file mồ côi vừa là rác trong zip
                // vừa làm lệch cặp ảnh↔depth phía máy trạm (mục 4 PLAN-NANG-NET).
                if let depthFile = meta.depth {
                    try? FileManager.default.removeItem(
                        at: shotsDirURL.appendingPathComponent(depthFile)
                    )
                }
            }
        }
        metas = kept
    }

    /// Chốt sổ: chờ nén xong hết, ghi shots.json, trả về thư mục texture-shots + SỐ ẢNH
    /// thật đã ghi (nil nếu không có ảnh nào — thư mục cũng bị dọn luôn).
    /// @MainActor cùng lý do ScanVideoRecorder.finish: tick chạy trên main, thân hàm phải
    /// cùng actor để invalidate/đọc trạng thái không đua với tick (SE-0338).
    ///
    /// 🔴 Vì sao trả kèm SỐ ẢNH: `stopAndExport` dùng nó để chọn đường LƯU NHANH (đủ ảnh
    /// texture thì bỏ hẳn vòng bake màu-đỉnh). Con số phải lấy từ `metas.count` NGAY TRONG
    /// ioQueue — nơi duy nhất được đụng `metas`. ✗ đọc `metas` từ main (phá bất biến
    /// không-lock của class này) và ✗ dùng `approxShotCount`: nó là số ƯỚC LƯỢNG, bị chia
    /// đôi khi kho đầy và trừ đi khi ghi ảnh lỗi.
    @MainActor
    func finish() async -> (dir: URL, shotCount: Int)? {
        guard !isFinishing else { return nil }
        isFinishing = true
        displayLink?.invalidate()
        displayLink = nil
        let dirURL = shotsDirURL
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<(dir: URL, shotCount: Int)?, Never>) in
            ioQueue.async { [weak self] in
                guard let self, !self.metas.isEmpty else {
                    try? FileManager.default.removeItem(at: dirURL.deletingLastPathComponent())
                    continuation.resume(returning: nil)
                    return
                }
                let file = ShotsFile(
                    version: 1,
                    note: "ARKit: m = camera-to-world, column-major; camera looks -Z, +X right, "
                        + "+Y up. Images kept in SENSOR orientation (landscape), no EXIF; "
                        + "intrinsics match stored pixels. Pixel origin top-left, +u right, "
                        + "+v down. Project world point P: q = inverse(m)*P; "
                        + "u = fx*q.x/(-q.z) + cx; v = fy*(-q.y)/(-q.z) + cy; valid when q.z < 0. "
                        + "t = ARKit frame timestamp (device clock, NOT video PTS). "
                        + "ev = ARKit exposureOffset (EV). "
                        + "Optional per-shot 'depth' file (dw*dh): raw DEFLATE, no zlib "
                        + "header — Python: zlib.decompress(data, -15) -> Float32 "
                        + "little-endian, row-major, meters, same sensor orientation as "
                        + "the JPEG; scale intrinsics by dw/w, dh/h. Raw ARKit sceneDepth "
                        + "(values may be non-finite) — reserved for future fusion, "
                        + "no consumer yet.",
                    shots: self.metas
                )
                do {
                    let data = try JSONEncoder().encode(file)
                    try data.write(to: dirURL.appendingPathComponent("shots.json"))
                    continuation.resume(returning: (dir: dirURL, shotCount: self.metas.count))
                } catch {
                    // Thiếu shots.json thì ảnh vô dụng với máy trạm — dọn cả gói, đừng
                    // độn 50MB rác vào zip.
                    try? FileManager.default.removeItem(at: dirURL.deletingLastPathComponent())
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Hủy (khách bấm Hủy buổi quét) — xoá sạch thư mục tạm.
    func cancel() {
        isFinishing = true
        displayLink?.invalidate()
        displayLink = nil
        let parent = shotsDirURL.deletingLastPathComponent()
        ioQueue.async {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    // MARK: - Toán phụ

    /// Góc quay giữa hai quaternion (độ), xử lý double-cover bằng |dot|.
    private static func angleDeg(_ a: simd_quatf, _ b: simd_quatf) -> Float {
        let d = min(1, abs(simd_dot(a.vector, b.vector)))
        return 2 * acos(d) * 180 / .pi
    }

    private static func columnMajor(_ m: simd_float4x4) -> [Float] {
        [
            m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
            m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
            m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
            m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w,
        ]
    }
}
