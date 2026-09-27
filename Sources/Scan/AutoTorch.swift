import Foundation
import ARKit
import AVFoundation
import ImageIO
import UIKit

/// Auto flashlight while scanning (owner 26/09, "like CubiCasa": dark → torch on, light → off).
/// Owner's field test of CubiCasa = the acceptance bar: room light switched ON while the torch
/// is lit → torch off at once; room light OFF → torch on at once; no flicker.
///
/// 🔴 SIGNAL = EXIF BrightnessValue of every frame (`ARFrame.exifData`, APEX, ABSOLUTE scene
/// brightness), ✗ `lightEstimate.ambientIntensity`. 2.60/2.61 used ambientIntensity and the
/// owner's scan (27/09, order #LS-MUJJ0HGJQ, iPhone 12 Pro, per-shot bv/iso/exp/depth) proved it
/// is NOT scene brightness: it falls only when auto-exposure runs out (ISO 3200 at the longest
/// exposure) and barely rises in bright scenes. Measured: torch ON at BV −3.7 with exposure
/// capped at 1/100 s but NOT at BV −4.2 with 1/61 s; then NEVER off — not even in daylight
/// (BV 9–10, 1/6000 s), 196 s lit. BV on that scan: dark room −4…−2, lit room 0…4, daylight
/// 6…10. With the torch on in the dark it read −3.7…−1.2 (the torch adds ~1–2 stops close up).
///
/// Rules (Lum = 2^BV, linear, smoothed over `smoothTauSec`):
///  - ON — TWO TIERS (owner 28/09 on 2.63: "bật đèn cả những vùng hơi tối trong phòng có đèn"):
///    · PITCH BLACK (raw BV more than `pitchBlackMarginBV` below onBelowBV, i.e. < −4.5): ON
///      after `pitchBlackFrames` (2) frames in a row, ~0.1–0.2 s — tracking is at stake (below).
///    · DIM/DARK (BV < onBelowBV −2.5): ON only when a log-domain average (`onSmoothTauSec`)
///      stays below for `dimSustainSec` (2 s). A dim corner panned past in a lit room is short
///      (on the 2.61 scan 7 dips below −2.5 in 330 s of lit rooms, ≤ 1.3 s each); a dark room
///      stays dark. ARKit tracked fine at BV −3…−4.25 without light (2.61 scan, pose
///      corrections ~0), so a 2 s wait there costs texture, not the mesh.
///    2.63 used one fast rule (0.3 s at −2.5) and lit the torch in dim corners of lit rooms.
///    Waits only `onSettleSec` after a switch; warm-up 1 s. The level
///    "before the ON" (`preL`, loop classifier + trace) = min(average, this frame): the
///    average still holds the lit room on a sudden drop, and a lit `preL` made real room-light
///    OFFs look like the torch's own loop (R1 of the fast-ON patch: 324/336 misread at BV −7).
///    🔴 Why fast (owner test 27/09, order #LS-MUJNJUQ56): room light switched off → 1.3 s of
///    pitch black (BV −7) before the 2.62 torch came on → ARKit had nothing to track and drifted
///    ~20 cm (shot poses from then on corrected by 19.5 cm vs ~1 cm before) → the new mesh was
///    built off the old one ("lưới bị mất", owner rescanned the floor). Darkness is what breaks
///    tracking; a torch that comes on late is the harm, one that comes on early costs little.
///  - OFF: est = Lum − share > 2^offAboveBV (−1.0 → 0.5) for `offSustainSec` (× back-off).
///    share = K/d² is an UPPER BOUND of the torch's own light, not an estimate: on that scan
///    (torch 0.7, dark rooms) close views (near depth < 1.2 m) had Lum·d² ≤ 0.41 even if ALL
///    the light were torch → K = 1.0 (~2.5× margin), scaled by level (far views mix in room
///    light, so they do not bound K). d = NEAR depth (20th percentile of a 5×5 full-frame LiDAR
///    grid, ≥ 0.3 m; none → 0.7 m) so a near white wall at the frame edge cannot pass for a lit
///    room. A room light switched on is caught by the same rule, moving or still.
///    ⚠ In practice the OFF bar is BV ≈ 0…+0.5 at 1–1.4 m near depth (K/d² ≈ 0.5–1): on that
///    scan a lit torch would stay on in 56/60 lit samples at room BV −1…0, 18/66 at 0…1,
///    10/38 at 1…2, 0/115 at ≥ 2. A "dim-lit room keeps the torch on" report = this, expected.
///  - Replay of the #LS-MUJJ0HGJQ scan (10 Hz port of this file, shot samples ~1.3 s apart):
///    5–10 ONs in 9 min, all at dark↔lit boundaries; in the dark torch-lit stretch est peaked at
///    0.15 (bar 0.5); torch off in the lit area and in daylight; lit time 196 s → ~100 s.
///  - No OFF decision for `settleSec` after any switch (exposure moving); texture shots skip it.
///  - Smoothing restarts at every switch and is fed only from `reseedDelaySec` after it (the
///    new torch state reaches the frame/exposure with some latency, worse at 30 fps when hot),
///    so after `settleSec` the reading holds only the new state (a torch-lit residue once hid
///    false offs — R1/R2 of 2.62, 10 Hz simulations with frame delay).
///  - False off (R3 "pred", simulated on the reviewers' suite): (a) the OFF is loop-like — the
///    torch ALONE explains the reading at the OFF: its own step measured at the seed after the
///    ON (seed = first reading fed after the switch), scaled 1/d² to now, ×2 tolerance; AND
///    (b) nothing switched since, dark from the first settled readings, and the reading still
///    at the seed level after that OFF (the switch alone explains the whole change). A glance
///    through a lit doorway, a hand flipping the light, a near surface coming into view while
///    walking read differently → not counted. Timing-only versions climbed the ladder on the
///    owner's own quick toggles (28/40 simulated runs stuck on) — ✗ go back to them.
///    The first is free; each later one doubles the OFF BAR for the rest of the scan (cap
///    `maxBarDoublings`), so a stronger torch stops causing false offs after a few instead of
///    blinking forever; real OFFs stay 1 s.
///  - MEASURED (#LS-MUJNJUQ56, `torch.switches`, 12 switches): at every ON, BV jumps +1…+4
///    stops within the FIRST frame (0.1 s), then only drifts ±0.7 with motion — BV does not lag
///    like auto-exposure, so the seed at 0.4 s holds the new state (the simulated loop risk
///    under a slow BV is retired). Keep logging `torch.switches` for other devices.
///  - Accepted: near a wall in a dim-lit room the bound keeps the torch on until the customer
///    steps back; a room between the two thresholds keeps whatever state it is in (hysteresis).
/// ✗ Per-scan torch-share measurement (2.60: contaminated by lights switched during settling,
/// confounded ≲3× by surface colour — 7 review rounds of patches). ✗ Probing (dimming the
/// torch to measure): visible flicker + exposure jumps in texture shots.
///
/// Every device step is optional: no device / no torch / torch unavailable (iOS disables it
/// when hot) / lock failure / no BV in exifData = the scan goes on, the "Turn on lights" coach
/// covers it (`coversLowLight` false).
///
/// Texture: torch light is harsh (hotspot, 1/d² falloff, cold LED vs warm room light) and the
/// white balance is LOCKED after warm-up (2.54) — whichever light it locked under, the other
/// gets a tint. Each shot records `torch` (level, 0 = off) so the workstation can prefer
/// non-torch shots later. LiDAR depth is unaffected (IR).
/// Heat/battery: the LED adds roughly 0.5–1 W on top of a 4–6 W scan (level 0.7), right next
/// to the camera module (that scan: thermal "serious" 7 s after the torch came on, 5.7 min in).
/// Hot phone = ARKit camera 60→30 fps (SESSION-HANDOFF §ĐÃ CHỐT thermal) → level < 1,
/// remote-tunable. iOS itself cuts the torch when too hot (isTorchAvailable false) → coach.
///
/// Calibration without a console: scan-report.json `torch.trace` (1 Hz: t, bv, near depth, on)
/// + per-shot bv/torch/depth in shots.json. Tune from those, ✗ guess.
///
/// MAIN THREAD ONLY (CADisplayLink on main, like every other scan loop). Reads
/// `arSession.currentFrame`, never takes the session delegate.
final class AutoTorch: ObservableObject {
    /// Torch lit right now (as the device reports it) — the scan screen's small indicator.
    @Published private(set) var isOn = false
    /// Debug readout, only when the hidden debug flag is on (7 taps on the version line in
    /// Account). nil otherwise — no 10 Hz SwiftUI churn for customers.
    @Published private(set) var debugLine: String?

