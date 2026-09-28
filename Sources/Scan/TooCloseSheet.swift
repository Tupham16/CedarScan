import SwiftUI
import UIKit
import ARKit
import AVFoundation

/// "TOO CLOSE" sheet (owner 28/09, CubiCasa style; approved mockup
/// `PLAN-GIAO-DIEN-mockups/59-tooclose-D3-70.png`): one screen-fixed sheet of yellow tiled
/// "TOO CLOSE" text, shown only where the LiDAR sees a surface nearer than `farMeters`,
/// strongest at `nearMeters`, max opacity `maxOpacity`. Replaces the old "Step back a little"
/// banner (centre-depth median at 0.35 m), so the customer sees ONE too-close signal.
///
/// Signal: `sceneDepth.depthMap` (256×192 landscape, Float32) + `confidenceMap`, 32×24 cells of
/// 8×8 px, 16 samples each. Cell depth = 2nd smallest confident sample (one noisy pixel cannot
/// light a cell). Low-confidence / invalid cells HOLD their last value and decay slowly: glass
/// never had a confident near reading so it stays clear, while a surface that got too close for
/// the LiDAR to measure keeps the sheet for a moment instead of blinking off. What the LiDAR
/// really reports right against a surface is unmeasured — read the debug line on device
/// (`tc pk … min … lo … unk …`) before changing the hold.
///
/// Mapping: the cell grid lives in camera-image space; each mask pixel (view space, portrait)
/// is mapped back through `displayTransform(for:viewportSize:).inverted()` — the same
/// aspect-fill crop ARSCNView draws the camera with. Wrong mapping = fill on the wrong side, and
/// CI cannot see it (device test step 3).
///
/// Cadence: own CADisplayLink on main (30 Hz while showing, 10 Hz while clear), reads
/// `currentFrame` like ScanQualityMonitor. The TEXT is fixed to the screen, only the soft,
/// time-smoothed mask follows the scene, so a frame of lag vs the ARSCNView image is invisible —
/// unlike the mesh (§RUNG LƯỚI), nothing crisp is registered to the camera image here.
/// ✗ move it into the SceneKit scene: a quad posed per tick jitters (the red tint's oversize trick
/// does not work for text).
struct TooCloseSheetView: UIViewRepresentable {
    let arSession: ARSession

    func makeUIView(context: Context) -> TooCloseSheetUIView {
        TooCloseSheetUIView(arSession: arSession)
    }

    func updateUIView(_ uiView: TooCloseSheetUIView, context: Context) {}

    /// CADisplayLink holds its target strongly — without stop() the view never dies.
    static func dismantleUIView(_ uiView: TooCloseSheetUIView, coordinator: ()) {
        uiView.stop()
    }
}

final class TooCloseSheetUIView: UIView {
    // MARK: Tuning (owner judges on device, see handoff test steps)
    /// Sheet starts to show at this depth (m)…
    static let farMeters: Float = 0.50
    /// …and is at full strength at this depth (m).
    static let nearMeters: Float = 0.25
    /// Owner 28/09: "opacity max 70".
    static let maxOpacity: Float = 0.70
    /// Display smoothing: rise fast, fade slower (no flicker at the threshold).
    private static let riseTau: Double = 0.10
    private static let fallTau: Double = 0.30
    /// Unknown (low-confidence / invalid) cell: keeps its last value, decaying with this τ.
    private static let holdTau: Double = 1.2
    /// No new ARFrame for this long (interruption) → fade out.
    private static let staleSec: CFTimeInterval = 0.5
    /// Haptic/voice only after the on-screen sheet stayed strong this long (door frames and
    /// fridge edges flash past all scan long; the sheet itself stays instant).
    private static let feedbackDwellSec: CFTimeInterval = 0.7

    private static let cols = 32, rows = 24
    /// Mask image width in pixels (view space); height follows the view's aspect.
    private static let maskWidth = 36

    private weak var arSession: ARSession?
    private var displayLink: CADisplayLink?

