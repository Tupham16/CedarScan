import Foundation
import ARKit
import CoreImage
import CoreVideo
import ImageIO
import simd

/// Chụp ảnh JPEG 960×720 + pose camera trong lúc quét — NGUYÊN LIỆU cho bước bake texture
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
///    gian → đã DI CHUYỂN đủ xa so với ảnh trước) rồi thu nhỏ khung camera về 960 ngang
///    NGAY TRÊN MAIN vào buffer RIÊNG (không giữ CVPixelBuffer của ARKit qua async —
///    pool của ARKit rất nhỏ, giữ lâu là tracking sụt), nén JPEG + ghi đĩa ở queue nền.
///  - Kho đầy (480 ảnh ≈ 50MB): BỎ 1 ẢNH XEN KẼ TRÊN ĐĨA rồi nhân đôi giãn cách — đúng
///    cơ chế trải-đều của kho khung màu, nhưng trả giá bằng đĩa (rẻ) thay vì RAM.
///  - Ảnh giữ NGUYÊN HƯỚNG CẢM BIẾN (landscape) — không xoay pixel, không gắn EXIF:
///    intrinsics của ARKit tham chiếu đúng lưới pixel đó, xoay ảnh là phải xoay cả
///    intrinsics (chỗ sai kinh điển, lộ ra thành texture lệch toàn bộ mà không ai bắt được
///    bằng mắt thường). Máy trạm tự lo chuyện hướng — mở file thấy ảnh nằm ngang là ĐÚNG.
final class TextureShotRecorder {
    // MARK: - Hằng số (chỉnh ở đây khi máy trạm đòi khác)
    /// Bề ngang ảnh lưu (px). 960 trên khung 1920×1440 = đúng nửa → ~4mm/px ở khoảng cách
    /// 2.5m, JPEG ~70–110KB/ảnh. Chủ app duyệt mức "+~50MB zip" 2026-07-29.
    private static let targetWidth = 960
    /// Chất lượng JPEG — 0.62 đủ cho texture tường/sàn, đổi 0.75 nếu đội vẽ chê vỡ hạt.
    private static let jpegQuality: Double = 0.62
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
    /// buổi quét dài bao nhiêu cũng hội tụ dưới ~480 ảnh ≈ 50MB.
    private static let maxShots = 480
    /// Còn quá nhiều ảnh chờ nén thì bỏ lượt này (I/O nghẽn) — không xếp hàng vô hạn.
    private static let maxPendingEncodes = 3

    /// Thư mục chứa ảnh + shots.json. Bọc trong thư mục cha `texshots-<uuid>` để
    /// lastPathComponent luôn là "texture-shots" sạch sẽ khi được copy vào zip.
    /// HỢP ĐỒNG với ScanStore: dọn dẹp = xoá THƯ MỤC CHA (deletingLastPathComponent).
    let shotsDirURL: URL

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
            ev: evRaw.isFinite ? evRaw : 0
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
                written = (try? data.write(to: dirURL.appendingPathComponent(meta.file))) != nil
            }
            if written {
                self?.metas.append(meta)
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
            }
        }
        metas = kept
    }

    /// Chốt sổ: chờ nén xong hết, ghi shots.json, trả về thư mục texture-shots
    /// (nil nếu không có ảnh nào — thư mục cũng bị dọn luôn).
    /// @MainActor cùng lý do ScanVideoRecorder.finish: tick chạy trên main, thân hàm phải
    /// cùng actor để invalidate/đọc trạng thái không đua với tick (SE-0338).
    @MainActor
    func finish() async -> URL? {
        guard !isFinishing else { return nil }
        isFinishing = true
        displayLink?.invalidate()
        displayLink = nil
        let dirURL = shotsDirURL
        return await withCheckedContinuation { continuation in
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
                        + "ev = ARKit exposureOffset (EV).",
                    shots: self.metas
                )
                do {
                    let data = try JSONEncoder().encode(file)
                    try data.write(to: dirURL.appendingPathComponent("shots.json"))
                    continuation.resume(returning: dirURL)
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
