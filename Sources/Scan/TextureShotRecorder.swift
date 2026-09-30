import Foundation
import ARKit
import AVFoundation
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
///  - Sharpest frame (2.70, owner 29/09 "hướng 1"): a shot that is DUE no longer saves the
///    first frame through the gates. That frame opens a CHOICE WINDOW (≤ 0.8 s, ticks at
///    20Hz meanwhile); the recorder keeps ONE downscaled copy of the least-blurred frame
///    seen and saves it when the window ends. Blur is PREDICTED, no image work: exposure
///    time × image speed from two consecutive ARKit poses (see `predictBlur`). The
///    window ends early on a sharp frame (≤ 1 px), when the camera leaves an 8° / 15 cm cone
///    around the opening frame, and on Stop. The gates run on the OPENING frame exactly as
///    before, so shots come as often as before; each saved frame is within 8° / 15 cm /
///    0.8 s of the one the old rule saved. Why: the owner's textures looked smeared next to
///    Scaniverse / 3D Scanner App, and the workstation measured the RAW shots as already
///    soft (motion blur while turning, q0.55) — bake-side fixes did not help.
///  - Kho đầy (800 ảnh, ~160KB/ảnh jpg+depth at q0.55, see jpegQuality):
///    BỎ 1 ẢNH XEN KẼ TRÊN ĐĨA (kèm file depth của nó) rồi nhân đôi giãn cách — đúng cơ chế
///    trải-đều của kho khung màu, nhưng trả giá bằng đĩa (rẻ) thay vì RAM.
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
    /// (đời trần 480, 30/07) kho 480 ảnh ~50MB (960/q0.62) → ~90–100MB thay vì ~110MB,
    /// nằm trong mức "+50–60MB zip" chủ app duyệt lúc đó (nay trần 800, xem maxShots).
    /// 0.55 → 0.8 (2.70) → back to 0.55 (2.70.2, owner 30/09): the workstation MEASURED q0.8
    /// useless — jpg +75% (181 vs ~105KB) on the 2.70 scans, re-encoding a q0.8 shot at 0.55
    /// changed no measured sharpness (< 1%) and deblur results were the same.
    /// Measured at 0.55: jpg ~107KB (~139KB mean on a dim scan) + depth ~52KB ≈ 160KB/shot →
    /// full 800 store ~128MB. Noisier frames cost more: 2.70.1's hard 4 ms cap (ISO at max on
    /// 43% of frames) ran 246KB jpg at q0.8; the adaptive cap keeps dark rooms near 2.70's
    /// noise. A full store always takes the fast-save path (≥ fastSaveMinShots, no GLB), under
    /// the 500MB objzip cap (order-webapp app-storage.ts) with room to spare.
    private static let jpegQuality: Double = 0.55
    /// Giãn cách TỐI THIỂU giữa hai ảnh (giây) — nhân đôi mỗi lần kho đầy.
    private static let startInterval: TimeInterval = 1.2
    /// Ngưỡng "đã sang góc nhìn mới": dịch ≥ 0.4m HOẶC xoay ≥ 25°. Đứng yên một chỗ thì
    /// một ảnh là đủ cho texture — không tốn thêm.
    private static let minTravel: Float = 0.4
    private static let minTurnDeg: Float = 25
    /// Đang lia nhanh hơn mức này (độ/giây) thì khung gần như chắc chắn nhoè → nhịn, chờ
    /// tick sau. Ngưỡng này chỉ chặn cú vụt mạnh; nhoè nhẹ là "noise chấp nhận được" của lối
    /// texture này (chính chủ app mô tả CubiCasa y hệt).
    /// 30 → 40 (26/09, owner "mục 5 cách 3"): at 30–60°/s there was no coach warning AND no
    /// photo. The baker weights sharpness (compute_shot_sharpness), so a blurrier shot is used
    /// only when nothing sharper exists. Was paired with ScanQualityConfig.maxRotationSoft 45;
    /// since 2.57 the coach warns at 68 (owner: too naggy).
    /// 40 → 50 (2.58, owner 26/09): ~25% more motion blur / rolling-shutter skew on shots taken
    /// while turning fast, accepted; the baker's sharpness weighting + photo-consistency filter
    /// prefer sharper shots, mesh/measurements unaffected. 50–68°/s = no photo, no warning (owner
    /// knows). Move this gate or the coach only with the owner.
    private static let maxTurnRateDegPerSec: Float = 50
    /// Trần số ảnh trên đĩa. Chạm là bỏ xen kẽ còn một nửa + nhân đôi giãn cách —
    /// buổi quét dài bao nhiêu cũng hội tụ dưới trần này. ⚠ Trần này GẮN với nhịp
    /// giãn-đôi — muốn giảm dung lượng thì hạ jpegQuality, ✗ hạ trần (buổi dài sẽ dồn
    /// hết ảnh vào phút đầu). 🔴 Trần ĐẾM này MỘT MÌNH chặn cỡ zip — ✗ bỏ.
    /// 480 → 800 (26/09, owner): 480 was hit at ~10 min, so big houses thinned to 240 and
    /// ~8% of faces got no photo (#LS-MSLINTGA7, 949 m², 268 shots). Measured ~160KB/shot
    /// (jpg ~107KB + depth ~52KB) → full store ~128MB; worst gap vs 480 ≈ 400 shots
    /// ≈ +64MB zip (800 full vs 400 just-thinned), only for scans past ~10 min.
    /// (2.70's q0.8 measured jpg 181KB, 246KB under 2.70.1's hard 4 ms cap, + depth; 2.70.2 is
    /// back at 0.55, see jpegQuality.)
    /// Server objzip cap 500MB (order-webapp app-storage.ts). Paired with
    /// tex-worker-config.json "maxShots" (bake set-cover cap) on the workstation.
    private static let maxShots = 800
    /// Còn quá nhiều ảnh chờ nén thì bỏ lượt này (I/O nghẽn) — không xếp hàng vô hạn.
    /// Checked when a choice window OPENS (pending ≤ 2 then), so the held copy + the queue
    /// never hold more than 3 downscaled buffers (~6MB each), as before 2.70.
    private static let maxPendingEncodes = 3
    // ── Choice window (2.70, see the class comment). Tuning levers; the gates above and the
    // coach are NOT part of it.
    /// Longest wait for a sharper frame after a shot fell due (host clock).
    private static let windowSec: CFTimeInterval = 0.8
    /// A frame this sharp (predicted, stored-image px) is saved at once — also the opening
    /// frame, so bright scenes / a still phone behave exactly as before 2.70.
    private static let sharpEnoughPx: Float = 1.0
    /// A later frame replaces the held copy only when clearly sharper (both rules): each copy
    /// is a main-thread GPU downscale, so small gains are not worth one.
    private static let improveFactor: Float = 0.7
    private static let improveMinPx: Float = 0.5
    /// Copies per window, the opening one included; a sharp-enough frame is always taken.
    private static let maxCopiesPerWindow = 4
    /// The saved frame stays this close to the opening frame (the one the old rule saved):
    /// beyond it the camera looks at something else — save the held copy now. Bounds how
    /// far photo coverage can move vs before 2.70.
    private static let maxDriftDeg: Float = 8
    private static let maxDriftM: Float = 0.15
    /// Ranking only, when ARFrame.exifData has no exposure time (typical indoor value;
    /// `blurPx` is then not recorded).
    private static let assumedExposureSec: Double = 1.0 / 60
    /// Tick rates: 3Hz between windows (unchanged), 20Hz inside one — pose deltas ~50ms
    /// apart estimate the motion during a ~10–16ms exposure far better than 333ms apart.
    private static let slowRate = CAFrameRateRange(minimum: 2, maximum: 5, preferred: 3)
    private static let fastRate = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 20)
    /// Name of the per-shot ARAnchor (item 1, 26/09) — MeshScanController picks the final
    /// poses by it. Other anchor readers (ColorMeshBuilder, MeshOverlayRenderer) take
    /// `ARMeshAnchor` only; ARSCNView gives each anchor an empty node (no delegate).
    static let anchorName = "cedar.texshot"

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
        /// Named at commit (`shot-NNNN.jpg`) — a held window copy has no number yet.
        var file: String
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
        // ── 26/09 additions (owner-approved). PHASE RULE: record only — the workstation does
        // NOT read these yet, and `m` stays the capture-time pose exactly as before. All
        // optional (nil = key omitted) and finite-checked before they get here (NaN rule).
        /// Final pose of this shot's ARAnchor, read at Stop BEFORE arSession.pause(); same
        /// convention as `m`. ARKit corrects its map (loop closure) and moves anchors with it,
        /// `m` stays frozen. nil = anchor missing in the final frame / non-finite.
        var m2: [Float]?
        /// From ARFrame.exifData: exposure time (s), ISO, EXIF BrightnessValue (APEX).
        var exp: Double?
        var iso: Float?
        var bv: Float?
        /// AVCaptureDevice.deviceWhiteBalanceGains at capture [r, g, b].
        var wb: [Float]?
        /// Auto torch (26/09): torch level at capture, 0 = off; nil = no torch device.
        /// Torch-lit = harsh hotspot, 1/d² falloff, cold LED under a locked white balance —
        /// the workstation may later prefer shots with 0. Finite 0…1 (AutoTorch.levelForShot).
        var torch: Float?
        // ── 2.70 additions (owner 29/09). PHASE RULE as above: record only, optional, finite.
        /// Predicted motion blur of THIS frame in stored-image px (`predictBlur`). nil =
        /// motion or exposure time unknown.
        var blurPx: Float?
        /// Same for the frame that opened the choice window = the frame builds before 2.70
        /// would have saved; blurPx0 − blurPx is what the choice gained.
        var blurPx0: Float?
        /// Seconds from that opening frame to this one (0 = the opening frame was kept).
        var win: Double?
        /// 🧪 TEST build only (ExposureCap, 2.70.1): the device's auto-exposure upper limit in
        /// force at capture, ms (finite). nil = key absent (every normal build).
        var expMaxMs: Float?
    }
    /// The ONE held copy of a choice window (main only). `buffer` is the recorder's own
    /// downscaled BGRA buffer — never an ARKit buffer.
    private struct Candidate {
        var buffer: CVPixelBuffer
        var depthRaw: Data?
        var depthW: Int
        var depthH: Int
        /// `file`/`depth` names are given at commit.
        var meta: ShotMeta
        /// Added to the session when the copy is MADE (capture-time map, as before 2.70) and
        /// removed when a sharper copy replaces it.
        var anchor: ARAnchor
        /// Predicted blur used for ranking; .infinity = motion unknown.
        var rank: Float
    }
    private struct ShotsFile: Encodable {
        let version: Int
        let note: String
        let shots: [ShotMeta]
    }

    // Trạng thái CHỈ đụng trên ioQueue
    private var metas: [ShotMeta] = []
    /// shot file → its ARAnchor (item 1, 26/09). The anchor leaves the session when
    /// thinOnDisk drops the shot or the JPEG write fails (no shot = no anchor).
    private var shotAnchors: [String: ARAnchor] = [:]
    private var thinningEvents = 0
    private var writeFailures = 0
    // Trạng thái CHỈ đụng trên main (tick + finish/cancel đều main)
    private var minInterval = TextureShotRecorder.startInterval
    private var approxShotCount = 0
    private var shotIndex = 0
    private var pendingEncodes = 0
    /// Time + pose of the last window-OPENING frame (= the frame the pre-2.70 rule saved).
    /// The interval / travel / turn gates measure from it, so the shot cadence is unchanged.
    private var lastShotTime: TimeInterval = 0
    private var lastShotPosition: SIMD3<Float>?
    private var lastShotQuat: simd_quatf?
    private var lastSeenFrameTime: TimeInterval = 0
    private var prevTickTime: TimeInterval = 0
    private var prevTickQuat: simd_quatf?
    private var prevTickPosition: SIMD3<Float>?
    private var isFinishing = false
    /// Choice window (2.70): open ⇔ `candidate != nil`.
    private var candidate: Candidate?
    private var windowOpenedAt: CFTimeInterval = 0
    private var windowCopies = 0
    private var windowBlur0: Float?

    /// ARKit's configurable primary camera (set by MeshScanController) — only READ here, for
    /// the per-shot white-balance gains. nil = no gains recorded.
    weak var captureDevice: AVCaptureDevice?
    /// Auto torch — per-shot `torch` level + skip frames right after a switch. nil = none.
    weak var torch: AutoTorch?
    /// 🧪 TEST build only (ExposureCap, 2.70.2): skip frames right after an exposure-limit change
    /// (AE still moving). Never settling outside the test build. nil = none.
    weak var exposureCap: ExposureCap?

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
        link.preferredFrameRateRange = Self.slowRate
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        let perfT0 = ScanPerfProfiler.tickBegin()
        defer { ScanPerfProfiler.tickEnd(.texShot, perfT0) }
        guard !isFinishing else { return }
        // Choice-window deadline on the HOST clock, before every frame gate: an interruption
        // (frozen frame) or a tracking loss must not keep the held copy — and its shot — waiting.
        if candidate != nil, CACurrentMediaTime() - windowOpenedAt >= Self.windowSec {
            commitCandidate()
        }
        guard let frame = arSession?.currentFrame else { return }
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
        // cách vứt CẢ GÓI — một khung hỏng không được phép giết hàng trăm khung tốt.
        // (Cùng triết lý guard NaN của ScanVideoRecorder.appendTrackSample.)
        let k = frame.camera.intrinsics
        guard k.columns.0.x.isFinite, k.columns.1.y.isFinite,
              k.columns.2.x.isFinite, k.columns.2.y.isFinite else { return }

        // Cổng "đang lia quá nhanh": đo tốc độ xoay giữa hai tick liên tiếp.
        // Cập nhật mốc tick TRƯỚC khi qua các cổng sau — mốc phải mới ở MỌI tick normal.
        // 2.70: the camera velocity too (blur prediction). Both unknown after a gap > 1 s
        // (turnRate 0 for the gate as before, velocity nil = motion unknown for the blur).
        var turnRate: Float = 0
        var velocity: SIMD3<Float>?
        if let prevQuat = prevTickQuat, let prevPos = prevTickPosition,
           frame.timestamp > prevTickTime, frame.timestamp - prevTickTime <= 1.0 {
            let dt = Float(frame.timestamp - prevTickTime)
            turnRate = Self.angleDeg(prevQuat, quat) / dt
            velocity = (pos - prevPos) / dt
        }
        prevTickQuat = quat
        prevTickPosition = pos
        prevTickTime = frame.timestamp

        // Window open and the camera left the cone around the opening frame: no later frame
        // shows that view any more → save the held copy now.
        if candidate != nil, let openPos = lastShotPosition, let openQuat = lastShotQuat,
           simd_distance(pos, openPos) > Self.maxDriftM
            || Self.angleDeg(openQuat, quat) > Self.maxDriftDeg {
            commitCandidate()
        }

        guard turnRate <= Self.maxTurnRateDegPerSec else { return }
        // Torch just switched: exposure is still moving (over/under-exposed frame).
        if let torch, torch.isSettling(at: frame.timestamp) { return }
        // Same for a test-build exposure-limit step (ExposureCap, 2.70.2).
        if let exposureCap, exposureCap.isSettling(at: frame.timestamp) { return }

        if let best = candidate?.rank {
            // Window open: this frame competes with the held copy.
            let (blurPx, rank) = predictBlur(frame: frame, cam2world: tf, intrinsics: k,
                                             turnRate: turnRate, velocity: velocity)
            let sharp = rank <= Self.sharpEnoughPx
            let better = rank < best * Self.improveFactor && best - rank >= Self.improveMinPx
            guard sharp || (better && windowCopies < Self.maxCopiesPerWindow) else { return }
            // No depth = ranked at the 2 m fallback (may look sharper than it is) and no white
            // coverage mark — never trade a held copy WITH depth for one without.
            if candidate?.depthRaw != nil, frame.sceneDepth == nil { return }
            let replaced = candidate?.anchor
            guard let copy = makeCandidate(frame: frame, cam2world: tf, intrinsics: k,
                                           blurPx: blurPx, rank: rank,
                                           reuse: candidate?.buffer) else { return }
            if let replaced { arSession?.remove(anchor: replaced) }
            candidate = copy
            windowCopies += 1
            if sharp { commitCandidate() }
            return
        }

        guard frame.timestamp - lastShotTime >= minInterval else { return }

        if let lastPos = lastShotPosition, let lastQuat = lastShotQuat {
            let moved = simd_distance(pos, lastPos)
            let turned = Self.angleDeg(lastQuat, quat)
            guard moved >= Self.minTravel || turned >= Self.minTurnDeg else { return }
        }

        guard pendingEncodes < Self.maxPendingEncodes else { return }

        // A shot is due: this frame (the one builds before 2.70 saved) opens the choice window
        // as its first copy — the fallback when no sharper frame comes.
        let (blurPx, rank) = predictBlur(frame: frame, cam2world: tf, intrinsics: k,
                                         turnRate: turnRate, velocity: velocity)
        guard let copy = makeCandidate(frame: frame, cam2world: tf, intrinsics: k,
                                       blurPx: blurPx, rank: rank, reuse: nil) else { return }
        candidate = copy
        windowOpenedAt = CACurrentMediaTime()
        windowCopies = 1
        windowBlur0 = blurPx
        lastShotTime = frame.timestamp
        lastShotPosition = pos
        lastShotQuat = quat
        if rank <= Self.sharpEnoughPx {
            commitCandidate()
        } else {
            displayLink?.preferredFrameRateRange = Self.fastRate
        }
    }

    /// Predicted motion blur of a frame, in STORED-image px: exposure time × image speed.
    /// Image speed ≈ fx·ω (rotation ω rad/s moves every pixel ~fx·ω; roll moves the centre
    /// less, so an upper bound) + fx·v⊥/d (a camera moving sideways at v⊥ m/s shifts a surface
    /// at depth d by fx·v⊥/d; motion along the view axis mostly zooms — left out).
    /// d = median LiDAR depth of the frame, 2 m without depth. No image work.
    /// Returns (blurPx to record — nil when motion or exposure time is unknown, rank for the
    /// choice — the assumed exposure when unknown, .infinity when motion is unknown).
    private func predictBlur(
        frame: ARFrame, cam2world tf: simd_float4x4, intrinsics k: simd_float3x3,
        turnRate: Float, velocity: SIMD3<Float>?
    ) -> (blurPx: Float?, rank: Float) {
        guard let velocity else { return (nil, .infinity) }
        let srcW = CVPixelBufferGetWidth(frame.capturedImage)
        guard srcW > 0 else { return (nil, .infinity) }
        let fx = k.columns.0.x * Float(min(1, CGFloat(Self.targetWidth) / CGFloat(srcW)))
        let axis = SIMD3(tf.columns.2.x, tf.columns.2.y, tf.columns.2.z)
        let lateral = velocity - simd_dot(velocity, axis) * axis
        let depth = max(0.3, Self.medianDepth(of: frame) ?? 2)
        let speed = fx * (turnRate * .pi / 180 + simd_length(lateral) / depth)
        guard speed.isFinite, speed >= 0 else { return (nil, .infinity) }
        let exp = Self.exposure(from: frame).exp
        let rank = speed * Float(exp ?? Self.assumedExposureSec)
        guard rank.isFinite else { return (nil, .infinity) }
        let rounded = (rank * 100).rounded() / 100
        let blurPx: Float? = exp != nil && rounded.isFinite ? rounded : nil
        return (blurPx, rank)
    }

    /// Median of a sparse 8×6 grid of the frame's LiDAR depth (finite, 0.25–5 m). The ARKit
    /// buffer is locked, read and unlocked inside this call (✗ keep it). nil = no depth.
    private static func medianDepth(of frame: ARFrame) -> Float? {
        guard let depthMap = frame.sceneDepth?.depthMap,
              CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferLockBaseAddress(depthMap, .readOnly) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)
        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        guard w > 0, h > 0, rowBytes >= w * 4 else { return nil }
        var samples: [Float] = []
        samples.reserveCapacity(48)
        for j in 0..<6 {
            let row = (base + ((2 * j + 1) * h / 12) * rowBytes)
                .assumingMemoryBound(to: Float32.self)
            for i in 0..<8 {
                let d = row[(2 * i + 1) * w / 16]
                if d.isFinite, d > 0.25, d < 5 { samples.append(d) }
            }
        }
        guard !samples.isEmpty else { return nil }
        samples.sort()
        return samples[samples.count / 2]
    }

    /// One window copy: downscales the camera image into the recorder's OWN buffer (`reuse` =
    /// the held copy's buffer) and copies the raw depth, on main — nothing of ARKit's outlives
    /// this call. Everything that can fail runs BEFORE the render, so a nil return leaves a
    /// reused buffer (= the held copy) intact.
    private func makeCandidate(
        frame: ARFrame, cam2world tf: simd_float4x4, intrinsics k: simd_float3x3,
        blurPx: Float?, rank: Float, reuse: CVPixelBuffer?
    ) -> Candidate? {
        let srcBuffer = frame.capturedImage
        let srcW = CVPixelBufferGetWidth(srcBuffer)
        let srcH = CVPixelBufferGetHeight(srcBuffer)
        guard srcW > 0, srcH > 0 else { return nil }
        let scale = min(1, CGFloat(Self.targetWidth) / CGFloat(srcW))
        let outW = Int((CGFloat(srcW) * scale).rounded())
        let outH = Int((CGFloat(srcH) * scale).rounded())

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
        let expo = Self.exposure(from: frame)
        var wbGains: [Float]?
        if let g = captureDevice?.deviceWhiteBalanceGains,
           g.redGain.isFinite, g.greenGain.isFinite, g.blueGain.isFinite {
            wbGains = [g.redGain, g.greenGain, g.blueGain]
        }
        let meta = ShotMeta(
            file: "",
            t: frame.timestamp,
            m: Self.columnMajor(tf),
            fx: k.columns.0.x * s, fy: k.columns.1.y * s,
            cx: k.columns.2.x * s, cy: k.columns.2.y * s,
            w: outW, h: outH,
            ev: evRaw.isFinite ? evRaw : 0,
            depth: nil,
            dw: depthRaw != nil ? depthW : nil,
            dh: depthRaw != nil ? depthH : nil,
            exp: expo.exp, iso: expo.iso, bv: expo.bv,
            wb: wbGains,
            torch: torch?.levelForShot,
            blurPx: blurPx,
            expMaxMs: ExposureCap.limitMsForShot(captureDevice)
        )

        // Thu nhỏ về buffer RIÊNG ngay trên main (GPU, ~vài ms) — sau dòng render này
        // không còn đụng gì tới buffer của ARKit nữa. A held copy's buffer is reused (same
        // size): at most ONE extra ~6MB buffer while a window is open.
        var outBuffer: CVPixelBuffer?
        if let reuse, CVPixelBufferGetWidth(reuse) == outW, CVPixelBufferGetHeight(reuse) == outH {
            outBuffer = reuse
        } else {
            let bufferAttrs = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ] as CFDictionary
            CVPixelBufferCreate(
                kCFAllocatorDefault, outW, outH, kCVPixelFormatType_32BGRA,
                bufferAttrs, &outBuffer
            )
        }
        guard let outBuffer else { return nil }
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
        // Item 1 (26/09): an anchor at the camera pose — ARKit moves it when it corrects the
        // map; `finish(finalAnchorPoses:)` writes its final pose as `m2`. Added HERE, at
        // capture, so it lives in the capture-time map (a copy committed after an interruption
        // or at Stop keeps a meaningful m2). Main thread (tick).
        let anchor = ARAnchor(name: Self.anchorName, transform: tf)
        arSession?.add(anchor: anchor)
        return Candidate(buffer: outBuffer, depthRaw: depthRaw, depthW: depthW, depthH: depthH,
                         meta: meta, anchor: anchor, rank: rank)
    }

    /// Saves the held copy as the next shot and closes the window (main; no-op without one).
    /// Numbering, counters, the ioQueue encode and the store cap all happen HERE, so a copy
    /// that gets replaced leaves no file and no number (its anchor was removed on replace).
    private func commitCandidate() {
        guard let copy = candidate else { return }
        candidate = nil
        displayLink?.preferredFrameRateRange = Self.slowRate
        shotIndex += 1
        var shotMeta = copy.meta
        shotMeta.file = String(format: "shot-%04d.jpg", shotIndex)
        shotMeta.depth = copy.depthRaw != nil ? String(format: "shot-%04d.depth", shotIndex) : nil
        shotMeta.blurPx0 = windowBlur0
        // lastShotTime = the opening frame's timestamp (no newer window can exist yet).
        let waited = shotMeta.t - lastShotTime
        if waited.isFinite { shotMeta.win = max(0, (waited * 100).rounded() / 100) }
        let meta = shotMeta
        let outBuffer = copy.buffer
        let depthRaw = copy.depthRaw
        let depthW = copy.depthW
        let depthH = copy.depthH
        let anchor = copy.anchor
        let tf = anchor.transform
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
                self?.shotAnchors[m.file] = anchor
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
            if !written { self?.writeFailures += 1 }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingEncodes -= 1
                // Ghi hỏng (đĩa đầy…) thì trả lại suất đếm — không thì trần maxShots mòn ảo.
                if !written {
                    self.approxShotCount -= 1
                    self.arSession?.remove(anchor: anchor)
                }
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
        thinningEvents += 1
        var kept: [ShotMeta] = []
        kept.reserveCapacity((metas.count + 1) / 2)
        var dropped: [ARAnchor] = []
        for (i, meta) in metas.enumerated() {
            if i % 2 == 0 {
                kept.append(meta)
            } else {
                if let anchor = shotAnchors.removeValue(forKey: meta.file) {
                    dropped.append(anchor)
                }
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
        // ARSession calls stay on main, like every other session call in the app.
        if !dropped.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let session = self?.arSession else { return }
                for anchor in dropped { session.remove(anchor: anchor) }
            }
        }
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
    ///
    /// `finalAnchorPoses`: identifier → transform of every non-mesh anchor in the LAST frame,
    /// read by MeshScanController BEFORE arSession.pause() (item 1, 26/09) → per-shot `m2`.
    /// `stats` = figures for scan-report.json, returned on every path (also with no shots).
    @MainActor
    func finish(finalAnchorPoses: [UUID: simd_float4x4]) async -> (
        dir: URL?, shotCount: Int, stats: ScanSessionReport.ShotStats
    ) {
        guard !isFinishing else { return (nil, 0, ScanSessionReport.ShotStats()) }
        isFinishing = true
        // Normally a no-op (stopTicking saved it). Before `taken` and before the package block:
        // its encode is queued first on the serial ioQueue, so shots.json lists it.
        commitCandidate()
        displayLink?.invalidate()
        displayLink = nil
        let dirURL = shotsDirURL
        let taken = shotIndex
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<(dir: URL?, shotCount: Int, stats: ScanSessionReport.ShotStats), Never>) in
            ioQueue.async { [weak self] in
                guard let self, !self.metas.isEmpty else {
                    try? FileManager.default.removeItem(at: dirURL.deletingLastPathComponent())
                    var stats = ScanSessionReport.ShotStats()
                    stats.taken = taken
                    stats.thinningEvents = self?.thinningEvents ?? 0
                    stats.writeFailures = self?.writeFailures ?? 0
                    continuation.resume(returning: (nil, 0, stats))
                    return
                }
                var stats = self.applyFinalPoses(finalAnchorPoses, taken: taken)
                let file = ShotsFile(
                    version: 1,
                    note: Self.shotsNote + Self.exposureCapNote,
                    shots: self.metas
                )
                do {
                    let data = try JSONEncoder().encode(file)
                    try data.write(to: dirURL.appendingPathComponent("shots.json"))
                    stats.packageWritten = true
                    continuation.resume(returning: (dir: dirURL, shotCount: self.metas.count, stats: stats))
                } catch {
                    // Thiếu shots.json thì ảnh vô dụng với máy trạm — dọn cả gói, đừng
                    // độn 50MB rác vào zip.
                    try? FileManager.default.removeItem(at: dirURL.deletingLastPathComponent())
                    continuation.resume(returning: (dir: nil, shotCount: 0, stats: stats))
                }
            }
        }
    }

    /// Stop taking shots (Stop & Save, before the final anchor poses are read). Pending
    /// encodes still land; `finish` writes the package as usual. Main thread.
    /// A held choice-window copy is SAVED, not dropped (it is the last shot). Its anchor was
    /// added when the copy was made; a copy made on the very last tick may still miss m2
    /// (anchor not yet in the final frame — accepted, as before 2.70).
    func stopTicking() {
        commitCandidate()
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Hủy (khách bấm Hủy buổi quét) — xoá sạch thư mục tạm.
    func cancel() {
        isFinishing = true
        candidate = nil
        displayLink?.invalidate()
        displayLink = nil
        let parent = shotsDirURL.deletingLastPathComponent()
        ioQueue.async {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    /// shots.json `note` — the projection contract the workstation reads (fuse.py appends to
    /// it: keep it a STRING). An array join rather than a `+` chain (CI type-check time).
    private static let shotsNote: String = [
        "ARKit: m = camera-to-world, column-major; camera looks -Z, +X right, ",
        "+Y up. Images kept in SENSOR orientation (landscape), no EXIF; ",
        "intrinsics match stored pixels. Pixel origin top-left, +u right, ",
        "+v down. Project world point P: q = inverse(m)*P; ",
        "u = fx*q.x/(-q.z) + cx; v = fy*(-q.y)/(-q.z) + cy; valid when q.z < 0. ",
        "t = ARKit frame timestamp (device clock, NOT video PTS). ",
        "ev = ARKit exposureOffset (EV). ",
        "Optional per-shot 'depth' file (dw*dh): raw DEFLATE, no zlib ",
        "header — Python: zlib.decompress(data, -15) -> Float32 ",
        "little-endian, row-major, meters, same sensor orientation as ",
        "the JPEG; scale intrinsics by dw/w, dh/h. Raw ARKit sceneDepth ",
        "(values may be non-finite) — reserved for future fusion, ",
        "no consumer yet. ",
        "Optional, recorded only (no consumer yet): m2 = final ARKit anchor ",
        "pose of the shot read at scan stop (map corrections such as loop ",
        "closure applied; same convention as m; m = pose at capture); ",
        "exp = exposure time (s), iso = ISO, bv = EXIF BrightnessValue, ",
        "from ARFrame.exifData; wb = white-balance gains [r,g,b] at capture; ",
        "torch = flashlight level at capture (0 = off, key absent = no torch ",
        "device) — torch-lit shots have a hotspot/falloff and a cold tint. ",
        "Since app 2.70 each shot is the least-blurred frame of a short choice ",
        "window (<= 0.8 s) opened when a shot fell due; blurPx = predicted motion ",
        "blur of this frame in stored-image px = exp * fx * (rotation rate rad/s + ",
        "sideways camera speed / median LiDAR depth, 2 m when no depth), from ",
        "consecutive ARKit poses (absent = motion or exposure unknown); blurPx0 = same ",
        "for the frame that opened the window, i.e. the frame older builds saved (its ",
        "motion is measured over the ~0.33 s before it, later frames over ~0.05 s); ",
        "win = seconds from that frame to this one.",
    ].joined()

    /// 🧪 TEST build only (ExposureCap, 2.70.1 / 2.70.2) — appended to `note`; "" in every other
    /// build.
    private static let exposureCapNote: String = ExposureCap.testBuild
        ? [
            " TEST BUILD: expMaxMs = the camera's auto-exposure upper limit (ms) read when the ",
            "frame was copied (within a frame of its capture; moves during the scan when ",
            "scan-report.json exposureCapMode = adaptive; frames within 0.3 s after a change ",
            "are skipped); exposureCapMs = the floor / fixed limit selected (0 = off).",
        ].joined()
        : ""

    /// ioQueue. Fills `m2` from the final anchor poses and builds the report figures.
    /// m2 only when all 16 numbers are finite (NaN rule: one bad number kills the package).
    private func applyFinalPoses(
        _ final: [UUID: simd_float4x4], taken: Int
    ) -> ScanSessionReport.ShotStats {
        var stats = ScanSessionReport.ShotStats()
        stats.taken = taken
        stats.kept = metas.count
        stats.thinningEvents = thinningEvents
        stats.writeFailures = writeFailures
        var moves: [Double] = []
        var turns: [Double] = []
        for i in metas.indices {
            let meta = metas[i]
            if meta.depth != nil { stats.withDepth += 1 }
            if meta.exp != nil || meta.iso != nil { stats.withExposure += 1 }
            if meta.wb != nil { stats.withWhiteBalance += 1 }
            if let l = meta.torch, l > 0 { stats.withTorch += 1 }
            guard let anchor = shotAnchors[meta.file],
                  let f = final[anchor.identifier] else { continue }
            let m2 = Self.columnMajor(f)
            guard m2.allSatisfy({ $0.isFinite }) else { continue }
            metas[i].m2 = m2
            stats.withFinalPose += 1
            // Delta vs the capture pose (the anchor was created AT `m`).
            let a = anchor.transform
            let move = simd_distance(SIMD3(a.columns.3.x, a.columns.3.y, a.columns.3.z),
                                     SIMD3(f.columns.3.x, f.columns.3.y, f.columns.3.z))
            let turn = Self.angleDeg(simd_normalize(simd_quatf(a)), simd_normalize(simd_quatf(f)))
            if move.isFinite { moves.append(Double(move) * 100) }
            if turn.isFinite { turns.append(Double(turn)) }
        }
        if !moves.isEmpty || !turns.isEmpty {
            moves.sort()
            turns.sort()
            stats.poseDelta = ScanSessionReport.PoseDelta(
                n: max(moves.count, turns.count),
                moveCmMedian: Self.quantile(moves, 0.5),
                moveCmP95: Self.quantile(moves, 0.95),
                moveCmMax: moves.last.flatMap { ScanSessionReport.fin($0) },
                turnDegMedian: Self.quantile(turns, 0.5),
                turnDegP95: Self.quantile(turns, 0.95),
                turnDegMax: turns.last.flatMap { ScanSessionReport.fin($0) }
            )
        }
        return stats
    }

    /// Nearest-rank quantile of a SORTED array; nil when empty.
    private static func quantile(_ sorted: [Double], _ q: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((q * Double(sorted.count)).rounded(.up)) - 1
        return ScanSessionReport.fin(sorted[min(sorted.count - 1, max(0, rank))])
    }

    /// Exposure figures from ARFrame.exifData (iOS 16+, app targets 17): finite, exp/iso > 0
    /// (bv may be negative), else nil. Reads the top level, or a nested {Exif} dictionary.
    private static func exposure(from frame: ARFrame) -> (exp: Double?, iso: Float?, bv: Float?) {
        var exif = frame.exifData
        if let nested = exif[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif = nested
        }
        func number(_ key: CFString) -> Double? {
            let value = exif[key as String]
            var d: Double?
            if let n = value as? NSNumber {
                d = n.doubleValue
            } else if let list = value as? [NSNumber], let first = list.first {
                d = first.doubleValue
            }
            guard let d, d.isFinite else { return nil }
            return d
        }
        var exp: Double?
        if let e = number(kCGImagePropertyExifExposureTime), e > 0 { exp = e }
        var iso: Float?
        if let i = number(kCGImagePropertyExifISOSpeedRatings), i > 0, Float(i).isFinite {
            iso = Float(i)
        }
        var bv: Float?
        if let b = number(kCGImagePropertyExifBrightnessValue), Float(b).isFinite { bv = Float(b) }
        return (exp, iso, bv)
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
