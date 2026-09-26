import Foundation
import ARKit
import AVFoundation
import UIKit
import simd

/// Auto flashlight while scanning (owner 26/09, "like CubiCasa": dark → torch on, light → off).
/// Owner's field test of CubiCasa = the acceptance bar: room light switched ON while the torch
/// is lit → torch off at once; room light OFF → torch on at once; no flicker.
///
/// Signal: ARFrame.lightEstimate.ambientIntensity (the same number as the "Turn on lights"
/// coach). 🔴 FEEDBACK LOOP: the torch brightens what it measures, so an absolute off-threshold
/// flickers (dark → on → "bright" → off → dark …). Hence:
///  - ON: torch off, reading < onBelow for `onSustainSec`.
///  - At ON: remember the pre-torch reading; after `settleSec`, once the reading is FLAT
///    (`gainFlatSec`, or `gainTimeoutSec`), measure the torch's own share (`gain` = lit −
///    pre-torch) at the median LiDAR depth in front (`gainDepth`). From then on
///    est = reading − share, share = gain·(gainDepth/depth)² (the torch lights like 1/d²).
///  - OFF fast = a STEP in the RAW reading while the phone is STILL (moved < 10 cm, turned
///    < 8°, a full-frame 3×3 LiDAR grid — 3-pixel median per point — within 10 % with at most
///    one odd point; ambientIntensity meters the whole frame, so a near shelf sliding into a
///    frame edge must break "still"; grid points at 1/8, 1/2, 7/8 of each side): against ANY sample of the last ≤ `stepWindowSec`, the
///    reading rose by > max(stepMinRise, stepRatio × before); it holds `fastOffSustainSec`.
///    Armed only once the reading has gone FLAT after ON (= `gain` measured): an exposure /
///    light-estimate tail still climbing after settle would otherwise pass as a step and loop. Phone still ⇒ the torch's part is constant ⇒ the rise is
///    another light — no share model involved, so it works even when `gain` is wrong. Stillness is the discriminator: one scalar cannot tell
///    "a lamp came on" from "turned to a white wall" (~3× a dark floor, torch light included)
///    — but turning to a wall moves the camera, flipping a switch does not.
///  - OFF slow (walked into a lit area, or a switch while moving): est > offAbove +
///    shareMargin × share for `slowOffSustainSec`. Margin 2 absorbs surface colour (a 3×
///    surface adds ≈ 2 × share to est). Accepted: a lit room seen from right up against a wall
///    keeps the torch on until the customer steps back; a dim room keeps it on.
///  - No decision for `settleSec` after any switch (auto-exposure is catching up; its readings
///    lie in both directions).
///  - Back-off: a false off = dark again from the first settled readings after a SLOW off.
///    After a FAST off see Bounce below. Each false off multiplies both off-sustains by 3
///    (cap 27×) for the rest of the scan.
///  - Contaminated share: a room light switched on before the reading has gone flat after ON
///    (settle + flat probe, ~2–6 s) lands in `gain` while the step rule is not yet armed →
///    the torch looks huge, est stays low. Sanity: gain > offAbove measured at > `farMeters`
///    (the torch alone cannot do that far) = room light → off, not counted; the next gain is
///    trusted (no loop) — only when that OFF was followed by darkness at once (else a real
///    room light, and the flag would let the NEXT contaminated gain through). Residual
///    (switch in that window AND a near surface): the torch can stay on until the room light
///    changes again — the slow rule needs est over offAbove + 2·share, i.e. far walls in a
///    bright room (a 600 room + gain measured at 1 m ⇒ ≥ 5 m). ✗ A torch-strength constant
///    across the scan (tried, R3): surface colour (≲ 3×) swamps it either way.
///  - Accepted: a light switched on while panning misses the step (not still) → slow rule.
///    Also: right against a wall the torch dominates (share ≫ room) and the step's 0.8× bar
///    may not be met — the torch stays on until the customer steps back.
///  - Bounce: a fast off that is dark again from the first settled readings (the owner
///    flipping the light off again within ~1 s, or a fooled step). Bounces within
///    `bounceForgetSec` of each other accumulate; past `freeBounces` each one triples the FAST
///    sustain (cap 27×); `bounceForgetSec` without a bounce forgets them. A systematic fool
///    thus decays to ≤ one blink per ~15–30 s; repeated manual toggles stay fast.
///  - Dropped (lit → dark by itself: iOS heat cut, capture restart): retry after
///    `failRetrySec`; after `maxDrops` give up for this scan (coach takes over).
/// ✗ Probing (dimming the torch to measure the room): visible flicker AND exposure jumps in
/// texture shots. ✗ exif BrightnessValue instead: same information, one more parse.
///
/// Every device step is optional: no device / no torch / torch unavailable (iOS disables it
/// when hot) / lock failure = the scan goes on, the "Turn on lights" coach covers it
/// (`coversLowLight` false).
///
/// Texture: torch light is harsh (hotspot, 1/d² falloff, cold LED vs warm room light) and the
/// white balance is LOCKED after warm-up (2.54) — whichever light it locked under, the other
/// gets a tint. Each shot records `torch` (level, 0 = off) so the workstation can prefer
/// non-torch shots later; shots are skipped for `settleSec` after a switch (exposure jumping).
/// LiDAR depth is unaffected (IR).
/// Heat/battery: the LED adds roughly 0.5–1 W on top of a 4–6 W scan (level 0.7), right next
/// to the camera module. Hot phone = ARKit camera 60→30 fps (SESSION-HANDOFF §ĐÃ CHỐT thermal)
/// → `torchLevel` < 1 and remote-tunable. iOS itself cuts the torch when too hot
/// (isTorchAvailable false) → coach fallback.
///
/// MAIN THREAD ONLY (CADisplayLink on main, like every other scan loop). Reads
/// `arSession.currentFrame`, never takes the session delegate.
final class AutoTorch: ObservableObject {
    /// Torch lit right now (as the device reports it) — the scan screen's small indicator.
    @Published private(set) var isOn = false
    /// Debug readout, only when the hidden debug flag is on (7 taps on the version line in
    /// Account). nil otherwise — no 10 Hz SwiftUI churn for customers.
    @Published private(set) var debugLine: String?

