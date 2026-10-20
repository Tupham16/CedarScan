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
///  - frames are recorded only while the app is active; after every cut a NEW segment file starts
///    (its own writer, PTS from 0);
///  - cuts: the app about to leave the screen (willResignActive), an ARKit interruption
///    (`endSegment()`), a writer that failed, a gap of more than `maxGapSec` between frames. The
///    open segment is finished at once, under a short background task — at willResignActive the
///    encoder is still ours;
///  - 🔴 STALE FRAMES: after a cut or a return to the screen ARKit serves its last pre-cut frame
///    again until the camera is back (the 1.3 profiler's camResumeGuard). Recording it would put
///    the whole time away into the video as one frozen frame, so frames captured before
///    `staleBefore` (ARFrame.timestamp runs on CACurrentMediaTime's clock) are skipped;
///  - movie fragments (1 s, then every 5 s) keep a segment whose writer failed anyway readable up
///    to its last fragment (a writer that finishes normally writes a regular MP4);
///  - `finish()` keeps the readable segments, joins them end to end (AVMutableComposition +
///    passthrough export: no re-encode, no encoder needed — also run for a lone recovered segment,
///    so a regular MP4 is delivered) and writes camera-track.json on the delivered timeline (each
///    segment's samples shifted by where it starts). Join failed = retried without the recovered
///    segments, then the longest segment is kept.
/// So a lock / call / app switch mid-scan costs only the seconds the camera was off.
/// Main thread only (CADisplayLink, notifications on .main, `finish` is @MainActor).
final class ScanVideoRecorder {
    // Video dọc 360x480 (khung camera 4:3 xoay dọc), ~8 fps, H.264 ~700 kbps.
    // Nhẹ hơn ~½ so với 480p/14fps mà vẫn đủ nét cho đội vẽ xem chi tiết
    // (người quét ít lia máy nên fps thấp không mất thông tin). File cũng nhẹ hơn → upload nhanh.
    // T5 (2.79): the bitrate is `ScanQualityConfig.videoBitrateKbps` (server-tunable, default 700).
    private static let outputWidth = 360
    private static let outputHeight = 480
    /// A runaway (app switched every few seconds) must not fill the disk with tiny files: segments
    /// WITH frames beyond this are not recorded.
    private static let maxSegments = 64
    /// Frames further apart than this inside one segment (frames stopped while the app stayed on
    /// screen) = a cut, so the video never shows a long frozen frame.
    private static let maxGapSec: TimeInterval = 1
    /// A writer that could not start or failed: no new one before this many seconds.
    private static let retryDelaySec: CFTimeInterval = 2
    /// `finish()` waits this long for segment writers still finishing (normally well under a
    /// second); past it they count as LOST — a file its writer may still be writing is never
    /// read or delivered. Stop & Save must not hang on a finish that never lands.
    private static let closingWaitSec: Double = 60
    /// One frame at ~8 fps: each segment ends one frame after its last one, so a part's last
    /// frame (and a one-frame part) keeps a duration in the joined video.
    private static let lastFrameSec: Double = 0.125

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
    /// Error of the last writer that would not start (reported only when none ever started).
    private var startError: String?
    /// 2.79 `save` keys: videoSegments, videoRecovered, videoLost, videoJoin, videoKbps.
    private(set) var segmentFields: [String: any Sendable] = [:]

    private weak var arSession: ARSession?
    private let bitrateKbps: Int
    private var displayLink: CADisplayLink?
    private let ciContext = CIContext()
    /// T5 (2.79): 1440 → 360 is a 4× reduction; a plain affine scale samples ~1 of every 16
    /// source pixels (aliasing: shimmering edges, moiré on tiles). One reused filter, main only;
    /// its input is cleared after every frame (it would pin ARKit's camera buffer otherwise).
    private let lanczos = CIFilter.lanczosScaleTransform()
    private var lastTimestamp: TimeInterval = 0
    /// See the type comment (STALE FRAMES).
    private var staleBefore: TimeInterval = 0
    private var isFinishing = false
    private var observers: [NSObjectProtocol] = []

    /// The segment being recorded: its writer and its frames' track samples. Main thread only.
    private final class Segment {
        let url: URL
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        var firstTimestamp: TimeInterval?
        var lastAppended: TimeInterval?
        var frames = 0
        var track: [TrackSample] = []
        var lastTrackTime: TimeInterval = -1

        init(url: URL, writer: AVAssetWriter, input: AVAssetWriterInput,
             adaptor: AVAssetWriterInputPixelBufferAdaptor) {
            self.url = url
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
        }
    }