    private let container = CALayer()   // masked, unrotated
    private let sheet = CALayer()       // tiled text image
    private let maskLayer = CALayer()

    /// Per-cell target (0…1, after hold) and displayed value (after blur + smoothing).
    private var target = [Float](repeating: 0, count: cols * rows)
    private var shown = [Float](repeating: 0, count: cols * rows)
    private var blurred = [Float](repeating: 0, count: cols * rows)

    /// View-pixel → grid bilinear lookup, rebuilt when the view size or camera image changes.
    private struct Tap { var i0: Int32; var j0: Int32; var fx: Float; var fy: Float }
    private var taps: [Tap] = []
    private var tapsKey: (CGSize, CGSize, UIInterfaceOrientation)?
    /// Cells that reach the screen: the aspect-fill crop hides ~38% of the image (portrait
    /// left/right strips). `peak` — show/hide, 30 Hz, feedback — counts only these.
    private var visibleCells = [Bool](repeating: false, count: cols * rows)
    private var maskHeight = 0
    private var maskBytes: [UInt8] = []

    private var sheetSize: CGSize = .zero
    private var lastFrameT: TimeInterval = -1
    private var lastFrameWall: CFTimeInterval = 0
    private var lastTickWall: CFTimeInterval = 0
    private var peak: Float = 0
    private var isShowing = false

    // Feedback: one light tap on the rising edge, at most every 10 s (owner dislikes nagging).
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private let speech = AVSpeechSynthesizer()
    private var lastFeedbackWall: CFTimeInterval = -100
    private var armed = true
    private var strongSince: CFTimeInterval = -1

    // Hidden debug readout (Account › 7 taps on the version line).
    private let debugOn = UserDefaults.standard.bool(forKey: "scanDebugReadout")
    private let debugLabel = UILabel()
    private var lastDebugWall: CFTimeInterval = 0
    private var dbgMin: Float = 0, dbgLow: Float = 0, dbgUnknown: Float = 0, dbgNear: Float = 0