    /// Figures for scan-report.json (owner cannot read console logs: switch counts there are
    /// how "no flicker" is checked on real scans).
    struct Stats: Encodable {
        var status = "notStarted"
        var level: Float?
        var switchesOn = 0
        var fastOffs = 0
        var slowOffs = 0
        var onSec: Double = 0
        var falseOffs = 0
        var failures = 0
        /// Torch went dark by itself (iOS thermal cut, capture restart) while wanted on.
        var dropped = 0
        /// Fast offs followed by darkness at once (see Bounce in the class comment).
        var fastBounces = 0
        /// Share measurement rejected as room light (far-depth sanity check).
        var contaminated = 0
    }
    private(set) var stats = Stats()

    // MARK: - Tuning (see the class comment before touching)
    private static let warmupSec: TimeInterval = 4
    private static let settleSec: TimeInterval = 1.5
    private static let onSustainSec: TimeInterval = 0.5
    private static let stepWindowSec: TimeInterval = 1.5
    private static let stepMinSpanSec: TimeInterval = 0.4
    private static let stepMinRise = 300.0
    private static let stepRatio = 0.8
    private static let stillMaxMeters: Float = 0.10
    private static let stillMaxDeg: Float = 8
    /// ≤ 10 % depth change ⇒ torch share changes ≤ 21 % (1/d²) — below the step bar.
    private static let stillDepthRatio: Float = 1.1
    private static let gainFlatSec: TimeInterval = 0.5
    private static let gainTimeoutSec: TimeInterval = 4
    private static let farMeters: Float = 1.5
    private static let fastOffSustainSec: TimeInterval = 0.5
    private static let shareMargin = 2.0
    private static let slowOffSustainSec: TimeInterval = 4
    /// An ON whose dark stretch began within this of the settle end after an OFF = false off.
    private static let falseOffSlackSec: TimeInterval = 0.4
    private static let failRetrySec: TimeInterval = 5
    private static let maxDrops = 3
    private static let freeBounces = 4
    private static let bounceForgetSec: TimeInterval = 30
    /// Readings are smoothed over ~this (single-frame spikes).
    private static let smoothTauSec: TimeInterval = 0.25