    /// Figures for scan-report.json (owner cannot read console logs).
    struct Stats: Encodable {
        var status = "notStarted"
        var signal = "exifBrightnessValue"
        var level: Float?
        var onBelowBV: Double?
        var offAboveBV: Double?
        var shareK: Double?
        var switchesOn = 0
        var offs = 0
        var onSec: Double = 0
        var falseOffs = 0
        var failures = 0
        /// Torch went dark by itself (iOS thermal cut, capture restart) while wanted on.
        var dropped = 0
        /// Frames without a usable BrightnessValue (no decision on those).
        var noBV = 0
        var trace = Trace()
        /// Raw transient after each of the first light-level switches (see class comment).
        var switches: [SwitchTrace] = []
    }
    /// One light-level switch: direction, s since start, BV just before (OFF: average; ON:
    /// min(average, the deciding frame)), then raw BV,
    /// near depth (−1 = none) and seconds since the switch for `switchTraceSec`. All finite.
    struct SwitchTrace: Encodable {
        var on: Bool
        var t: Double
        var preBV: Double?
        var dt: [Double] = []
        var bv: [Double] = []
        var d: [Double] = []
    }
    /// 1 Hz while active: seconds since start, smoothed BV, near depth (m, −1 = none),
    /// torch lit (0/1). All finite (NaN rule: JSONEncoder throws → report lost).
    struct Trace: Encodable {
        var t: [Double] = []
        var bv: [Double] = []
        var d: [Double] = []
        var on: [Int] = []
    }
    private(set) var stats = Stats()

