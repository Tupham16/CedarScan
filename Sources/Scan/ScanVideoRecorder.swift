import Foundation
import ARKit
import AVFoundation
import CoreImage
import UIKit

/// Quay video 480p quá trình quét bằng cách đọc ARSession.currentFrame theo nhịp CADisplayLink
/// (không chiếm delegate của ARSession — RoomPlan vẫn toàn quyền điều khiển phiên AR).
final class ScanVideoRecorder {
    // Video dọc 360x480 (khung camera 4:3 xoay dọc), ~8 fps, H.264 ~700 kbps.
    // Nhẹ hơn ~½ so với 480p/14fps mà vẫn đủ nét cho đội vẽ xem chi tiết
    // (người quét ít lia máy nên fps thấp không mất thông tin). File cũng nhẹ hơn → upload nhanh.
    private static let outputWidth = 360
    private static let outputHeight = 480

    let outputURL: URL

    /// File camera-track.json (nếu có bật ghi track) — chỉ khác nil SAU khi finish()
    /// trả về URL video thành công. Track đi kèm video: thiếu video thì track vô nghĩa.
    private(set) var cameraTrackURL: URL?

    private weak var arSession: ARSession?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var displayLink: CADisplayLink?
    private let ciContext = CIContext()
    private var firstTimestamp: TimeInterval?
    private var lastTimestamp: TimeInterval = 0
    private var isFinishing = false

    // MARK: Camera track (minimap kiểu CubiCasa)
    // Cờ opt-in mặc định TẮT — recorder dùng chung cho cả luồng RoomPlan lẫn Mesh;
    // chỉ MeshScanController bật (cùng pattern strictVertexCap của ColorMeshBuilder).
    // Ghi {t, vị trí, hướng nhìn ngang, tracking} lấy từ CHÍNH ARFrame vừa ghi vào
    // video trong tick() → t trùng khớp tuyệt đối với PTS video, không cần timer riêng.
    private let recordCameraTrack: Bool
    private struct TrackSample {
        let t: TimeInterval
        let x: Float
        let y: Float
        let z: Float
        let dx: Float
        let dz: Float
        let ok: Bool
    }
    private var trackSamples: [TrackSample] = []
    private var lastTrackTime: TimeInterval = -1

    init(arSession: ARSession, recordCameraTrack: Bool = false) {
        self.arSession = arSession
        self.recordCameraTrack = recordCameraTrack
        self.outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-video-\(UUID().uuidString.prefix(8)).mp4")
    }