    private weak var arSession: ARSession?
    private var device: AVCaptureDevice?
    private var displayLink: CADisplayLink?
    private var enabled = false
    private var isActive = false
    /// Naming overlay open: stays off even if tracking recovery re-activates the coach.
    private var held = false
    private var gaveUp = false
    private var debug = false
    private var level: Float = 0.7
    private var onBelow = 250.0
    private var offAbove = 500.0

    // Timebase = ARFrame.timestamp.
    private var startT: TimeInterval = -1
    private var lastT: TimeInterval = -1
    private var smoothI = -1.0
    /// Our intent. `isOn` is the device truth.
    private var wantOn = false
    private var changedAt: TimeInterval = -.greatestFiniteMagnitude
    private var lastOffAt: TimeInterval = -.greatestFiniteMagnitude
    private var lastFailAt: TimeInterval = -.greatestFiniteMagnitude
    private var darkSince: TimeInterval = -1
    private var stepSince: TimeInterval = -1
    private var stepBase = 0.0
    private var slowSince: TimeInterval = -1
    private var preOnI = 0.0
    private var gain: Double?
    private var gainDepth: Float?
    /// Flatness probe for the gain measurement (reading at probe start).
    private var gainProbeT: TimeInterval = -1
    private var gainProbeI = 0.0
    /// Set by a contamination OFF: the next measured gain is accepted as is.
    private var trustNextGain = false
    /// Kind of the last light-level OFF (decides false off / bounce at the next ON).
    private var lastOffWasSlow = false
    /// Bounces close together (see class comment) and when the last one happened.
    private var recentBounces = 0
    private var lastBounceAt: TimeInterval = -.greatestFiniteMagnitude
    /// When the last contamination OFF happened (trust the next gain only if dark follows).
    private var contamOffAt: TimeInterval = -.greatestFiniteMagnitude
    private struct Sample {
        let t: TimeInterval
        /// Raw smoothed reading (not est: the step rule must not depend on `gain`).
        let reading: Double
        let depth: Float?
        /// Full-frame 3×3 depth grid (0 = no value) for the stillness test.
        let grid: [Float]
        let pos: SIMD3<Float>
        let quat: simd_quatf
    }
    /// Reading history for the step test, ≤ stepWindowSec (torch lit, after settle).
    private var recent: [Sample] = []
    private var lastHapticT: TimeInterval = -.greatestFiniteMagnitude
    private var lastDebugT: TimeInterval = -1
    private var lastDepth: Float?
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    init(arSession: ARSession) {
        self.arSession = arSession
    }

    /// True = the torch deals with low light, so the "Turn on lights" coach stays quiet.
    /// False (no device, no torch, iOS cut it, lock failing, gave up, switched off) = coach.
    var coversLowLight: Bool {
        guard enabled, !gaveUp, let device, device.hasTorch, device.isTorchAvailable else { return false }
        return lastT - lastFailAt > Self.failRetrySec
    }

    /// Texture shots skip frames this close to a switch (exposure still moving).
    func isSettling(at t: TimeInterval) -> Bool {
        t - changedAt < Self.settleSec
    }