    // MARK: - Tuning (see the class comment before touching)
    private static let warmupSec: TimeInterval = 1
    private static let settleSec: TimeInterval = 1.0
    /// DIM/DARK tier: the log-domain BV average must stay below onBelowBV this long.
    private static let dimSustainSec: TimeInterval = 2.0
    private static let onSmoothTauSec: TimeInterval = 0.5
    /// BV this far below onBelowBV = pitch black: ON after `pitchBlackFrames` such frames.
    private static let pitchBlackMarginBV = 2.0
    private static let pitchBlackFrames = 2
    /// ON decisions resume this soon after a switch (= reseedDelaySec: seed/loop classifier).
    private static let onSettleSec: TimeInterval = 0.4
    private static let offSustainSec: TimeInterval = 1.0
    /// Dark from the first readings after an OFF: the dark stretch began before
    /// OFF + settleSec + this (ON decisions may resume from onSettleSec already).
    private static let falseOffSlackSec: TimeInterval = 0.4
    /// Smoothing is fed only from this long after a switch (torch/exposure latency).
    private static let reseedDelaySec: TimeInterval = 0.4
    private static let freeFalseOffs = 1
    /// Bar ×2 per false off after the free one, cap 8 → ×256 (BV −1 → +7). Simulated (10/15 Hz):
    /// a torch 27× the measured share settles after 4–5 false offs, 80–130× after 7–8; below
    /// cap 8 the absurd cases looped. Only a stronger-than-K torch ever climbs this ladder.
    private static let maxBarDoublings = 8
    private static let failRetrySec: TimeInterval = 5
    private static let maxDrops = 3
    private static let smoothTauSec: TimeInterval = 0.3
    /// BV older than this = signal lost → coach takes over.
    private static let bvStaleSec: TimeInterval = 2
    private static let noDepthMeters: Float = 0.7
    private static let minDepthMeters: Float = 0.3
    /// K was measured at this level; the share bound scales linearly with the level.
    private static let referenceLevel: Float = 0.7
    private static let traceMax = 3600
    private static let switchTraceMax = 12
    private static let switchTraceSec: TimeInterval = 2.5

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
    /// ON threshold (BV, raw per frame), OFF threshold (linear 2^BV) and the share bound K.
    private var onBelowBV = -2.5
    private var offAbove = 0.5
    private var shareK = 1.0