    /// A closed segment with frames: its file and what `finish()` needs. The writer is kept only
    /// until its finish lands (the input, adaptor and pixel-buffer pool go at the cut). Main
    /// thread only; the writer's completion handler hops to main.
    private final class Part: @unchecked Sendable {
        let url: URL
        let track: [TrackSample]
        /// Held until the finish lands (also after a timeout: freeing a writer mid-finish could
        /// cancel it and delete its file).
        var closingWriter: AVAssetWriter?
        /// `finish()` stopped waiting for it: lost, whatever lands later.
        var timedOut = false
        /// Writer status once closed (`.unknown` = still finishing).
        var result: AVAssetWriter.Status = .unknown
        var error: String?
        var keepAlive: UIBackgroundTaskIdentifier = .invalid
        var keepAliveExpired = false

        init(url: URL, track: [TrackSample]) {
            self.url = url
            self.track = track
        }
    }

    /// A readable part ready to be joined. The ASSET is kept here on purpose:
    /// `AVAssetTrack.asset` is weak, a track whose asset is gone cannot be inserted.
    private struct Readable {
        let part: Part
        let asset: AVURLAsset
        let track: AVAssetTrack
        let range: CMTimeRange
    }

    private var current: Segment?
    /// Closed (or finishing) segments that hold frames, in recording order.
    private var parts: [Part] = []
    /// Writers created (names the files) / writers that started / writers that would not start.
    private var opened = 0
    private var started = 0
    private var startFailures = 0
    /// A new segment was refused at `maxSegments`: the rest of the scan has no video.
    private var capped = false
    /// finishWriting calls in flight — `finish()` waits for them.
    private let closing = DispatchGroup()
    /// No new writer before this (CACurrentMediaTime).
    private var retryAt: CFTimeInterval = 0