    func start() {
        guard writer == nil else { return }
        try? FileManager.default.removeItem(at: outputURL)
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else { return }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Self.outputWidth,
            AVVideoHeightKey: Self.outputHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 700_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Self.outputWidth,
                kCVPixelBufferHeightKey as String: Self.outputHeight,
            ]
        )
        guard writer.canAdd(input) else { return }
        writer.add(input)
        guard writer.startWriting() else { return }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 6, maximum: 10, preferred: 8)
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    @objc private func tick() {
        guard !isFinishing,
              let frame = arSession?.currentFrame,
              frame.timestamp != lastTimestamp,
              let input, input.isReadyForMoreMediaData,
              let adaptor, let pool = adaptor.pixelBufferPool else {
            return
        }
        lastTimestamp = frame.timestamp
        if firstTimestamp == nil { firstTimestamp = frame.timestamp }

        var bufferOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &bufferOut)
        guard let buffer = bufferOut else { return }

        // Camera cho khung 4:3 nằm ngang → xoay dọc rồi thu về 480x640
        var image = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        let scale = CGFloat(Self.outputWidth) / image.extent.width
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        image = image.transformed(by: CGAffineTransform(
            translationX: -image.extent.origin.x,
            y: -image.extent.origin.y
        ))
        ciContext.render(
            image,
            to: buffer,
            bounds: CGRect(x: 0, y: 0, width: Self.outputWidth, height: Self.outputHeight),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let seconds = frame.timestamp - (firstTimestamp ?? frame.timestamp)
        adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600))
        if recordCameraTrack {
            appendTrackSample(frame: frame, at: seconds)
        }
    }

    /// Lấy mẫu vị trí + hướng camera từ ARFrame VỪA ghi vào video (t = PTS của khung đó).
    /// ~4Hz là đủ: viewer nội suy giữa các mẫu; 30 phút quét ≈ 7200 mẫu (~450KB JSON).
    private func appendTrackSample(frame: ARFrame, at t: TimeInterval) {
        guard trackSamples.isEmpty || t - lastTrackTime >= 0.24 else { return }
        let tf = frame.camera.transform
        // Hướng ống kính = -Z của camera.transform. KHÔNG cần viewMatrix(for:.portrait):
        // xoay giao diện chỉ quay quanh trục nhìn, không đổi vector nhìn của ống kính.
        var dx = -tf.columns.2.x
        var dz = -tf.columns.2.z
        if dx * dx + dz * dz < 0.04 {
            // Đang nhìn gần thẳng đứng (quét sàn/trần) → chiếu ngang của hướng nhìn ≈ 0,
            // mũi tên sẽ xoay loạn. Thay bằng trục DỌC MÁY: app portrait-only nên +X
            // camera trỏ về ĐUÔI máy (cạnh nút Home). CHÚC máy xuống sàn → đỉnh máy (-X)
            // ngả về phía trước = hướng người quét đối mặt; NGỬA máy lên trần thì ngược
            // lại — đuôi máy (+X) mới ngả về trước. Chọn dấu theo chiều đứng của hướng
            // nhìn để cả hai phía đều liên tục với nhánh -Z quanh ngưỡng (không lật 180°).
            let lookY = -tf.columns.2.y
            let s: Float = lookY < 0 ? -1 : 1
            dx = s * tf.columns.0.x
            dz = s * tf.columns.0.z
        }
        let len = (dx * dx + dz * dz).squareRoot()
        guard len > 0.001 else { return } // cả hai trục cùng thoái hóa (cực hiếm) — bỏ mẫu
        let px = tf.columns.3.x
        let py = tf.columns.3.y
        let pz = tf.columns.3.z
        // Tracking chập chờn có thể cho transform NaN/Inf — String(format:) sẽ ghi "nan"
        // làm VỠ cả file JSON. Bỏ mẫu hỏng, giữ file sạch.
        guard px.isFinite, py.isFinite, pz.isFinite, dx.isFinite, dz.isFinite else { return }
        var ok = false
        if case .normal = frame.camera.trackingState { ok = true }
        lastTrackTime = t
        trackSamples.append(TrackSample(
            t: t,
            x: px, y: py, z: pz,
            dx: dx / len, dz: dz / len,
            ok: ok
        ))
    }

    /// Ghi camera-track.json ra file tạm (gọi sau khi video hoàn tất). Ghi tay từng dòng
    /// cho gọn file (mảng phẳng thay vì object mỗi mẫu) và nhẹ cho type-checker.
    private func writeCameraTrackFile() {
        guard recordCameraTrack, !trackSamples.isEmpty else { return }
        var text = "{\"version\":1,\n"
        text += "\"coordinateSpace\":\"ARKit world: right-handed, Y-up, meters. "
        text += "t = seconds from video start (PTS-aligned). "
        text += "(dx,dz) = unit horizontal look direction in the X-Z plane. "
        text += "ok: 1 = tracking normal, 0 = limited/interrupted.\",\n"
        text += "\"fields\":[\"t\",\"x\",\"y\",\"z\",\"dx\",\"dz\",\"ok\"],\n\"samples\":[\n"
        for (i, s) in trackSamples.enumerated() {
            let sep = i == trackSamples.count - 1 ? "\n" : ",\n"
            let line = String(
                format: "[%.2f,%.3f,%.3f,%.3f,%.3f,%.3f,%d]",
                s.t, Double(s.x), Double(s.y), Double(s.z),
                Double(s.dx), Double(s.dz), s.ok ? 1 : 0
            )
            text += line + sep
        }
        text += "]}\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("camera-track-\(UUID().uuidString.prefix(8)).json")
        do {
            try Data(text.utf8).write(to: url)
            cameraTrackURL = url
        } catch {
            cameraTrackURL = nil // track hỏng không được chặn việc lưu video/mesh
        }
    }

    /// Kết thúc quay; trả về URL file video (hoặc nil nếu chưa quay được khung nào).
    /// @MainActor: tick() chạy trên main (CADisplayLink) — thân hàm cùng actor thì
    /// invalidate/đọc trackSamples không đua với tick (hàm async không isolation sẽ
    /// chạy thân hàm trên executor NỀN theo SE-0338).
    @MainActor
    func finish() async -> URL? {
        guard let writer, let input, !isFinishing else { return nil }
        isFinishing = true
        displayLink?.invalidate()
        displayLink = nil

        guard firstTimestamp != nil, writer.status == .writing else {
            writer.cancelWriting()
            return nil
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { return nil }
        writeCameraTrackFile()
        return outputURL
    }

    /// Hủy quay (khi khách bấm Hủy) — xoá file tạm.
    func cancel() {
        isFinishing = true
        displayLink?.invalidate()
        displayLink = nil
        writer?.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
    }
}