    // Timebase = ARFrame.timestamp.
    private var startT: TimeInterval = -1
    private var lastT: TimeInterval = -1
    private var smoothL = -1.0
    private var lastBVAt: TimeInterval = -.greatestFiniteMagnitude
    /// Our intent. `isOn` is the device truth.
    private var wantOn = false
    private var changedAt: TimeInterval = -.greatestFiniteMagnitude
    private var lastOffAt: TimeInterval = -.greatestFiniteMagnitude
    /// The last light-level OFF was loop-like (the torch alone explained the reading).
    private var offWasLoop = false
    /// Loop classifier: level just before the last switch (OFF: average; ON: min(average, the
    /// deciding frame)), the first reading fed after it (seed) and the clamped near depth then;
    /// −1 = none yet.
    private var preL = -1.0
    private var seedL = -1.0
    private var seedD: Float = -1
    /// Clamped near depth of the current tick (light-level OFFs read it).
    private var curD: Float = 0.7
    /// A switch trace is being filled.
    private var switchTraceOpen = false
    private var lastFailAt: TimeInterval = -.greatestFiniteMagnitude
    private var darkSince: TimeInterval = -1
    /// Consecutive pitch-black frames while off.
    private var pitchFrames = 0
    /// Log-domain BV average for the DIM tier (restarted at every switch like `smoothL`);
    /// nil = not seeded yet. `dimSince` = its sustain.
    private var smoothBV: Double?
    private var dimSince: TimeInterval = -1
    private var brightSince: TimeInterval = -1
    private var lastTraceT: TimeInterval = -.greatestFiniteMagnitude
    private var lastHapticT: TimeInterval = -.greatestFiniteMagnitude
    private var lastDebugT: TimeInterval = -1
    private var lastDepth: Float?
    private var lastEst = 0.0
    private var lastShare = 0.0
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    init(arSession: ARSession) {
        self.arSession = arSession
    }

    /// True = the torch deals with low light, so the "Turn on lights" coach stays quiet.
    /// False (no device/torch, iOS cut it, lock failing, gave up, no BV, switched off) = coach.
    var coversLowLight: Bool {
        guard enabled, !gaveUp, let device, device.hasTorch, device.isTorchAvailable else { return false }
        // Naming overlay: torch off on purpose, BV goes stale — no "Turn on lights" behind it.
        if held { return true }
        return lastT - lastFailAt > Self.failRetrySec && lastT - lastBVAt < Self.bvStaleSec
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
        // off < on + 1 stop would flicker by construction.
        let onBV = cfg.torchOnBelowBV
        let offBV = max(cfg.torchOffAboveBV, onBV + 1)
        onBelowBV = onBV
        offAbove = pow(2.0, offBV)
        shareK = cfg.torchShareK * Double(level / Self.referenceLevel)
        stats.level = level
        stats.onBelowBV = onBV
        stats.offAboveBV = offBV
        stats.shareK = cfg.torchShareK
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
        defer { publishDebug(t) }

        let lit = device.isTorchActive
        if lit { stats.onSec += dt }
        if isOn != lit { isOn = lit }

        // Lit although not wanted (an OFF whose lock failed): retry, also while inactive.
        if !wantOn && lit && t - changedAt > Self.settleSec && t - lastFailAt > Self.failRetrySec {
            switchOff(at: t, countAsOff: false)
        }

        guard isActive else { return }
        guard let bv = Self.brightnessValue(of: frame) else {
            stats.noBV += 1
            return
        }
        lastBVAt = t
        let depth = Self.nearDepth(of: frame)
        lastDepth = depth
        let d = max(depth ?? Self.noDepthMeters, Self.minDepthMeters)
        curD = d
        recordSwitchSample(t, bv: bv, depth: depth)
        let lum = pow(2.0, bv)
        // After a switch, frames within reseedDelaySec may still show the old torch state.
        if t - changedAt >= Self.reseedDelaySec {
            if let sbv = smoothBV {
                smoothBV = sbv + (bv - sbv) * min(1, dt / Self.onSmoothTauSec)
            } else {
                smoothBV = bv
            }
            if smoothL < 0 {
                smoothL = lum
                seedL = lum
                seedD = d
            } else {
                smoothL += (lum - smoothL) * min(1, dt / Self.smoothTauSec)
            }
        }

        // Wanted on but dark: iOS cut it (heat) or the capture session restarted.
        if wantOn && !lit && t - changedAt > Self.settleSec {
            stats.dropped += 1
            // Clear torchMode too, so iOS does not relight it later on its own.
            switchOff(at: t, countAsOff: false)
            lastFailAt = t // retry delay (switchOff counts a lock failure itself)
            if stats.dropped >= Self.maxDrops {
                gaveUp = true
                stats.status = "gaveUp"
            }
        }

        let share = shareK / Double(d * d)
        let est = smoothL - share
        lastEst = est
        lastShare = share
        recordTrace(t, depth: depth, lit: lit)

        guard t - startT > Self.warmupSec else { return }

        if !wantOn {
            // Two tiers (see class comment): pitch black fast, dim/dark only when it lasts.
            guard t - changedAt > Self.onSettleSec else { return }
            sustain(&darkSince, bv < onBelowBV, t) // raw: loop classifier (switchOn)
            if let sbv = smoothBV {
                sustain(&dimSince, sbv < onBelowBV, t)
            } else {
                dimSince = -1
            }
            pitchFrames = bv < onBelowBV - Self.pitchBlackMarginBV ? pitchFrames + 1 : 0
            let dimLasted = dimSince > 0 && t - dimSince >= Self.dimSustainSec
            if dimLasted || pitchFrames >= Self.pitchBlackFrames,
               !gaveUp, t - lastFailAt > Self.failRetrySec, device.isTorchAvailable {
                switchOn(at: t, frameLum: lum)
            }
            return
        }
        guard t - changedAt > Self.settleSec else { return }

        let doublings = min(max(0, stats.falseOffs - Self.freeFalseOffs), Self.maxBarDoublings)
        let bar = offAbove * pow(2.0, Double(doublings))
        sustain(&brightSince, est > bar, t)
        if brightSince > 0 && t - brightSince >= Self.offSustainSec {
            stats.offs += 1
            switchOff(at: t, countAsOff: true)
        }
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
        brightSince = -1
        pitchFrames = 0
        dimSince = -1
    }