    // MARK: Camera track (minimap kiểu CubiCasa)
    // Cờ opt-in mặc định TẮT — recorder dùng chung cho cả luồng RoomPlan lẫn Mesh;
    // chỉ MeshScanController bật (cùng pattern strictVertexCap của ColorMeshBuilder).
    // Ghi {t, vị trí, hướng nhìn ngang, tracking} lấy từ CHÍNH ARFrame vừa ghi vào
    // video trong tick() → t trùng khớp tuyệt đối với PTS video, không cần timer riêng.
    // 2.79: t = the segment's PTS while recording; `finish()` shifts it onto the delivered video.
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
        let center = NotificationCenter.default
        // The encoder is lost in the background: close the segment while it is still ours.
        observers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.endSegment()
        })
        // Back on screen: frames from before this moment are the frozen pre-cut ones.
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.staleBefore = max(self.staleBefore, CACurrentMediaTime())
        })
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 6, maximum: 10, preferred: 8)
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    /// A new writer for the next segment; nil = cannot start now (retried `retryDelaySec` later).
    private func openSegment() -> Segment? {
        guard parts.count < Self.maxSegments else {
            capped = true
            return nil
        }
        guard CACurrentMediaTime() >= retryAt else { return nil }
        let url = outputURL.deletingPathExtension()
            .appendingPathExtension("part\(opened)").appendingPathExtension("mp4")
        opened += 1
        try? FileManager.default.removeItem(at: url)
        retryAt = CACurrentMediaTime() + Self.retryDelaySec
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
            startFailures += 1
            startError = writer.error.map(Self.errorCodes) ?? "status:\(writer.status.rawValue)"
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        writer.startSession(atSourceTime: .zero)
        started += 1
        retryAt = 0
        return Segment(url: url, writer: writer, input: input, adaptor: adaptor)
    }

    @objc private func tick() {
        guard !isFinishing,
              let frame = arSession?.currentFrame,
              frame.timestamp != lastTimestamp,
              frame.timestamp > staleBefore,
              // N7: the encoder is ours only on screen — nothing is recorded meanwhile.
              UIApplication.shared.applicationState == .active else {
            return
        }
        // A writer that failed while recording keeps its file (fragments) and makes way; frames
        // that stopped coming for a while start a new segment (no frozen stretch in the video).
        if let open = current {
            // Near the cap a gap is recorded as before 2.79 (a held frame), so the cap can only
            // be reached by real cuts.
            let gap = parts.count < Self.maxSegments - 1
                && (open.lastAppended.map { frame.timestamp - $0 > Self.maxGapSec } ?? false)
            if open.writer.status == .failed || gap {
                closeSegment()
            }
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
        // ✗ keep ARKit's camera buffer past this tick (small pool: tracking suffers).
        defer { lanczos.inputImage = nil }
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
        segment.lastAppended = frame.timestamp
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

    /// The camera stops for a while (app leaving the screen, ARKit interruption): ends the open
    /// segment and marks every frame captured until now as stale. The first frame after it on
    /// screen opens the next segment. Idempotent.
    func endSegment() {
        staleBefore = max(staleBefore, CACurrentMediaTime())
        closeSegment()
    }

    /// Closes the open segment, if any.
    private func closeSegment() {
        guard let segment = current else { return }
        current = nil
        let writer = segment.writer
        guard segment.frames > 0 else {
            if writer.status == .writing { writer.cancelWriting() }
            if writer.status == .failed { retryAt = CACurrentMediaTime() + Self.retryDelaySec }
            try? FileManager.default.removeItem(at: segment.url)
            return
        }
        let part = Part(url: segment.url, track: segment.track)
        parts.append(part)
        // markAsFinished / finishWriting raise (not throw) unless the writer is still writing.
        guard writer.status == .writing else {
            Self.note(writer, in: part)
            if writer.status == .failed { retryAt = CACurrentMediaTime() + Self.retryDelaySec }
            return
        }
        if let first = segment.firstTimestamp, let last = segment.lastAppended {
            writer.endSession(atSourceTime: CMTime(
                seconds: last - first + Self.lastFrameSec, preferredTimescale: 600
            ))
        }
        segment.input.markAsFinished()
        part.closingWriter = writer
        // A few frames to flush + the file index: keep the process alive for that if the app is
        // on its way to the background. The handler ENDS the task before it returns (L1: a task
        // still held when its time is up = app killed); UIKit calls it on main.
        part.keepAlive = UIApplication.shared.beginBackgroundTask(withName: "scan-video-segment") {
            part.keepAliveExpired = true
            if Thread.isMainThread {
                Self.endKeepAlive(part)
            } else {
                DispatchQueue.main.async { Self.endKeepAlive(part) }
            }
        }
        // The handler can run inside `beginBackgroundTask` when no time is left at all.
        if part.keepAliveExpired { Self.endKeepAlive(part) }
        closing.enter()
        let group = closing
        writer.finishWriting {
            DispatchQueue.main.async {
                if !part.timedOut, let finished = part.closingWriter {
                    Self.note(finished, in: part)
                }
                part.closingWriter = nil
                Self.endKeepAlive(part)
                group.leave()
            }
        }
    }

    private static func note(_ writer: AVAssetWriter, in part: Part) {
        part.result = writer.status
        guard part.result != .completed, let failure = writer.error else { return }
        part.error = errorCodes(failure)
    }

    private static func endKeepAlive(_ part: Part) {
        let id = part.keepAlive
        part.keepAlive = .invalid
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
    /// 2.79: closes the open segment, waits (bounded) for every segment to finish, keeps the
    /// readable ones, joins them and writes camera-track.json on the delivered timeline.
    @MainActor
    func finish() async -> URL? {
        guard !isFinishing else { return nil }
        isFinishing = true
        displayLink?.invalidate()
        displayLink = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        closeSegment()
        await waitForClosingSegments()

        if startFailures > 0 { segmentFields["videoStartFailures"] = startFailures }
        if capped { segmentFields["videoCapped"] = true }
        guard started > 0 else {
            // No frame on screen ever asked for a writer (2.78: "noFrames"), or none would start.
            finishStatus = opened == 0 ? "noFrames" : "notStarted"
            writerError = startError
            return nil
        }
        guard !parts.isEmpty else {
            finishStatus = "noFrames"
            return nil
        }
        // Readable parts: a completed file, or a failed one up to its last movie fragment.
        var readable: [Readable] = []
        var recovered = 0
        var lost = 0
        for part in parts {
            if part.result != .completed {
                writerStatus = part.result.rawValue
                writerError = part.error ?? writerError
            }
            // A timed-out part's writer may still be writing its file: lost, file left alone
            // (its late finish lands in tmp, swept with it).
            guard !part.timedOut else {
                lost += 1
                continue
            }
            guard let found = await Self.readable(part) else {
                lost += 1
                try? FileManager.default.removeItem(at: part.url)
                continue
            }
            if part.result != .completed { recovered += 1 }
            readable.append(found)
        }
        segmentFields["videoSegments"] = parts.count
        segmentFields["videoRecovered"] = recovered
        segmentFields["videoLost"] = lost
        guard !readable.isEmpty else {
            finishStatus = "failed"
            segmentFields["videoJoin"] = "none"
            return nil
        }

        // One completed part = the video as it is. Several, or any recovered one = one export
        // (a recovered part is a fragmented file with a possibly cut end).
        var kept = readable
        var starts = [0.0]
        var exported = false
        if readable.count > 1 || recovered > 0 {
            switch await join(readable) {
            case .success(let offsets):
                starts = offsets
                exported = true
                segmentFields["videoJoin"] = "ok"
            case .failure(let error):
                var outcome = "failed:" + Self.errorCodes(error)
                // A recovered part is the likeliest culprit: once more without them.
                let clean = readable.filter { $0.part.result == .completed }
                if !clean.isEmpty, clean.count < readable.count,
                   case .success(let offsets) = await join(clean) {
                    kept = clean
                    starts = offsets
                    exported = true
                    outcome += " retried:ok"
                } else {
                    // Keep the longest part as it is; the others are lost.
                    let longest = readable.indices.max {
                        readable[$0].range.duration < readable[$1].range.duration
                    } ?? 0
                    kept = [readable[longest]]
                }
                segmentFields["videoJoin"] = outcome
            }
        } else {
            segmentFields["videoJoin"] = "none"
        }
        if !exported {
            // One file is the video: under the output name.
            try? FileManager.default.removeItem(at: outputURL)
            guard (try? FileManager.default.moveItem(at: kept[0].part.url, to: outputURL)) != nil else {
                finishStatus = "failed"
                readable.forEach { try? FileManager.default.removeItem(at: $0.part.url) }
                return nil
            }
        }
        // The segment files are no longer needed (exported, or not kept).
        for part in readable where part.part.url != outputURL {
            try? FileManager.default.removeItem(at: part.part.url)
        }
        let complete = recovered == 0 && lost == 0 && kept.count == readable.count
        finishStatus = complete ? "ok" : "partial"

        // camera-track.json: each kept part's samples, shifted to where it starts in the video,
        // cut at its readable end (a recovered part may end before its last sample).
        var samples: [TrackSample] = []
        for (index, item) in kept.enumerated() {
            let shift = starts[min(index, starts.count - 1)] - item.range.start.seconds
            let end = item.range.end.seconds
            for s in item.part.track where s.t <= end + 0.01 {
                samples.append(TrackSample(t: s.t + shift, x: s.x, y: s.y, z: s.z,
                                           dx: s.dx, dz: s.dz, ok: s.ok))
            }
        }
        writeCameraTrackFile(samples)
        return outputURL
    }

    /// Waits for the segment writers still finishing, at most `closingWaitSec` (a finish that
    /// never lands must not hang Stop & Save; those parts then count as failed).
    @MainActor
    private func waitForClosingSegments() async {
        let group = closing
        let once = Once()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .main) {
                if once.claim() { continuation.resume() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.closingWaitSec) {
                if once.claim() { continuation.resume() }
            }
        }
        for part in parts where part.result == .unknown && part.closingWriter != nil {
            part.timedOut = true
            part.result = .failed
            part.error = "finishTimeout"
        }
    }

    /// First caller wins (the continuation must resume exactly once).
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    /// The part's video track, its time range and the asset holding it; nil = unreadable / empty.
    private static func readable(_ part: Part) async -> Readable? {
        guard FileManager.default.fileExists(atPath: part.url.path) else { return nil }
        let asset = AVURLAsset(url: part.url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let range = try? await track.load(.timeRange),
              range.duration.isNumeric, range.duration.seconds > 0 else {
            return nil
        }
        return Readable(part: part, asset: asset, track: track, range: range)
    }

    private enum JoinError: Error { case noTrack, noExport, noMP4, export(Error?) }

    /// Parts end to end into `outputURL`, passthrough (no re-encode). Success = where each part
    /// starts in the delivered video (seconds). `parts` keeps every source asset alive meanwhile.
    @MainActor
    private func join(_ parts: [Readable]) async -> Result<[Double], Error> {
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
        // Setting a type the session does not list raises (not throws).
        guard export.supportedFileTypes.contains(.mp4) else {
            return .failure(JoinError.noMP4)
        }
        try? FileManager.default.removeItem(at: outputURL)
        export.outputURL = outputURL
        export.outputFileType = .mp4
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        withExtendedLifetime(parts) {}
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
        if let open = current {
            if open.writer.status == .writing { open.writer.cancelWriting() }
            try? FileManager.default.removeItem(at: open.url)
        }
        current = nil
        // Segments still finishing write to their files until they land: delete after that.
        let urls = parts.map(\.url)
        parts = []
        closing.notify(queue: .main) {
            urls.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        try? FileManager.default.removeItem(at: outputURL)
    }
}