    init(arSession: ARSession) {
        self.arSession = arSession
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        accessibilityElementsHidden = true

        maskLayer.magnificationFilter = .linear
        maskLayer.contentsGravity = .resize
        container.mask = maskLayer
        container.isHidden = true
        sheet.opacity = Self.maxOpacity
        sheet.contentsGravity = .resize
        container.addSublayer(sheet)
        layer.addSublayer(container)

        if debugOn {
            debugLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            debugLabel.textColor = .white
            debugLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
            debugLabel.layer.cornerRadius = 6
            debugLabel.layer.masksToBounds = true
            addSubview(debugLabel)
        }

        // Remote kill switch of the whole coach (`scan-quality-config` {"enabled": false}).
        guard ScanQualityConfig.current.enabled else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 10)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Off-window (cover torn down without dismantle): no ticks. dismantleUIView still stops.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.isPaused = window == nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        maskLayer.frame = bounds
        sheet.frame = bounds
        if bounds.size != sheetSize, bounds.width > 0, bounds.height > 0 {
            sheetSize = bounds.size
            sheet.contents = Self.renderSheet(size: bounds.size)
        }
        CATransaction.commit()
        if debugOn {
            // Below the torch readout (2 lines at the HUD's capped text size).
            debugLabel.frame = CGRect(x: 16, y: safeAreaInsets.top + 150, width: bounds.width - 32, height: 18)
        }
    }

    // MARK: - Tick

    @objc private func tick(_ link: CADisplayLink) {
        let perfT0 = ScanPerfProfiler.tickBegin()
        defer { ScanPerfProfiler.tickEnd(.tooClose, perfT0) }
        let now = CACurrentMediaTime()
        let wallDt = lastTickWall > 0 ? min(0.2, now - lastTickWall) : 0
        lastTickWall = now
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }

        if let frame = arSession?.currentFrame, frame.timestamp != lastFrameT {
            let dt = lastFrameT > 0 ? min(0.2, max(0, frame.timestamp - lastFrameT)) : 0
            lastFrameT = frame.timestamp
            lastFrameWall = now
            if readDepth(frame, dt: dt) {
                updateTaps(frame)
            }
            smooth(dt: dt)
        } else if now - lastFrameWall > Self.staleSec {
            // Interrupted / no depth: let everything fade.
            for k in target.indices { target[k] = 0 }
            smooth(dt: wallDt)
        } else {
            return
        }
        render()
        feedback(now: now)
        if debugOn { publishDebug(now: now) }
    }

    /// Reads the depth map into `target`. false = no usable depth this frame (targets decayed).
    private func readDepth(_ frame: ARFrame, dt: Double) -> Bool {
        let decay = Float(dt > 0 ? exp(-dt / Self.holdTau) : 1)
        guard let depth = frame.sceneDepth,
              CVPixelBufferGetPixelFormatType(depth.depthMap) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferLockBaseAddress(depth.depthMap, .readOnly) == kCVReturnSuccess else {
            for k in target.indices { target[k] *= decay }
            return false
        }
        defer { CVPixelBufferUnlockBaseAddress(depth.depthMap, .readOnly) }
        let map = depth.depthMap
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        guard let base = CVPixelBufferGetBaseAddress(map), w >= Self.cols * 4, h >= Self.rows * 4,
              rowBytes >= w * 4 else {
            for k in target.indices { target[k] *= decay }
            return false
        }

        // Confidence is optional: without it every finite sample counts.
        var confBase: UnsafeMutableRawPointer?
        var confRow = 0
        let conf = depth.confidenceMap
        if let conf, CVPixelBufferGetPixelFormatType(conf) == kCVPixelFormatType_OneComponent8,
           CVPixelBufferGetWidth(conf) == w, CVPixelBufferGetHeight(conf) == h,
           CVPixelBufferLockBaseAddress(conf, .readOnly) == kCVReturnSuccess {
            confBase = CVPixelBufferGetBaseAddress(conf)
            confRow = CVPixelBufferGetBytesPerRow(conf)
            if confBase == nil { CVPixelBufferUnlockBaseAddress(conf, .readOnly) }
        }
        defer { if confBase != nil, let conf { CVPixelBufferUnlockBaseAddress(conf, .readOnly) } }

        let cw = w / Self.cols, ch = h / Self.rows
        let sx = max(1, cw / 4), sy = max(1, ch / 4)
        let medium = UInt8(ARConfidenceLevel.medium.rawValue)
        let far = Self.farMeters, near = Self.nearMeters
        var minD = Float.greatestFiniteMagnitude
        var lowN = 0, sampleN = 0, unknownN = 0, nearN = 0

        for r in 0..<Self.rows {
            for c in 0..<Self.cols {
                // Two smallest confident samples of the cell.
                var d1 = Float.greatestFiniteMagnitude, d2 = Float.greatestFiniteMagnitude
                var valid = 0
                for j in 0..<4 {
                    let y = r * ch + j * sy + sy / 2
                    let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
                    let crow = confBase.map { $0.advanced(by: y * confRow).assumingMemoryBound(to: UInt8.self) }
                    for i in 0..<4 {
                        let x = c * cw + i * sx + sx / 2
                        sampleN += 1
                        if let crow, crow[x] < medium { lowN += 1; continue }
                        let v = row[x]
                        guard v.isFinite, v > 0 else { continue }
                        valid += 1
                        if v < d1 { d2 = d1; d1 = v } else if v < d2 { d2 = v }
                    }
                }
                let k = r * Self.cols + c
                if valid >= 4 {
                    target[k] = Self.smoothstep(from: far, to: near, d2)
                    minD = min(minD, d2)
                    if target[k] > 0.5 { nearN += 1 }
                } else {
                    target[k] *= decay
                    unknownN += 1
                }
            }
        }
        let cells = Float(Self.cols * Self.rows)
        dbgMin = minD
        dbgLow = sampleN > 0 ? Float(lowN) / Float(sampleN) : 0
        dbgUnknown = Float(unknownN) / cells
        dbgNear = Float(nearN) / cells
        return true
    }

    /// 0 at `from`, 1 at `to` (from > to), smooth in between.
    private static func smoothstep(from e0: Float, to e1: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    /// 3×3 [1 2 1] blur of `target`, then asymmetric exponential smoothing into `shown`.
    private func smooth(dt: Double) {
        let C = Self.cols, R = Self.rows
        target.withUnsafeBufferPointer { t in
            for r in 0..<R {
                for c in 0..<C {
                    var s: Float = 0, wsum: Float = 0
                    for dr in -1...1 {
                        let rr = min(R - 1, max(0, r + dr))
                        for dc in -1...1 {
                            let cc = min(C - 1, max(0, c + dc))
                            let wgt: Float = (dr == 0 ? 2 : 1) * (dc == 0 ? 2 : 1)
                            s += t[rr * C + cc] * wgt
                            wsum += wgt
                        }
                    }
                    blurred[r * C + c] = s / wsum
                }
            }
        }
        let up = Float(dt > 0 ? 1 - exp(-dt / Self.riseTau) : 1)
        let down = Float(dt > 0 ? 1 - exp(-dt / Self.fallTau) : 1)
        var p: Float = 0
        for k in shown.indices {
            let b = blurred[k]
            let v = shown[k]
            let n = v + (b - v) * (b > v ? up : down)
            shown[k] = n < 0.004 ? 0 : n
            if visibleCells[k] { p = max(p, shown[k]) }
        }
        peak = p
    }

    /// Rebuilds the view→grid lookup when the view size, image size or orientation changed.
    private func updateTaps(_ frame: ARFrame) {
        let size = bounds.size
        let image = frame.camera.imageResolution
        let orientation = window?.windowScene?.interfaceOrientation ?? .portrait
        if let key = tapsKey, key.0 == size, key.1 == image, key.2 == orientation { return }
        tapsKey = (size, image, orientation)

        let mw = Self.maskWidth
        let mh = max(1, Int((CGFloat(mw) * size.height / size.width).rounded()))
        maskHeight = mh
        maskBytes = [UInt8](repeating: 0, count: mw * mh * 4)
        // Normalized view point (top-left origin) → normalized camera-image point.
        let toImage = frame.displayTransform(for: orientation, viewportSize: size).inverted()
        var t: [Tap] = []
        t.reserveCapacity(mw * mh)
        var seen = [Bool](repeating: false, count: Self.cols * Self.rows)
        for j in 0..<mh {
            for i in 0..<mw {
                let v = CGPoint(x: (CGFloat(i) + 0.5) / CGFloat(mw), y: (CGFloat(j) + 0.5) / CGFloat(mh))
                let p = v.applying(toImage)
                // Cell centres sit at (c + 0.5) / cols.
                let gx = Float(p.x) * Float(Self.cols) - 0.5
                let gy = Float(p.y) * Float(Self.rows) - 0.5
                let cx = min(Float(Self.cols - 1), max(0, gx))
                let cy = min(Float(Self.rows - 1), max(0, gy))
                let i0 = min(Self.cols - 2, Int(cx)), j0 = min(Self.rows - 2, Int(cy))
                t.append(Tap(i0: Int32(i0), j0: Int32(j0), fx: cx - Float(i0), fy: cy - Float(j0)))
                for dj in 0...1 {
                    for di in 0...1 { seen[(j0 + dj) * Self.cols + i0 + di] = true }
                }
            }
        }
        taps = t
        visibleCells = seen
    }

    private func render() {
        let visible = peak > 0.01 && !taps.isEmpty
        if visible != isShowing {
            isShowing = visible
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.isHidden = !visible   // hidden = no offscreen mask pass
            CATransaction.commit()
            displayLink?.preferredFrameRateRange = CAFrameRateRange(
                minimum: 10, maximum: 30, preferred: visible ? 30 : 10)
        }
        guard visible else { return }

        let C = Self.cols
        let mw = Self.maskWidth, mh = maskHeight
        shown.withUnsafeBufferPointer { g in
            for k in 0..<(mw * mh) {
                let tp = taps[k]
                let a = Int(tp.j0) * C + Int(tp.i0)
                let top = g[a] + (g[a + 1] - g[a]) * tp.fx
                let bot = g[a + C] + (g[a + C + 1] - g[a + C]) * tp.fx
                let v = top + (bot - top) * tp.fy
                let byte = UInt8(max(0, min(255, (v * 255).rounded())))
                // Premultiplied white: only alpha matters to a mask.
                maskBytes[k * 4] = byte
                maskBytes[k * 4 + 1] = byte
                maskBytes[k * 4 + 2] = byte
                maskBytes[k * 4 + 3] = byte
            }
        }
        guard let provider = CGDataProvider(data: Data(maskBytes) as CFData),
              let image = CGImage(
                width: mw, height: mh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: mw * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.contents = image
        CATransaction.commit()
    }

    private func feedback(now: CFTimeInterval) {
        if peak < 0.2 { armed = true }
        if peak > 0.5 {
            if strongSince < 0 { strongSince = now }
        } else {
            strongSince = -1
        }
        guard armed, strongSince >= 0, now - strongSince >= Self.feedbackDwellSec else { return }
        armed = false
        guard now - lastFeedbackWall > 10 else { return }
        lastFeedbackWall = now
        let hapticsOn = UserDefaults.standard.object(forKey: "scanCoachHaptics") == nil
            || UserDefaults.standard.bool(forKey: "scanCoachHaptics")
        if hapticsOn { haptic.impactOccurred() }
        let words = String(localized: "TOO CLOSE").localizedLowercase
        if UserDefaults.standard.bool(forKey: "scanCoachVoice") {
            let utterance = AVSpeechUtterance(string: words)
            utterance.voice = AVSpeechSynthesisVoice(language: AppLanguage.speechVoice)
            speech.speak(utterance)
        } else if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: words)
        }
    }

    private func publishDebug(now: CFTimeInterval) {
        guard now - lastDebugWall >= 0.5 else { return }
        lastDebugWall = now
        let minText = dbgMin < 100 ? String(format: "%.2f", dbgMin) : "-"
        debugLabel.text = String(format: " tc pk %.2f near %.0f%% min %@ lo %.0f%% unk %.0f%%",
                                 peak, dbgNear * 100, minText, dbgLow * 100, dbgUnknown * 100)
    }

    // MARK: - Sheet image

    /// Yellow "TOO CLOSE" rows, rotated −20°, staggered — drawn once per view size at 2× (a
    /// translucent watermark does not need 3×; saves ~7 MB during the scan).
    private static func renderSheet(size: CGSize) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        let text = String(localized: "TOO CLOSE")
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = CGSize(width: 0, height: 1)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 30, weight: .heavy),
            .kern: 1.5,
            .foregroundColor: UIColor(red: 1, green: 214 / 255, blue: 10 / 255, alpha: 1),
            .shadow: shadow,
        ]
        let string = NSAttributedString(string: text, attributes: attrs)
        let textSize = string.size()
        let gap: CGFloat = 34, rowH: CGFloat = 60
        let step = textSize.width + gap
        let reach = (size.width * size.width + size.height * size.height).squareRoot() / 2 + 60
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            cg.translateBy(x: size.width / 2, y: size.height / 2)
            cg.rotate(by: -20 * .pi / 180)
            var row = 0
            var y = -reach
            while y < reach {
                var x = -reach - (row % 2 == 1 ? step / 2 : 0)
                while x < reach {
                    string.draw(at: CGPoint(x: x, y: y - textSize.height / 2))
                    x += step
                }
                y += rowH
                row += 1
            }
        }
        return image.cgImage
    }
}
