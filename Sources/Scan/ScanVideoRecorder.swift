import Foundation
import ARKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Quay video 480p quá trình quét bằng cách đọc ARSession.currentFrame theo nhịp CADisplayLink
/// (không chiếm delegate của ARSession — RoomPlan vẫn toàn quyền điều khiển phiên AR).
///
/// N7 (2.79) — SEGMENTS. iOS takes the hardware encoder away from an app that leaves the screen;
/// with ONE writer for the whole scan the writer failed, `finish()` returned nil and the scan lost
/// its whole video and camera-track.json (the minimap). Now:
///  - frames are recorded only while the app is active; each time it comes back a NEW segment
///    file starts (its own writer, PTS from 0);
///  - the open segment is finished at once when the app is about to leave (willResignActive) or
///    ARKit is interrupted (`endSegment()`), under a short background task — the encoder is still
///    ours at that moment;
///  - movie fragments (1 s, then every 5 s) keep a segment whose writer failed anyway readable up
///    to its last fragment;
///  - `finish()` joins the segments end to end (AVMutableComposition + passthrough export: no
///    re-encode, no encoder needed) and writes camera-track.json on the joined timeline (each
///    segment's samples shifted by where it starts). Join failed = the longest segment is kept.
/// So a lock / call / app switch mid-scan costs only the seconds the camera was off.
/// Main thread only (CADisplayLink, notifications on .main, `finish` is @MainActor).
final class ScanVideoRecorder {
    // Video dọc 360x480 (khung camera 4:3 xoay dọc), ~8 fps, H.264 ~700 kbps.
    // Nhẹ hơn ~½ so với 480p/14fps mà vẫn đủ nét cho đội vẽ xem chi tiết
    // (người quét ít lia máy nên fps thấp không mất thông tin). File cũng nhẹ hơn → upload nhanh.
    // T5 (2.79): the bitrate is `ScanQualityConfig.videoBitrateKbps` (server-tunable, default 700).
    private static let outputWidth = 360
    private static let outputHeight = 480
    /// A runaway (app switched every few seconds) must not fill the disk with tiny files.
    private static let maxSegments = 64

    let outputURL: URL

    /// File camera-track.json (nếu có bật ghi track) — chỉ khác nil SAU khi finish()
    /// trả về URL video thành công. Track đi kèm video: thiếu video thì track vô nghĩa.
    private(set) var cameraTrackURL: URL?

    /// scan-report.json `save.video` (2.78), set by `finish()`: "ok", "partial" (2.79: the video
    /// exists but a part was lost — see `segmentFields`), "notStarted" (no writer ever started),
    /// "noFrames", or "failed" with the last failed writer's status raw value and error codes
    /// ("domain:code", then the underlying error's). Diagnostics only.
    private(set) var finishStatus = "notFinished"
    private(set) var writerStatus: Int?
    private(set) var writerError: String?
    /// 2.79 `save` keys: videoSegments, videoRecovered, videoLost, videoJoin, videoKbps.
    private(set) var segmentFields: [String: any Sendable] = [:]

    private weak var arSession: ARSession?
    private let bitrateKbps: Int
    private var displayLink: CADisplayLink?
    private let ciContext = CIContext()
    /// T5 (2.79): 1440 → 360 is a 4× reduction; a plain affine scale samples ~1 of every 16
    /// source pixels (aliasing: shimmering edges, moiré on tiles). One reused filter, main only.
    private let lanczos = CIFilter.lanczosScaleTransform()
    private var lastTimestamp: TimeInterval = 0
    private var isFinishing = false
    private var observers: [NSObjectProtocol] = []

    /// One writer = one file. Main thread only; the writer's completion handler hops to main.
    private final class Segment: @unchecked Sendable {
        let url: URL
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        var firstTimestamp: TimeInterval?
        var frames = 0
        var track: [TrackSample] = []
        var lastTrackTime: TimeInterval = -1
        /// Writer status once closed (`.unknown` = still open / closing).
        var result: AVAssetWriter.Status = .unknown
        var error: String?
        var keepAlive: UIBackgroundTaskIdentifier = .invalid

        init(url: URL, writer: AVAssetWriter, input: AVAssetWriterInput,
             adaptor: AVAssetWriterInputPixelBufferAdaptor) {
            self.url = url
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
        }
    }
    private var current: Segment?
    /// Closed (or closing) segments that hold frames, in recording order.
    private var segments: [Segment] = []
    private var opened = 0
    /// finishWriting calls in flight — `finish()` waits for them.
    private let closing = DispatchGroup()
    /// After a writer could not start: no new attempt before this (CACurrentMediaTime).
    private var retryAt: CFTimeInterval = 0