    /// The reading is still at the seed level and the seed moved away from the pre-switch
    /// level: the switch alone explains the whole change since.
    private var loopLike: Bool {
        guard seedL > 0, preL > 0, smoothL > 0 else { return false }
        return abs(log2(smoothL) - log2(seedL)) < abs(log2(seedL) - log2(preL))
    }

    private func startSwitchTrace(on: Bool, _ t: TimeInterval, preLum: Double) {
        switchTraceOpen = false
        guard stats.switches.count < Self.switchTraceMax else { return }
        let rel = t - startT
        guard rel.isFinite else { return }
        var pre: Double?
        if preLum > 0 {
            let v = log2(preLum)
            if v.isFinite { pre = (v * 100).rounded() / 100 }
        }
        stats.switches.append(SwitchTrace(on: on, t: (rel * 10).rounded() / 10, preBV: pre))
        switchTraceOpen = true
    }

    private func recordSwitchSample(_ t: TimeInterval, bv: Double, depth: Float?) {
        guard switchTraceOpen, let i = stats.switches.indices.last else { return }
        let since = t - changedAt
        guard since <= Self.switchTraceSec else {
            switchTraceOpen = false
            return
        }
        guard since.isFinite, bv.isFinite else { return }
        stats.switches[i].dt.append((since * 1000).rounded() / 1000)
        stats.switches[i].bv.append((bv * 100).rounded() / 100)
        let dd = depth.map { Double($0) } ?? -1
        stats.switches[i].d.append(dd.isFinite ? (dd * 100).rounded() / 100 : -1)
    }

    private func recordTrace(_ t: TimeInterval, depth: Float?, lit: Bool) {
        guard t - lastTraceT >= 1, stats.trace.t.count < Self.traceMax, smoothL > 0 else { return }
        let bv = log2(smoothL)
        let rel = t - startT
        guard bv.isFinite, rel.isFinite else { return }
        lastTraceT = t
        stats.trace.t.append((rel * 10).rounded() / 10)
        stats.trace.bv.append((bv * 100).rounded() / 100)
        let d = depth.map { Double($0) } ?? -1
        stats.trace.d.append(d.isFinite ? (d * 100).rounded() / 100 : -1)
        stats.trace.on.append(lit ? 1 : 0)
    }

    // MARK: - Device