    /// Torch level at capture for ShotMeta `torch`: 0 = off, nil = no torch device.
    /// Finite and 0…1 (NaN rule of shots.json).
    var levelForShot: Float? {
        guard let device, device.hasTorch else { return nil }
        guard device.isTorchActive else { return 0 }
        let l = device.torchLevel
        return l.isFinite ? min(max(l, 0), 1) : nil
    }

    // MARK: - Lifecycle (main)

    func start(device primary: AVCaptureDevice?) {
        guard displayLink == nil else { return }
        let cfg = ScanQualityConfig.current
        let userOn = UserDefaults.standard.object(forKey: "scanAutoTorch") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "scanAutoTorch")
        debug = UserDefaults.standard.bool(forKey: "scanDebugReadout")
        guard userOn else { stats.status = "disabledByUser"; return }
        guard cfg.autoTorch else { stats.status = "disabledByConfig"; return }
        // ARKit's primary camera; fallback = the back wide camera (same hardware torch).
        let dev = primary ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        guard let dev else { stats.status = "noDevice"; return }
        // setTorchModeOn raises (crash, not throw) when .on is unsupported.
        guard dev.hasTorch, dev.isTorchModeSupported(.on), dev.isTorchModeSupported(.off) else {
            stats.status = "noTorch"
            return
        }
        device = dev
        // Level must be in (0, 1] or setTorchModeOn raises. Config already validates; again here.
        let l = Float(cfg.torchLevel)
        level = (l.isFinite && l > 0) ? min(l, 1) : 0.7
        onBelow = cfg.torchOnBelow
        // off ≤ on would flicker by construction.
        offAbove = max(cfg.torchOffAbove, onBelow * 1.5)
        stats.level = level
        stats.status = "ready"
        enabled = true
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 10)
        link.add(to: .main, forMode: .common)
        displayLink = link
        haptic.prepare()
    }

    /// Mirrors the coach (ScanQualityMonitor.setActive forwards here): naming overlay,
    /// interruption. Inactive = torch off; back to active re-decides from scratch.
    func setActive(_ active: Bool) {
        isActive = active && !held
        guard !isActive else { return }
        if wantOn || isOn || device?.isTorchActive == true {
            switchOff(at: lastT, countAsOff: false)
        }
        resetSustains()
    }

    /// Naming overlay (MeshScanFlowView): tracking recovery calls setActive(true) behind it —
    /// the torch must not come back on there. Release = the overlay's Back.
    func setHold(_ hold: Bool) {
        held = hold
        if hold { setActive(false) }
    }

    /// End of scan (both exits, BEFORE arSession.pause). The device outlives the session:
    /// the torch must not stay lit on the next screen. One retry if the lock fails.
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        isActive = false
        if wantOn || isOn || device?.isTorchActive == true
            || (device.map { $0.torchMode != .off } ?? false) {
            if !switchOff(at: lastT, countAsOff: false) {
                // Lock busy right now: one more try shortly (the display link is gone).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.switchOff(at: self?.lastT ?? 0, countAsOff: false)
                }
            }
        }
        enabled = false
        isOn = false
        debugLine = nil
    }

    // MARK: - Loop

    @objc private func tick() {
        guard enabled, let device, let frame = arSession?.currentFrame else { return }
        let t = frame.timestamp
        guard t != lastT else { return } // paused/interrupted = same frame again
        let dt = lastT > 0 ? min(0.5, max(0, t - lastT)) : 0
        lastT = t
        if startT < 0 { startT = t }

        let lit = device.isTorchActive
        if lit { stats.onSec += dt }
        if isOn != lit { isOn = lit }

        // Lit although not wanted (an OFF whose lock failed): retry, also while inactive.
        if !wantOn && lit && t - changedAt > Self.settleSec && t - lastFailAt > Self.failRetrySec {
            switchOff(at: t, countAsOff: false)
        }

        guard isActive else { return }
        guard let raw = frame.lightEstimate?.ambientIntensity, raw.isFinite, raw >= 0 else { return }
        let reading = Double(raw)
        smoothI = smoothI < 0 ? reading : smoothI + (reading - smoothI) * min(1, dt / Self.smoothTauSec)

        // Wanted on but dark: iOS cut it (heat) or the capture session restarted.
        if wantOn && !lit && t - changedAt > Self.settleSec {
            stats.dropped += 1
            // Clear torchMode too, so iOS does not relight it later on its own.
            switchOff(at: t, countAsOff: false)
            lastFailAt = t // retry delay (switchOff counts a lock failure itself)
            resetSustains()
            if stats.dropped >= Self.maxDrops {
                gaveUp = true
                stats.status = "gaveUp"
            }
        }

        defer { publishDebug(t) }
        guard t - startT > Self.warmupSec, t - changedAt > Self.settleSec else { return }

        if !wantOn {
            sustain(&darkSince, smoothI < onBelow, t)
            if darkSince > 0, t - darkSince >= Self.onSustainSec, !gaveUp,
               t - lastFailAt > Self.failRetrySec, device.isTorchAvailable {
                switchOn(at: t)
            }
            return
        }

        let probe = Self.depthProbe(of: frame)
        let depth = probe?.center
        let grid = probe?.grid ?? []
        lastDepth = depth
        let tf = frame.camera.transform
        let pos = SIMD3(tf.columns.3.x, tf.columns.3.y, tf.columns.3.z)
        let quat = simd_normalize(simd_quatf(tf))
        let backoff = pow(3.0, Double(min(stats.falseOffs, 3)))
        if t - lastBounceAt > Self.bounceForgetSec { recentBounces = 0 }
        let bouncePenalty = max(0, recentBounces - Self.freeBounces)
        let fastBackoff = pow(3.0, Double(min(stats.falseOffs + bouncePenalty, 3)))

        // Fast: a still-phone step of the raw reading — armed once the reading went flat.
        if gain == nil {
            stepSince = -1
        } else if stepSince < 0 {
            // Any earlier sample (≤ ~15) that shows the rise with a still phone in between.
            if let old = recent.first(where: {
                t - $0.t >= Self.stepMinSpanSec
                    && smoothI - $0.reading > max(Self.stepMinRise, Self.stepRatio * $0.reading)
                    && Self.still($0, pos, quat, grid)
            }) {
                stepSince = t
                stepBase = old.reading
            }
        } else if !(smoothI > stepBase + Self.stepMinRise) {
            stepSince = -1
        }
        recent.append(Sample(t: t, reading: smoothI, depth: depth, grid: grid, pos: pos, quat: quat))
        while let first = recent.first, t - first.t > Self.stepWindowSec { recent.removeFirst() }
        if stepSince > 0 && t - stepSince >= Self.fastOffSustainSec * fastBackoff {
            stats.fastOffs += 1
            lastOffWasSlow = false
            switchOff(at: t, countAsOff: true)
            return
        }

        guard let g = gain else {
            // The torch's own share, at this distance — once the reading is flat.
            if gainProbeT < 0 {
                gainProbeT = t
                gainProbeI = smoothI
                return
            }
            guard t - gainProbeT >= Self.gainFlatSec else { return }
            let flat = abs(smoothI - gainProbeI) < max(60, 0.15 * gainProbeI)
            if !flat && t - changedAt < Self.settleSec + Self.gainTimeoutSec {
                gainProbeT = t
                gainProbeI = smoothI
                return
            }
            let measured = max(0, smoothI - preOnI)
            if !trustNextGain, measured > offAbove, let d = depth, d > Self.farMeters {
                // A room light came on while settling (see class comment).
                stats.contaminated += 1
                contamOffAt = t
                switchOff(at: t, countAsOff: false)
                return
            }
            trustNextGain = false
            gain = measured
            gainDepth = depth
            // The step rule arms now: no pre-flat (still rising) sample may serve as its base.
            recent.removeAll()
            return
        }
        let (est, share) = estimate(g, depth)
        // Slow: walked into a lit area (or a switch while moving).
        sustain(&slowSince, est > offAbove + Self.shareMargin * share, t)
        if slowSince > 0 && t - slowSince >= Self.slowOffSustainSec * backoff {
            stats.slowOffs += 1
            lastOffWasSlow = true
            switchOff(at: t, countAsOff: true)
        }
    }

    /// Phone held still between `old` and now: moved < 10 cm, turned < 8°, and of the
    /// full-frame 3×3 LiDAR grid points (1/8, 1/2, 7/8) valid on both sides (≥ 6 of 9) at most one changed
    /// ≥ 10 % (a cell on a depth edge can flip near/far between frames).
    private static func still(_ old: Sample, _ pos: SIMD3<Float>, _ quat: simd_quatf, _ grid: [Float]) -> Bool {
        guard old.grid.count == 9, grid.count == 9 else { return false }
        var matched = 0
        var odd = 0
        for i in 0..<9 where old.grid[i] > 0 && grid[i] > 0 {
            let ratio = max(old.grid[i] / grid[i], grid[i] / old.grid[i])
            if ratio >= stillDepthRatio { odd += 1 }
            matched += 1
        }
        guard matched >= 6, odd <= 1 else { return false }
        let dot = min(1, abs(simd_dot(old.quat.vector, quat.vector)))
        let turnDeg = 2 * acos(dot) * 180 / .pi
        return simd_distance(old.pos, pos) < stillMaxMeters && turnDeg < stillMaxDeg
    }

    /// (room light without the torch's share (≥ 0), that share). The share scales 1/d² from
    /// where it was measured; no depth on either side = unscaled.
    private func estimate(_ g: Double, _ depth: Float?) -> (est: Double, share: Double) {
        var share = g
        if let d0 = gainDepth, let d = depth {
            let k = Double(d0 / d)
            share *= min(k * k, 16)
        }
        return (max(0, smoothI - share), share)
    }

    private func sustain(_ since: inout TimeInterval, _ active: Bool, _ t: TimeInterval) {
        if active {
            if since < 0 { since = t }
        } else {
            since = -1
        }
    }

    private func resetSustains() {
        darkSince = -1
        stepSince = -1
        slowSince = -1
    }

    // MARK: - Device

    private func switchOn(at t: TimeInterval) {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
        } catch {
            fail(t)
            return
        }
        var ok = true
        do {
            // Throws when above the thermally allowed level.
            try device.setTorchModeOn(level: level)
        } catch {
            ok = false
        }
        device.unlockForConfiguration()
        guard ok else { fail(t); return }
        // Dark again from the first settled readings after an OFF: after a SLOW off = false
        // off; after a FAST off = bounce (first free, later ones = false offs).
        let darkAtOnce = { (offAt: TimeInterval) in
            self.darkSince > 0 && self.darkSince - offAt < Self.settleSec + Self.falseOffSlackSec
        }
        if darkAtOnce(lastOffAt) {
            if lastOffWasSlow {
                stats.falseOffs += 1
            } else {
                stats.fastBounces += 1
                if t - lastBounceAt > Self.bounceForgetSec { recentBounces = 0 }
                recentBounces += 1
                lastBounceAt = t
            }
        }
        trustNextGain = darkAtOnce(contamOffAt)
        wantOn = true
        changedAt = t
        preOnI = smoothI
        gain = nil
        gainDepth = nil
        gainProbeT = -1
        recent.removeAll()
        resetSustains()
        stats.switchesOn += 1
        stats.status = "used"
        isOn = device.isTorchActive
        // One light tap on ON (not on OFF), at most every 30 s; respects the coach vibration toggle.
        let hapticsOn = UserDefaults.standard.object(forKey: "scanCoachHaptics") == nil
            || UserDefaults.standard.bool(forKey: "scanCoachHaptics")
        if hapticsOn && t - lastHapticT > 30 {
            lastHapticT = t
            haptic.impactOccurred()
        }
    }

    /// `countAsOff` false = not a light-level decision (pause, end of scan, retry): no
    /// false-off bookkeeping. Returns false when the lock failed (torch may still be lit).
    @discardableResult
    private func switchOff(at t: TimeInterval, countAsOff: Bool) -> Bool {
        wantOn = false
        changedAt = t
        gain = nil
        gainProbeT = -1
        recent.removeAll()
        resetSustains()
        if countAsOff { lastOffAt = t }
        guard let device else { return true }
        guard (try? device.lockForConfiguration()) != nil else {
            stats.failures += 1
            lastFailAt = t
            return false
        }
        device.torchMode = .off
        device.unlockForConfiguration()
        isOn = device.isTorchActive
        return true
    }

    private func fail(_ t: TimeInterval) {
        stats.failures += 1
        lastFailAt = t
        resetSustains()
    }

    // MARK: - Helpers

    /// center = median of a 3×3 grid over the middle half of the LiDAR depth map (where the
    /// torch beam lands; nil if < 5 valid); grid = 3×3 over the WHOLE frame (0 = invalid) for
    /// the stillness test. nil = no sceneDepth / bad buffer.
    private static func depthProbe(of frame: ARFrame) -> (center: Float?, grid: [Float])? {
        guard let map = frame.sceneDepth?.depthMap,
              CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferLockBaseAddress(map, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let w = CVPixelBufferGetWidth(map)
        let h = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        guard w >= 8, h >= 8, rowBytes >= w * 4 else { return nil }
        func value(_ x: Int, _ y: Int) -> Float {
            let v = base.advanced(by: y * rowBytes + x * 4)
                .assumingMemoryBound(to: Float32.self).pointee
            return (v.isFinite && v > 0.2 && v < 8) ? v : 0
        }
        var center: [Float] = []
        var grid: [Float] = []
        center.reserveCapacity(9)
        grid.reserveCapacity(9)
        for fy in [1, 2, 3] {
            for fx in [1, 2, 3] {
                let c = value(w / 4 + fx * w / 8, h / 4 + fy * h / 8)
                if c > 0 { center.append(c) }
                // 1/8, 1/2, 7/8 of each side: a near object entering an edge band is seen.
                let gx = [w / 8, w / 2, 7 * w / 8][fx - 1]
                let gy = [h / 8, h / 2, 7 * h / 8][fy - 1]
                // 3-pixel median (gx−2, gx, gx+2): one noisy pixel does not break "still".
                let trio = [value(max(gx - 2, 0), gy), value(gx, gy), value(min(gx + 2, w - 1), gy)]
                    .filter { $0 > 0 }.sorted()
                grid.append(trio.count >= 2 ? trio[trio.count / 2] : 0)
            }
        }
        let median: Float? = center.count >= 5 ? center.sorted()[center.count / 2] : nil
        return (median, grid)
    }

    private func publishDebug(_ t: TimeInterval) {
        guard debug, t - lastDebugT >= 0.5 else { return }
        lastDebugT = t
        var s = String(format: "I %.0f", smoothI)
        if wantOn, let g = gain {
            let e = estimate(g, lastDepth)
            s += String(format: " est %.0f sh %.0f g %.0f d %.1f/%.1f",
                        e.est, e.share, g, gainDepth ?? -1, lastDepth ?? -1)
            if stepSince > 0 { s += " STEP" }
        }
        s += " · \(isOn ? "ON" : "off") on×\(stats.switchesOn) f\(stats.fastOffs)/s\(stats.slowOffs) fo\(stats.falseOffs) b\(stats.fastBounces) c\(stats.contaminated) fail\(stats.failures)"
        if device?.isTorchAvailable == false { s += " n/a" }
        debugLine = s
    }
}
