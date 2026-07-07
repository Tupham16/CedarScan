import Foundation
import ARKit
import AVFoundation
import CoreImage
import UIKit

/// Quay video 480p quá trình quét bằng cách đọc ARSession.currentFrame theo nhịp CADisplayLink
/// (không chiếm delegate của ARSession — RoomPlan vẫn toàn quyền điều khiển phiên AR).
final class ScanVideoRecorder {
    // Video dọc 480x640 (khung hình camera 4:3 xoay dọc), ~14 fps, H.264 ~1.2 Mbps
    private static let outputWidth = 480
    private static let outputHeight = 640

    let outputURL: URL

    private weak var arSession: ARSession?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var displayLink: CADisplayLink?
    private let ciContext = CIContext()
    private var firstTimestamp: TimeInterval?
    private var lastTimestamp: TimeInterval = 0
    private var isFinishing = false

    init(arSession: ARSession) {
        self.arSession = arSession
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
                AVVideoAverageBitRateKey: 1_200_000,
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
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15, preferred: 14)
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
    }

    /// Kết thúc quay; trả về URL file video (hoặc nil nếu chưa quay được khung nào).
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
        return writer.status == .completed ? outputURL : nil
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