    /// `frameLum`: this frame's 2^BV — the average lags a sudden drop (see class comment).
    private func switchOn(at t: TimeInterval, frameLum: Double) {
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
        // False off (see class comment): loop-like OFF, nothing switched since, dark from the
        // first settled readings, reading still at the seed level after that OFF.
        // Raw OR dim-average darkness (a dim-tier ON comes ≥ 2.4 s after the OFF; one noisy raw
        // frame resets the raw sustain — counting only raw lost the loop signature).
        let lim = Self.settleSec + Self.falseOffSlackSec
        let off = lastOffAt
        let darkAtOnce = [darkSince, dimSince].contains { $0 > 0 && $0 - off < lim }
        if offWasLoop, lastOffAt == changedAt, darkAtOnce, loopLike {
            stats.falseOffs += 1
        }
        let pre = smoothL > 0 ? min(smoothL, frameLum) : frameLum
        startSwitchTrace(on: true, t, preLum: pre)
        preL = pre
        wantOn = true
        changedAt = t
        smoothL = -1 // restart smoothing: after settle it holds the torch-lit state only
        smoothBV = nil
        seedL = -1
        seedD = -1
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
        if countAsOff {
            // Loop-like: the torch alone explains the reading — its step measured at the seed
            // after the ON, scaled 1/d² to the current near depth, ×2 tolerance.
            var loop = false
            if seedL > 0, preL > 0, seedD > 0, smoothL > 0 {
                let step = max(seedL - preL, 0) * Double(seedD * seedD)
                let predicted = preL + step / Double(curD * curD)
                loop = smoothL <= predicted * 2
            }
            offWasLoop = loop
            lastOffAt = t
            startSwitchTrace(on: false, t, preLum: smoothL)
        } else {
            switchTraceOpen = false
        }
        preL = smoothL
        wantOn = false
        changedAt = t
        smoothL = -1 // restart smoothing: after settle it holds the unlit state only
        smoothBV = nil
        seedL = -1
        seedD = -1
        resetSustains()
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

    /// EXIF BrightnessValue (APEX) of this frame: top level or nested {Exif}; number or
    /// one-element array. nil = missing / non-finite / absurd.
    private static func brightnessValue(of frame: ARFrame) -> Double? {
        var exif = frame.exifData
        if let nested = exif[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif = nested
        }
        let value = exif[kCGImagePropertyExifBrightnessValue as String]
        var bv: Double?
        if let n = value as? NSNumber {
            bv = n.doubleValue
        } else if let list = value as? [NSNumber], let first = list.first {
            bv = first.doubleValue
        }
        guard let bv, bv.isFinite, bv > -20, bv < 30 else { return nil }
        return bv
    }

    /// Near depth in front: 20th percentile of a 5×5 grid over the WHOLE LiDAR depth map
    /// (valid 0.2–8 m, ≥ 8 points). nil = no sceneDepth / bad buffer / too few points.
    private static func nearDepth(of frame: ARFrame) -> Float? {
        guard let map = frame.sceneDepth?.depthMap,
              CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferLockBaseAddress(map, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let w = CVPixelBufferGetWidth(map)
        let h = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        guard w >= 10, h >= 10, rowBytes >= w * 4 else { return nil }
        var samples: [Float] = []
        samples.reserveCapacity(25)
        for j in 0..<5 {
            for i in 0..<5 {
                let x = (2 * i + 1) * w / 10
                let y = (2 * j + 1) * h / 10
                let v = base.advanced(by: y * rowBytes + x * 4)
                    .assumingMemoryBound(to: Float32.self).pointee
                if v.isFinite, v > 0.2, v < 8 { samples.append(v) }
            }
        }
        guard samples.count >= 8 else { return nil }
        samples.sort()
        return samples[samples.count / 5]
    }

    private func publishDebug(_ t: TimeInterval) {
        guard debug, t - lastDebugT >= 0.5 else { return }
        lastDebugT = t
        let bv = smoothL > 0 ? log2(smoothL) : -99
        var s = String(format: "bv %.2f est %.2f sh %.2f d %.2f", bv, lastEst, lastShare, lastDepth ?? -1)
        s += " · \(isOn ? "ON" : "off") on×\(stats.switchesOn) off×\(stats.offs) fo\(stats.falseOffs) fail\(stats.failures)"
        if device?.isTorchAvailable == false { s += " n/a" }
        if lastT - lastBVAt >= Self.bvStaleSec { s += " noBV" }
        debugLine = s
    }
}