    // MARK: Camera track (minimap kiểu CubiCasa)
    // Cờ opt-in mặc định TẮT — recorder dùng chung cho cả luồng RoomPlan lẫn Mesh;
    // chỉ MeshScanController bật (cùng pattern strictVertexCap của ColorMeshBuilder).
    // Ghi {t, vị trí, hướng nhìn ngang, tracking} lấy từ CHÍNH ARFrame vừa ghi vào
    // video trong tick() → t trùng khớp tuyệt đối với PTS video, không cần timer riêng.
    // 2.79: t = the segment's PTS while recording; `finish()` shifts it onto the joined video.
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

    init(arSession: ARSession, recordCameraTrack: Bool = false) {
        self.arSession = arSession
        self.recordCameraTrack = recordCameraTrack
        let id = UUID().uuidString.prefix(8)
        self.outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-video-\(id).mp4")
        bitrateKbps = Int(ScanQualityConfig.current.videoBitrateKbps.rounded())
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func start() {
        guard displayLink == nil, !isFinishing else { return }
        try? FileManager.default.removeItem(at: outputURL)
        segmentFields["videoKbps"] = bitrateKbps
        // The encoder is lost in the background: close the segment while it is still ours.
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.endSegment()
        })
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 6, maximum: 10, preferred: 8)
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    /// A new writer for the next segment; nil = could not start (retried 2 s later).
    private func openSegment() -> Segment? {
        guard opened < Self.maxSegments, CACurrentMediaTime() >= retryAt else { return nil }
        let url = outputURL.deletingPathExtension()
            .appendingPathExtension("part\(opened)").appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: url)
        retryAt = CACurrentMediaTime() + 2
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        // N7: a failed writer leaves a file playable up to its last fragment (first after 1 s).
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
        writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Self.outputWidth,
            AVVideoHeightKey: Self.outputHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrateKbps * 1000,
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
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        writer.startSession(atSourceTime: .zero)
        opened += 1
        retryAt = 0
        return Segment(url: url, writer: writer, input: input, adaptor: adaptor)
    }

    @objc private func tick() {
        guard !isFinishing,
              let frame = arSession?.currentFrame,
              frame.timestamp != lastTimestamp,
              // N7: the encoder is ours only on screen — nothing is recorded meanwhile.
              UIApplication.shared.applicationState == .active else {
            return
        }
        // A writer that failed while recording keeps its file (fragments) and makes way.
        if let open = current, open.writer.status == .failed {
            endSegment()
        }
        if current == nil {
            current = openSegment()
        }
        guard let segment = current, segment.input.isReadyForMoreMediaData,
              let pool = segment.adaptor.pixelBufferPool else {
            return
        }
        lastTimestamp = frame.timestamp
        if segment.firstTimestamp == nil { segment.firstTimestamp = frame.timestamp }

        var bufferOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &bufferOut)
        guard let buffer = bufferOut else { return }

        // Camera cho khung 4:3 nằm ngang → xoay dọc rồi thu về 360x480 bằng Lanczos (T5).
        // Clamped first so the filter's border taps see the edge pixels, not transparent black;
        // then cut back to the scaled frame.
        let source = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { return }
        let scale = CGFloat(Self.outputWidth) / extent.width
        lanczos.inputImage = source.clampedToExtent()
        lanczos.scale = Float(scale)
        lanczos.aspectRatio = 1
        guard let scaled = lanczos.outputImage else { return }
        let frameRect = CGRect(
            x: extent.minX * scale, y: extent.minY * scale,
            width: CGFloat(Self.outputWidth), height: CGFloat(Self.outputHeight)
        )
        let image = scaled.cropped(to: frameRect)
            .transformed(by: CGAffineTransform(translationX: -frameRect.minX, y: -frameRect.minY))
        ciContext.render(
            image,
            to: buffer,
            bounds: CGRect(x: 0, y: 0, width: Self.outputWidth, height: Self.outputHeight),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let seconds = frame.timestamp - (segment.firstTimestamp ?? frame.timestamp)
        guard segment.adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600)) else {
            return
        }
        segment.frames += 1
        if recordCameraTrack {
            appendTrackSample(to: segment, frame: frame, at: seconds)
        }
    }

    /// Lấy mẫu vị trí + hướng camera từ ARFrame VỪA ghi vào video (t = PTS của khung đó).
    /// ~4Hz là đủ: viewer nội suy giữa các mẫu; 30 phút quét ≈ 7200 mẫu (~450KB JSON).
    private func appendTrackSample(to segment: Segment, frame: ARFrame, at t: TimeInterval) {
        guard segment.track.isEmpty || t - segment.lastTrackTime >= 0.24 else { return }
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
        segment.lastTrackTime = t
        segment.track.append(TrackSample(
            t: t,
            x: px, y: py, z: pz,
            dx: dx / len, dz: dz / len,
            ok: ok
        ))
    }

    /// Ends the open segment, if any (app leaving the screen, ARKit interruption, a failed
    /// writer, Stop). The next frame on screen opens a new one. Idempotent.
    func endSegment() {
        guard let segment = current else { return }
        current = nil
        guard segment.frames > 0 else {
            if segment.writer.status == .writing { segment.writer.cancelWriting() }
            try? FileManager.default.removeItem(at: segment.url)
            return
        }
        segments.append(segment)
        // markAsFinished / finishWriting raise (not throw) unless the writer is still writing.
        guard segment.writer.status == .writing else {
            Self.noteResult(segment)
            return
        }
        segment.input.markAsFinished()
        // A few frames to flush + the file index: keep the process alive for that if the app is
        // on its way to the background. The handler ENDS it (L1's rule: a held task = killed).
        segment.keepAlive = UIApplication.shared.beginBackgroundTask(withName: "scan-video-segment") {
            DispatchQueue.main.async {
                Self.endKeepAlive(segment)
            }
        }
        closing.enter()
        let group = closing
        segment.writer.finishWriting {
            DispatchQueue.main.async {
                Self.noteResult(segment)
                Self.endKeepAlive(segment)
                group.leave()
            }
        }
    }

    private static func noteResult(_ segment: Segment) {
        segment.result = segment.writer.status
        guard segment.result != .completed, let failure = segment.writer.error else { return }
        segment.error = errorCodes(failure)
    }

    private static func endKeepAlive(_ segment: Segment) {
        let id = segment.keepAlive
        segment.keepAlive = .invalid
        if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
    }

    private static func errorCodes(_ failure: Error) -> String {
        let error = failure as NSError
        var codes = "\(error.domain):\(error.code)"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            codes += " \(underlying.domain):\(underlying.code)"
        }
        return codes
    }

    /// Ghi camera-track.json ra file tạm (gọi sau khi video hoàn tất). Ghi tay từng dòng
    /// cho gọn file (mảng phẳng thay vì object mỗi mẫu) và nhẹ cho type-checker.
    /// 2.79: `samples` already on the delivered video's timeline (format unchanged).
    private func writeCameraTrackFile(_ samples: [TrackSample]) {
        guard recordCameraTrack, !samples.isEmpty else { return }
        var text = "{\"version\":1,\n"
        text += "\"coordinateSpace\":\"ARKit world: right-handed, Y-up, meters. "
        text += "t = seconds from video start (PTS-aligned). "
        text += "(dx,dz) = unit horizontal look direction in the X-Z plane. "
        text += "ok: 1 = tracking normal, 0 = limited/interrupted.\",\n"
        text += "\"fields\":[\"t\",\"x\",\"y\",\"z\",\"dx\",\"dz\",\"ok\"],\n\"samples\":[\n"
        for (i, s) in samples.enumerated() {
            let sep = i == samples.count - 1 ? "\n" : ",\n"
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
    /// invalidate/đọc trạng thái không đua với tick (hàm async không isolation sẽ
    /// chạy thân hàm trên executor NỀN theo SE-0338).
    /// 2.79: closes the open segment, waits for every segment to finish, keeps the readable
    /// ones, joins them (≥ 2) and writes camera-track.json on the joined timeline.
    @MainActor
    func finish() async -> URL? {
        guard !isFinishing else { return nil }
        isFinishing = true
        displayLink?.invalidate()
        displayLink = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        endSegment()
        let group = closing
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .main) { continuation.resume() }
        }

        guard opened > 0 else {
            finishStatus = "notStarted"
            return nil
        }
        guard !segments.isEmpty else {
            finishStatus = "noFrames"
            return nil
        }
        // Readable parts: a completed file, or a failed one up to its last movie fragment.
        var parts: [(segment: Segment, track: AVAssetTrack, range: CMTimeRange)] = []
        var recovered = 0
        var lost = 0
        for segment in segments {
            if segment.result != .completed {
                writerStatus = segment.result.rawValue
                writerError = segment.error
            }
            guard let readable = await Self.readableTrack(segment.url) else {
                lost += 1
                try? FileManager.default.removeItem(at: segment.url)
                continue
            }
            if segment.result != .completed { recovered += 1 }
            parts.append((segment, readable.track, readable.range))
        }
        segmentFields["videoSegments"] = segments.count
        segmentFields["videoRecovered"] = recovered
        segmentFields["videoLost"] = lost
        guard !parts.isEmpty else {
            finishStatus = "failed"
            segmentFields["videoJoin"] = "none"
            return nil
        }

        var kept = parts
        var offsets = [0.0]
        var joined = false
        if parts.count > 1 {
            switch await join(parts.map { (track: $0.track, range: $0.range) }) {
            case .success(let starts):
                offsets = starts
                joined = true
                segmentFields["videoJoin"] = "ok"
            case .failure(let error):
                segmentFields["videoJoin"] = "failed:" + Self.errorCodes(error)
                // Keep the longest part; the others are lost.
                let longest = parts.indices.max { parts[$0].range.duration < parts[$1].range.duration } ?? 0
                kept = [parts[longest]]
            }
        } else {
            segmentFields["videoJoin"] = "none"
        }
        if !joined {
            // One file is the video: under the output name.
            try? FileManager.default.removeItem(at: outputURL)
            guard (try? FileManager.default.moveItem(at: kept[0].segment.url, to: outputURL)) != nil else {
                finishStatus = "failed"
                parts.forEach { try? FileManager.default.removeItem(at: $0.segment.url) }
                return nil
            }
        }
        // The segment files are no longer needed (joined, or not kept).
        for part in parts where part.segment.url != outputURL {
            try? FileManager.default.removeItem(at: part.segment.url)
        }
        let complete = recovered == 0 && lost == 0 && kept.count == parts.count
        finishStatus = complete ? "ok" : "partial"

        // camera-track.json: each kept segment's samples, shifted to where it starts in the
        // video, cut at its readable end (a recovered segment may end before its last sample).
        var samples: [TrackSample] = []
        for (index, part) in kept.enumerated() {
            let shift = offsets[min(index, offsets.count - 1)] - part.range.start.seconds
            let end = part.range.end.seconds
            for s in part.segment.track where s.t <= end + 0.01 {
                samples.append(TrackSample(t: s.t + shift, x: s.x, y: s.y, z: s.z,
                                           dx: s.dx, dz: s.dz, ok: s.ok))
            }
        }
        writeCameraTrackFile(samples)
        return outputURL
    }

    /// The video track of a segment file and its time range; nil = unreadable / empty.
    private static func readableTrack(_ url: URL) async -> (track: AVAssetTrack, range: CMTimeRange)? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let range = try? await track.load(.timeRange),
              range.duration.isNumeric, range.duration.seconds > 0 else {
            return nil
        }
        return (track, range)
    }

    private enum JoinError: Error { case noTrack, noExport, export(Error?) }

    /// Segments end to end into `outputURL`, passthrough (no re-encode). Success = where each
    /// segment starts in the joined video (seconds).
    @MainActor
    private func join(_ parts: [(track: AVAssetTrack, range: CMTimeRange)]) async -> Result<[Double], Error> {
        let composition = AVMutableComposition()
        guard let target = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return .failure(JoinError.noTrack)
        }
        var cursor = CMTime.zero
        var starts: [Double] = []
        do {
            for part in parts {
                try target.insertTimeRange(part.range, of: part.track, at: cursor)
                starts.append(cursor.seconds)
                cursor = cursor + part.range.duration
            }
        } catch {
            return .failure(error)
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            return .failure(JoinError.noExport)
        }
        try? FileManager.default.removeItem(at: outputURL)
        export.outputURL = outputURL
        export.outputFileType = .mp4
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            return .failure(export.error ?? JoinError.export(nil))
        }
        return .success(starts)
    }

    /// Hủy quay (khi khách bấm Hủy) — xoá file tạm.
    func cancel() {
        isFinishing = true
        displayLink?.invalidate()
        displayLink = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if let open = current, open.writer.status == .writing {
            open.writer.cancelWriting()
        }
        if let open = current { try? FileManager.default.removeItem(at: open.url) }
        current = nil
        // Closing segments: their finish lands on deleted paths' writers — remove after.
        let urls = segments.map(\.url)
        segments = []
        closing.notify(queue: .main) {
            urls.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        try? FileManager.default.removeItem(at: outputURL)
    }
}
