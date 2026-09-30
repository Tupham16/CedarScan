import Foundation
import ARKit
import AVFoundation
import Combine
import CoreMedia
import ImageIO
import QuartzCore

/// EXPOSURE CAP — ON FOR EVERY CUSTOMER since 2.73 (owner 30/09 "ok làm 2.72" after the 2.70.2
/// measurements; 2.72 went to the Home headers first). Tested as branch `claude/exposure-cap-adaptive`
/// (2.70.1 hard, 2.70.2 adaptive).
/// Which mode a scan runs is decided ONCE at its start (`resolveMode`):
///  1. hidden debug mode on (7 taps on the version line in Account) AND a pick other than "Default"
///     in its "Exposure cap" picker → that pick (Off / Adaptive / Hard 4 / 6 / 8 ms; owner tests);
///  2. else the SERVER KILL SWITCH: `scan-quality-config` `{"exposureCap": "off"}` → off
///     (ScanQualityConfig.exposureCap; arrives with `catalog()` = the order form, persisted, so an
///     "off" applies from the device's next scan after that);
///  3. else adaptive (the default; also with no server row / no key).
/// Off never sets anything on the device (it still traces and records `expMaxMs` = the baseline).
///
/// MEASURED 2.70.2 ADAPTIVE (owner's phone, #LS-MUNOBU41H): 56% of shots at 4 ms, blur p50 3.4 px
/// (2.70: 8.4), darkest-quarter photo luma 100 (uncapped 96) = dark rooms no darker, tracking
/// normal, 20 up / 18 down steps, JPEG 105 KB/shot, device ISO / EXIF ISO 0.996. No tube-light test.
///
/// WHY: texture photos are motion-blurred. ARKit's auto-exposure never goes below 10 ms (the 50 Hz
/// anti-flicker step) / 16.4 ms, even in bright rooms, and the phone turns ~31°/s at shot time.
/// MEASURED 2.70.1 (hard 4 ms, #LS-MUNIC2NLP vs a 2.70 scan of the same floor): cap held on every
/// frame, tracking normal 474/476 s, no banding in that house, predicted blur p50 8.4 → 2.3 px,
/// textures visibly crisper; cost: ISO at the format max on 43% of frames → dark rooms ~1 stop
/// darker and noisier. 2.70.2 = ADAPTIVE (owner-approved): 4 ms, lengthened only as far as the light
/// needs once the ISO has run out.
///
/// HOW (all modes): auto-exposure stays ON; only its upper limit (`activeMaxExposureDuration`) is
/// changed on ARKit's own capture device (`configurableCaptureDeviceForPrimaryCamera`, the one 2.54
/// locks the white balance on). Measured: AE then uses the WHOLE limit and trades ISO (4 ms at
/// ISO 32…3200; shorter only at ISO min in daylight). Defences kept from 2.70.1:
///  - first set `applyDelaySec` after start, at a tick where tracking is normal and frames advance
///    (paused / interrupted = the same frame again): ARKit configures the device when its capture
///    session starts, and a format change resets the limit to the default;
///  - reset = the device no longer holds OUR read-back value (format change, capture restart after
///    an interruption) → the device's value is its new own limit, ours is set again at a normal
///    tick (`resets`, times in `setAt`); ≥ `loopSets` first/reset sets within `loopWindowSec` =
///    something keeps undoing it → give up. Adaptive steps do NOT count towards that guard;
///  - the setter RAISES (ObjC exception = crash, not a throw) outside activeFormat's
///    min…maxExposureDuration and without the configuration lock: every value is clamped under the
///    lock to [floor, ceiling] ⊂ that range (floor = the mode's ms clamped to the range, ceiling =
///    the device's own limit clamped to it; exact CMTimeCompare); an unusable range = give up;
///  - never ABOVE the device's own limit (ARKit's default, 16.667 ms measured): device limit already
///    ≤ floor → nothing set ("notNeeded");
///  - read-back checked (`appliedTolerance` both ways): the setter ignored = give up; lock failures:
///    retried ≥ `lockRetrySec` apart, give up after `maxLockFailures` IN A ROW (≥ 5 s, as 2.70.1);
///  - any give-up puts the device's own limit back at once when ours is on it (review R1: a short
///    limit left behind would keep a dark room dark), retried every `lockRetrySec`, else at teardown;
///  - only while AE runs (continuous/auto): a locked/custom exposure mode ignores the limit;
///  - restored at teardown (both exits, BEFORE arSession.pause — the device outlives the session)
///    to the device's own value, only if the device still holds OUR value; a failed restore is
///    retried 0.5 s later and then at the next scan's start (`stale`; stuck there = `staleAtStart`).
///  - Kill switches: server `{"exposureCap": "off"}` for everyone; the debug picker per phone
///    (resolution order at the top). Off never sets anything (it still traces, shows the debug
///    readout and records `expMaxMs` = A/B baseline).
///
/// ADAPTIVE (mode `adaptive4`, the default). Loop at 10 Hz on main (2.70.1: 2 Hz), inputs = the
/// capture device's `iso` / `activeFormat.maxISO` (`isoFrac`: same scale, unrounded — review R1: EXIF
/// ISO is rounded to 1/3-stop values, a 2112 max reads 2000 = 0.947, so an EXIF bar at 0.95 would
/// never fire; EXIF ISO / maxISO only if the device gives no ISO) and ARKit's `exposureOffset`
/// (`ev`, AE's target offset: measured on 2.70.1 to track the underexposure, r −0.98).
///  - Start: 4 ms; a scan that starts in a dim room starts directly at the limit where its ISO would
///    sit at `startISOFrac` of the max (else a 2-stop dip right when tracking starts). After a reset
///    (interruption, format change) ours goes back as max(ours, that estimate for the current light).
///  - UP (starved): isoFrac ≥ 0.95 AND ev ≤ −0.3 for `upSustainSec` (0.2 s, 3 ticks) → limit ×
///    2^(0.8 × shortfall), shortfall = the LEAST negative ev of the window, step ×1.25…×2, ≤ ceiling.
///    Proportional, not a fixed ×1.25: walking into a BV −2.3 room the offline sim (2.70.1 trace,
///    AE modelled as measured) is within 0.3 stop after ~1.0 s (fixed ×1.25: 2.8 s; 2 Hz: 1.6 s).
///  - DOWN (headroom): isoFrac < 0.6 for `downSustainSec` (1 s) and ≥ `reverseDwellSec` (2 s) after
///    the last UP → limit × max(isoFrac/0.8, 0.5) (≤ ×0.8), ≥ floor ⇒ the ISO lands at ≤ ~80% of max,
///    well under the 0.95 UP bar: one step can never trigger the opposite one (hysteresis ≥ 0.6
///    stop plus the 0.3-stop ev bar). A positive ev alone does NOT step down: with AE using the whole
///    limit it is a transient that the ISO settles within frames.
///  - A step landing within 5 % of the ceiling / floor snaps to it (no 16.0 / 4.17 ms leftovers).
///  - No decision for `settleSec` (0.3 s) after any set (AE follows a new limit within a few frames;
///    30 fps when hot), and the sustain windows restart after every set and on a paused frame.
///    Texture shots skip the frames of that settle too (`isSettling`, like the torch's).
///  - No ISO or ev for `noSignalSec` (1 s) = give up (`gaveUp:noSignal`) + restore.
///  - Why 10 Hz: an UP needs ≥ 3 samples in its 0.2 s window; at 2 Hz each step takes ≥ 1.5 s and a
///    dark room stays 1–2 stops underexposed for seconds (tracking risk below). Cost: one
///    `currentFrame` + `exifData` read per tick (AutoTorch already does the same at 10 Hz) and
///    unlocked device reads; ≤ 2 locked sets per second by construction (settle + sustain).
///  - Offline sim on the 2.70.1 scan (`scratch_exposure-cap/sim-2.70.2/sim.py` in the main
///    checkout, untracked): ~55% of shots at a full 4 ms, blur p50 ~3.0 px (uncapped 9.5, hard
///    4 ms 2.3), shots > 0.3 stop underexposed ~7% (uncapped 3%, hard 4 ms 32%), ~50 UP / ~35 DOWN
///    steps in 476 s. The workstation's ideal rule said 65% / 2.9 px / 0%: hysteresis + ramp lag
///    cost the difference. Measured on the device (2.70.2): 56% / 3.4 px (top of this comment).
///  - HARD modes (`hard4/6/8`) = 2.70.1: fixed limit, no steps.
///
/// What to expect / risks:
///  - Banding under mains-flickering light (tubes, cheap LED drivers): only an exposure of whole
///    flicker periods (10 ms at 50 Hz, 8.3 ms at 60 Hz) averages it out. Lit rooms stay at 4 ms in
///    adaptive mode too → same banding risk as hard 4 ms (none found in the owner's house; no
///    tube-light test yet). Customers report bands → the server kill switch (top of this comment).
///  - Dark rooms: adaptive climbs to the device default (= uncapped) within ~1 s, so a dark room
///    gets what 2.70 gave it after that ramp; the 2.70.1 risk (dim room ~2 stops darker for ARKit
///    while the torch waits 2 s) is reduced to that ramp.
///  - Auto torch (EXIF BrightnessValue): BV is compensated for exposure, ISO and ev (2.70.1 k-check:
///    bv − (Tv − Sv) − ev on the capped scan's ISO-max shots 1.61 vs 1.62 expected from the uncapped
///    trend) → the limit should not move BV, the torch decides at the same scene brightness (2.70.1:
///    5 ON / 5 OFF, 0 false offs, 92 s lit at 4 ms). Nothing here reads the torch and nothing in
///    AutoTorch reads the limit → no loop. 🔴 But a torch-lit dark room still reads BV −1…−2, where
///    4 ms runs out of ISO (2.70.1 trace: torch on at ISO 3200, ev −0.9…−1.4) → adaptive steps UP
///    to ~8–16 ms and torch-lit shots lose most of the 4 ms gain; torch OFF (lit room) → ISO falls
///    → DOWN after ≥ 1 s. Owner's policy call later; unchanged here. `steps[].bv` (10 Hz EXIF BV for
///    1 s after each of the first `stepBVLogSteps` steps) checks that a step does not move BV.
///  - "Turn on lights" coach (ambientIntensity, falls when AE runs out): back to 2.70's behaviour
///    after the ramp.
///  - Data: scan-report.json `exposureCapMs` (floor / hard ms, 0 = off), `exposureCapMode`
///    (adaptive | hard | off), `exposureCap` {…, ceilingMs, stepsUp, stepsDown, limMsMax, exifIsoMax,
///    `steps` t / lim / iso / diso / ev / bv0 / bv, `trace` 1 Hz t / bv / exp / iso / diso / ev /
///    lim}; shots.json per shot `expMaxMs` (the device's AE limit when the frame was copied).
///
/// MAIN THREAD ONLY (own Timer on main, like the other scan loops). Reads `arSession.currentFrame`,
/// never takes the session delegate.
final class ExposureCap: ObservableObject {
    /// What a scan runs (resolved at its start, see `resolveMode`).
    enum Mode: String {
        case off, adaptive4, hard4, hard6, hard8

        /// The floor (adaptive) or the fixed limit (hard), ms; 0 = off.
        var capMs: Int {
            switch self {
            case .off: return 0
            case .adaptive4, .hard4: return 4
            case .hard6: return 6
            case .hard8: return 8
            }
        }

        var isAdaptive: Bool { self == .adaptive4 }

        /// scan-report.json `exposureCapMode`.
        var reportName: String {
            switch self {
            case .off: return "off"
            case .adaptive4: return "adaptive"
            case .hard4, .hard6, .hard8: return "hard"
            }
        }
    }

    /// Hidden debug picker (Account, only while the debug mode is on). `auto` = what customers
    /// get (adaptive, or off when the server says so).
    enum DebugChoice: String, CaseIterable, Identifiable {
        case auto, off, adaptive4, hard4, hard6, hard8

        var id: String { rawValue }

        /// nil = `auto`.
        var mode: Mode? { Mode(rawValue: rawValue) }

        /// Picker text (English, verbatim — owner-only debug UI, no translation keys).
        var label: String {
            switch self {
            case .auto: return "Default"
            case .off: return "Off"
            case .adaptive4: return "Adaptive 4 ms"
            case .hard4: return "Hard 4 ms"
            case .hard6: return "Hard 6 ms"
            case .hard8: return "Hard 8 ms"
            }
        }
    }

    /// UserDefaults key of the debug picker (DebugChoice raw value). NEW in 2.73: the test builds'
    /// keys (`scanExposureCapMs` 2.70.1, `scanExposureCapMode` 2.70.2) are ignored, so a test pick
    /// never carries into the customer build.
    static let debugChoiceKey = "scanExposureCapDebug"
    /// Account's hidden debug flag (AccountView `scanDebugReadout`).
    static let debugFlagKey = "scanDebugReadout"

    /// The mode of a scan starting now + where it came from (scan-report `exposureCap.source`):
    /// the debug pick only while the debug mode is ON (a customer never has it; turning debug off
    /// puts the owner's phone back on the customer path), else the server switch, else adaptive.
    static func resolveMode() -> (mode: Mode, source: String) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: debugFlagKey),
           let raw = defaults.string(forKey: debugChoiceKey),
           let mode = DebugChoice(rawValue: raw)?.mode {
            return (mode, "debug")
        }
        if ScanQualityConfig.current.exposureCapOff { return (.off, "server") }
        return (.adaptive4, "default")
    }

    /// Debug readout (only with the hidden debug flag): mode, device limit, exp/iso/ev of the frame.
    @Published private(set) var debugLine: String?

    /// One 1 Hz sample (seconds since scan start; raw EXIF bv, exposure ms, ISO; the device's ISO;
    /// ARKit exposureOffset; the device limit in ms). Absent keys = not available.
    struct TracePoint: Encodable {
        let t: Double
        let bv: Double?
        let exp: Double?
        let iso: Double?
        let diso: Double?
        let ev: Double?
        let lim: Double?
    }

    /// One adaptive step: seconds since scan start, the limit the device read back after it (ms),
    /// the EXIF ISO / device ISO / ARKit exposureOffset / EXIF BV of the tick that decided it, and
    /// (first `stepBVLogSteps` steps only) the EXIF BV of every tick for `stepBVLogSec` after it.
    struct StepPoint: Encodable {
        let t: Double
        let lim: Double?
        let iso: Double?
        let diso: Double?
        let ev: Double?
        let bv0: Double?
        var bv: [Double]?
    }

    /// scan-report.json `exposureCap`. Doubles are rounded and finite (JSONEncoder rule).
    struct Stats: Encodable {
        /// notStarted | off | noDevice | unsupported | pending | capped | notNeeded | notApplied
        /// | notAutoExposure:<mode> | lockFailed:<code> | badRange | gaveUp:lockFailed
        /// | gaveUp:resetLoop | gaveUp:notApplied | gaveUp:stepNotApplied | gaveUp:noSignal
        var status = "notStarted"
        /// off | adaptive | hard
        var mode = "off"
        /// Where the mode came from: default (adaptive) | server (kill switch "off") | debug (picker).
        var source = "default"
        /// Floor (adaptive) / fixed limit (hard), ms; 0 = off.
        var capMs = 0
        /// Device limit read back after our first set, ms.
        var appliedMs: Double?
        /// Seconds after scan start of the first set.
        var appliedAt: Double?
        /// Seconds after scan start of the first set and every reset set (not adaptive steps),
        /// ≤ `maxSetTimes`.
        var setAt: [Double] = []
        /// Seconds after scan start of a give-up.
        var gaveUpAt: Double?
        /// Device limit before our first set = ARKit's default, ms.
        var deviceDefaultMs: Double?
        var formatMinMs: Double?
        var formatMaxMs: Double?
        var formatMaxISO: Double?
        /// The mode's ms was outside the format range and got clamped.
        var clamped = false
        /// Times the device limit was found changed by someone else and set again.
        var resets = 0
        var lockFailures = 0
        /// A limit left by an earlier scan (failed restore) was still on the device at start —
        /// this scan's numbers may not be what the setting says (per-shot `expMaxMs` tells).
        var staleAtStart = false
        /// Frames sampled at 2 Hz while our limit is in force and tracking normal…
        var framesSampled = 0
        /// …whose EXIF exposure time was above the limit (+10 % + 0.1 ms) = the limit NOT honoured;
        var framesOverCap = 0
        /// …at ≥ 0.8 × the limit = the limit was actually binding (a bright room never reaches it);
        var framesAtCap = 0
        /// …at ≥ 0.95 × the format's max ISO (EXIF, rounded) = AE had run out (darker than uncapped).
        var framesIsoMax = 0
        var expMsMax: Double?
        /// Highest EXIF ISO seen (2 Hz samples) — vs formatMaxISO: the EXIF scale / rounding.
        var exifIsoMax: Double?
        /// Adaptive top = the device's own limit (ms) at the first set / last reset.
        var ceilingMs: Double?
        var stepsUp = 0
        var stepsDown = 0
        /// Highest limit the device held as ours (read back after a set), ms.
        var limMsMax: Double?
        /// Every adaptive step, ≤ `maxStepLog`.
        var steps: [StepPoint] = []
        /// true = the device's own limit is back (at a give-up or at teardown, or the device already
        /// held its own again), false = restore failed (retried later), nil = nothing to restore.
        var restored: Bool?
        /// 1 Hz, whole scan (also with the cap Off = the A/B baseline), ≤ `traceMax` points.
        var trace: [TracePoint] = []
    }
    private(set) var stats = Stats()

    static let applyDelaySec: CFTimeInterval = 1.0
    /// 10 Hz — see ADAPTIVE in the class comment.
    private static let tickSec: TimeInterval = 0.1
    /// Stats sampling and the debug readout stay at 2 Hz (framesSampled comparable with 2.70.1).
    private static let sampleSec: CFTimeInterval = 0.45
    private static let traceSec: CFTimeInterval = 0.95
    /// ≥ this many first/reset sets within `loopWindowSec` = a reset loop: give up.
    private static let loopSets = 10
    private static let loopWindowSec: CFTimeInterval = 30
    private static let maxSetTimes = 100
    /// Lock failures IN A ROW before giving up; a failed lock is retried after `lockRetrySec`.
    private static let maxLockFailures = 10
    private static let lockRetrySec: CFTimeInterval = 0.5
    private static let traceMax = 3600
    private static let maxStepLog = 300
    private static let stepBVLogSteps = 12
    private static let stepBVLogSec: CFTimeInterval = 1.0
    /// A read-back outside want ÷/× this = the setter did not take.
    private static let appliedTolerance = 1.25
    // ── Adaptive loop (class comment). Tuning levers; the sim barely moved with them (±0.2 px).
    private static let settleSec: CFTimeInterval = 0.3
    private static let starvedISOFrac = 0.95
    private static let starvedEV = -0.3
    private static let upSustainSec: CFTimeInterval = 0.2
    private static let upGain = 0.8
    private static let upMinFactor = 1.25
    private static let upMaxFactor = 2.0
    private static let brightISOFrac = 0.6
    private static let downSustainSec: CFTimeInterval = 1.0
    private static let downTargetISOFrac = 0.8
    private static let downMinFactor = 0.5
    private static let downMaxFactor = 0.8
    private static let reverseDwellSec: CFTimeInterval = 2.0
    /// Within this share of the ceiling / floor: no step (not worth a lock) / a step snaps to it.
    private static let edgeBand = 0.05
    /// First adaptive limit = the one where the ISO would sit at this fraction of the max.
    private static let startISOFrac = 0.8
    /// Adaptive without ISO or ev this long = give up (+ restore).
    private static let noSignalSec: CFTimeInterval = 1.0
    /// Sustain windows are measured on a ~10 Hz Timer: this much slack for its jitter.
    private static let tickSlack: CFTimeInterval = 0.01

    private weak var arSession: ARSession?
    /// The device we limit; nil = off / unsupported / no device.
    private var device: AVCaptureDevice?
    /// ARKit's primary camera, only READ (trace / readout show its limit even with the cap off).
    private var readDevice: AVCaptureDevice?
    private var timer: Timer?
    private var t0: CFTimeInterval = 0
    private var mode: Mode = .off
    private var capMs = 0
    private var dueAt: CFTimeInterval = .greatestFiniteMagnitude
    private var debug = false
    private var stopped = false
    private var gaveUp = false
    private var recentSets: [CFTimeInterval] = []
    private var lockFailuresInRow = 0
    /// No lock (set or give-up restore) before this host time: lock-failure back-off.
    private var nextLockAt: CFTimeInterval = 0
    /// AE needs a few frames to follow a new limit: no decision / honoured-sample right after a set.
    private var lastSetAt: CFTimeInterval = -.greatestFiniteMagnitude
    /// ARFrame.timestamp of the tick that set the limit last (texture-shot settle gate).
    private var lastSetFrameT: TimeInterval = -.greatestFiniteMagnitude
    private var lastUpAt: CFTimeInterval = -.greatestFiniteMagnitude
    private var lastSampleAt: CFTimeInterval = -.greatestFiniteMagnitude
    private var lastTraceAt: CFTimeInterval = -.greatestFiniteMagnitude
    private var lastFrameT: TimeInterval = -1
    /// The device's own limit (restored at teardown; the adaptive ceiling) and the value the
    /// device read back after our last set.
    private var original: CMTime?
    private var ourValue: CMTime?
    /// Floor / ceiling in seconds as of the first set / last reset (decisions only — every set
    /// clamps again under the lock).
    private var floorS: Double = 0
    private var ceilS: Double = 0
    /// Sustain windows of the adaptive loop.
    private var starvedSince: CFTimeInterval?
    private var starvedEVMax = 0.0
    private var brightSince: CFTimeInterval?
    private var brightISOMax = 0.0
    private var noSignalSince: CFTimeInterval?
    /// Step whose EXIF BV is being logged at every tick, until `bvLogUntil`.
    private var bvLogIndex: Int?
    private var bvLogUntil: CFTimeInterval = 0

    /// A restore that failed at the end of an earlier scan (lock busy): retried at the next start.
    private static var stale: (device: AVCaptureDevice, original: CMTime, ours: CMTime)?

    private typealias Exposure = (expMs: Double?, iso: Double?, bv: Double?)

    // MARK: - Lifecycle (main)

    /// Scan start, right after `arSession.run` (MeshScanController.startSession).
    func start(device primary: AVCaptureDevice?, arSession session: ARSession) {
        guard t0 == 0 else { return }
        t0 = CACurrentMediaTime()
        arSession = session
        readDevice = primary
        debug = UserDefaults.standard.bool(forKey: Self.debugFlagKey)
        if let s = Self.stale {
            if Self.restore(s.device, original: s.original, ours: s.ours) {
                Self.stale = nil
            } else {
                stats.staleAtStart = true
            }
        }
        let resolved = Self.resolveMode()
        mode = resolved.mode
        capMs = mode.capMs
        stats.mode = mode.reportName
        stats.source = resolved.source
        stats.capMs = capMs
        if capMs <= 0 {
            stats.status = "off"
        } else if let primary {
            if primary.isExposureModeSupported(.continuousAutoExposure) {
                device = primary
                stats.status = "pending"
                dueAt = t0 + Self.applyDelaySec
            } else {
                stats.status = "unsupported"
            }
        } else {
            stats.status = "noDevice"
        }
        // Always, also Off: the trace of an Off scan is the A/B baseline.
        let timer = Timer(timeInterval: Self.tickSec, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// End of scan (both exits, BEFORE arSession.pause — MeshScanController.teardownCommon).
    func stop() {
        guard !stopped else { return }
        stopped = true
        timer?.invalidate()
        timer = nil
        clearSustain()
        if debugLine != nil { debugLine = nil }
        if let device, let original, let ourValue {
            self.original = nil
            self.ourValue = nil
            // Ours == the device's own (adaptive at the ceiling): nothing to put back.
            if Self.sameValue(original, ourValue) || Self.restore(device, original: original, ours: ourValue) {
                stats.restored = true
            } else {
                stats.restored = false
                Self.stale = (device, original, ourValue)
            }
        } else if let s = Self.stale, Self.restore(s.device, original: s.original, ours: s.ours) {
            // An older scan's failed restore that this scan's start could not do either.
            Self.stale = nil
        }
        guard Self.stale != nil else { return }
        // Lock busy right now: one more try shortly (the report is written after the save's
        // awaits, usually later), then at the next scan's start.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let s = Self.stale else { return }
            if Self.restore(s.device, original: s.original, ours: s.ours) {
                Self.stale = nil
                if self?.stats.restored == false { self?.stats.restored = true }
            }
        }
    }

    /// Safety net only — both scan exits call `stop()` first (teardownCommon).
    deinit {
        timer?.invalidate()
        if let device, let original, let ourValue, !Self.sameValue(original, ourValue) {
            _ = Self.restore(device, original: original, ours: ourValue)
        }
    }

    /// Texture shots skip frames captured this close after a limit change (AE still moving;
    /// TextureShotRecorder, like `AutoTorch.isSettling`). `t` = ARFrame.timestamp.
    func isSettling(at t: TimeInterval) -> Bool {
        t - lastSetFrameT < Self.settleSec
    }

    // MARK: - Loop (main, 10 Hz)

    private func tick() {
        guard !stopped, let frame = arSession?.currentFrame else {
            pauseReset()
            return
        }
        let t = frame.timestamp
        // Paused / interrupted = the same frame again: no set, no sample, windows start over.
        guard t != lastFrameT else {
            pauseReset()
            return
        }
        lastFrameT = t
        var normal = false
        var tracked = true
        switch frame.camera.trackingState {
        case .normal: normal = true
        case .notAvailable: tracked = false
        case .limited: break
        }
        let now = CACurrentMediaTime()
        // Read once ARKit's format is surely in place (right after `run` it may not be yet).
        if normal, stats.formatMaxISO == nil, let readDevice {
            stats.formatMaxISO = Self.fin(Double(readDevice.activeFormat.maxISO))
        }
        let sampleDue = now - lastSampleAt >= Self.sampleSec
        let traceDue = now - lastTraceAt >= Self.traceSec && stats.trace.count < Self.traceMax
        let controlling = !gaveUp && device != nil && now >= dueAt
        let bvLogging = bvLogIndex != nil
        let restoreDue = gaveUp && ourValue != nil
        guard controlling || sampleDue || traceDue || bvLogging || restoreDue else { return }
        let expo = Self.exifExposure(frame)
        let evRaw = Double(frame.camera.exposureOffset)
        let ev: Double? = evRaw.isFinite ? evRaw : nil
        if controlling, let device {
            control(device, frame: frame, expo: expo, ev: ev, normal: normal, tracked: tracked, now: now)
        }
        if gaveUp { restoreAfterGiveUp(now: now) }
        if let i = bvLogIndex {
            if now > bvLogUntil || i >= stats.steps.count {
                bvLogIndex = nil
            } else if let bv = expo.bv.flatMap({ Self.fin($0) }) {
                stats.steps[i].bv?.append(bv)
            }
        }
        let limitMs = readDevice.flatMap { Self.ms($0.activeMaxExposureDuration) }
        if sampleDue {
            lastSampleAt = now
            if let iso = expo.iso { stats.exifIsoMax = Self.fin(max(stats.exifIsoMax ?? 0, iso)) }
            // Honoured? Only while the device holds OUR limit and AE had time to follow it.
            if normal, let device, let ours = ourValue, now - lastSetAt >= 0.5,
               Self.atOrBelow(device.activeMaxExposureDuration, ours),
               let expMs = expo.expMs, let limit = Self.ms(ours) {
                stats.framesSampled += 1
                if expMs > limit * 1.1 + 0.1 { stats.framesOverCap += 1 }
                if expMs >= limit * 0.8 { stats.framesAtCap += 1 }
                if let iso = expo.iso, let maxISO = stats.formatMaxISO, maxISO > 0, iso >= maxISO * 0.95 {
                    stats.framesIsoMax += 1
                }
                stats.expMsMax = Self.fin(max(stats.expMsMax ?? 0, expMs))
            }
            if debug { publishDebug(expo, ev: ev, limitMs: limitMs) }
        }
        if traceDue {
            lastTraceAt = now
            stats.trace.append(TracePoint(
                t: Self.fin(now - t0) ?? 0,
                bv: expo.bv.flatMap { Self.fin($0) },
                exp: expo.expMs.flatMap { Self.fin($0) },
                iso: expo.iso.flatMap { Self.fin($0) },
                diso: readDevice.flatMap { Self.deviceISO($0) },
                ev: ev.flatMap { Self.fin($0) },
                lim: limitMs
            ))
        }
    }

    /// First set, reset re-set, or an adaptive step.
    private func control(
        _ device: AVCaptureDevice, frame: ARFrame, expo: Exposure, ev: Double?, normal: Bool,
        tracked: Bool, now: CFTimeInterval
    ) {
        let frameT = frame.timestamp
        guard let ours = ourValue else {
            // Nothing of ours on the device yet: first set at a normal tick, like 2.70.1. Unlocked
            // pre-check — a device whose own limit is already ≤ the floor takes no lock (re-checked
            // every normal tick: a later format may have a longer default).
            guard normal else { return }
            guard let floor = Self.clampedCap(capMs, device.activeFormat) else {
                giveUp("badRange", now: now)
                return
            }
            let current = device.activeMaxExposureDuration
            guard !Self.atOrBelow(current, floor) else {
                if stats.status == "pending" || stats.status.hasPrefix("lockFailed") {
                    stats.status = "notNeeded"
                    stats.deviceDefaultMs = Self.ms(current)
                }
                return
            }
            apply(device, want: startLimit(device, expo: expo, ev: ev), kind: .first, now: now, frameT: frameT)
            return
        }
        // Unlocked read: the common case (the device holds ours) takes no lock.
        guard Self.sameValue(device.activeMaxExposureDuration, ours) else {
            // Someone else changed it (format change / capture restart): its value is the
            // device's own limit now; ours goes back on at a normal tick — no shorter than the
            // current light needs (the room may have changed during an interruption).
            clearSustain()
            guard normal else { return }
            let start = startLimit(device, expo: expo, ev: ev)
            let want = CMTimeCompare(start, ours) > 0 ? start : ours
            apply(device, want: want, kind: .reset, now: now, frameT: frameT)
            return
        }
        guard mode.isAdaptive, tracked, now - lastSetAt >= Self.settleSec,
              let limit = Self.seconds(ours) else {
            clearSustain()
            return
        }
        let maxISO = Double(device.activeFormat.maxISO)
        let diso = Self.deviceISO(device)
        var isoFrac: Double?
        if maxISO.isFinite, maxISO > 0 {
            if let diso {
                isoFrac = diso / maxISO
            } else if let iso = expo.iso {
                isoFrac = iso / maxISO
            }
        }
        guard let isoFrac, let ev else {
            // No signal: the loop is blind — after `noSignalSec` stop and put the device's own back.
            clearSustain()
            if let since = noSignalSince {
                if now - since >= Self.noSignalSec { giveUp("gaveUp:noSignal", now: now) }
            } else {
                noSignalSince = now
            }
            return
        }
        noSignalSince = nil
        // Dark rooms can drop tracking to `limited` — exactly when the limit must rise, so steps
        // run on any tracked, advancing frame (first set / resets still wait for normal).
        if isoFrac >= Self.starvedISOFrac, ev <= Self.starvedEV, limit < ceilS * (1 - Self.edgeBand) {
            brightSince = nil
            guard let since = starvedSince else {
                starvedSince = now
                starvedEVMax = ev
                return
            }
            starvedEVMax = max(starvedEVMax, ev)
            guard now - since >= Self.upSustainSec - Self.tickSlack else { return }
            let factor = min(max(pow(2, Self.upGain * -starvedEVMax), Self.upMinFactor), Self.upMaxFactor)
            var wantS = limit * factor
            if wantS >= ceilS * (1 - Self.edgeBand) { wantS = ceilS }
            apply(device, want: Self.time(wantS), kind: .up, now: now, frameT: frameT,
                  step: (iso: expo.iso, diso: diso, ev: ev, bv: expo.bv))
        } else if isoFrac < Self.brightISOFrac, limit > floorS * (1 + Self.edgeBand),
                  now - lastUpAt >= Self.reverseDwellSec {
            starvedSince = nil
            guard let since = brightSince else {
                brightSince = now
                brightISOMax = isoFrac
                return
            }
            brightISOMax = max(brightISOMax, isoFrac)
            guard now - since >= Self.downSustainSec - Self.tickSlack else { return }
            let factor = min(max(brightISOMax / Self.downTargetISOFrac, Self.downMinFactor), Self.downMaxFactor)
            var wantS = limit * factor
            if wantS <= floorS * (1 + Self.edgeBand) { wantS = floorS }
            apply(device, want: Self.time(wantS), kind: .down, now: now, frameT: frameT,
                  step: (iso: expo.iso, diso: diso, ev: ev, bv: expo.bv))
        } else {
            clearSustain()
        }
    }

    /// The first limit: the floor, or (adaptive, dim room) the one where the ISO would sit at
    /// `startISOFrac` of the max with the light the frame needed. Always a valid numeric CMTime
    /// ≥ the floor's ms; `apply` clamps it to the device's range.
    private func startLimit(_ device: AVCaptureDevice, expo: Exposure, ev: Double?) -> CMTime {
        let floor = Self.time(Double(capMs) / 1000)
        let maxISO = Double(device.activeFormat.maxISO)
        guard mode.isAdaptive, let expMs = expo.expMs, let iso = expo.iso, maxISO.isFinite, maxISO > 0 else {
            return floor
        }
        let offset = min(max(ev ?? 0, -3), 1)
        let wantS = expMs / 1000 * iso * pow(2, -offset) / (Self.startISOFrac * maxISO)
        guard wantS.isFinite, wantS > Double(capMs) / 1000 else { return floor }
        return Self.time(wantS)
    }

    private enum SetKind { case first, reset, up, down }

    /// Locks and puts `want` on the device, clamped under the lock to [floor, ceiling] inside the
    /// format's range, then reads it back. Gives up on the failures listed in the class comment.
    /// `step` = what decided an adaptive step (logged in `steps`).
    private func apply(
        _ device: AVCaptureDevice, want: CMTime, kind: SetKind, now: CFTimeInterval,
        frameT: TimeInterval, step: (iso: Double?, diso: Double?, ev: Double?, bv: Double?)? = nil
    ) {
        guard now >= nextLockAt else { return }
        let isSet = kind == .first || kind == .reset
        if isSet {
            recentSets.removeAll { now - $0 > Self.loopWindowSec }
            guard recentSets.count < Self.loopSets else {
                giveUp("gaveUp:resetLoop", now: now)
                return
            }
        }
        do {
            try device.lockForConfiguration()
        } catch {
            stats.lockFailures += 1
            lockFailuresInRow += 1
            nextLockAt = now + Self.lockRetrySec
            if ourValue == nil { stats.status = "lockFailed:\((error as NSError).code)" }
            if lockFailuresInRow >= Self.maxLockFailures {
                giveUp(ourValue == nil ? stats.status : "gaveUp:lockFailed", now: now)
            }
            return
        }
        lockFailuresInRow = 0
        defer { device.unlockForConfiguration() }
        // AE must be running for a limit to mean anything (ARKit runs continuous AE). Anything
        // else = someone else drives the exposure: leave it alone for the rest of the scan.
        let exposureMode = device.exposureMode
        guard exposureMode == .continuousAutoExposure || exposureMode == .autoExpose else {
            giveUp("notAutoExposure:\(exposureMode.rawValue)", now: now)
            return
        }
        // Again UNDER the lock: the range the setter checks is the one of this moment.
        let format = device.activeFormat
        guard let floor = Self.clampedCap(capMs, format) else {
            giveUp("badRange", now: now)
            return
        }
        let before = device.activeMaxExposureDuration
        let own: CMTime
        if isSet {
            own = before
        } else {
            // A reset between the unlocked check and the lock: the next tick handles it.
            guard let ours = ourValue, Self.sameValue(before, ours), let original else { return }
            own = original
        }
        guard let ceiling = Self.inRange(own, format) else {
            giveUp("badRange", now: now)
            return
        }
        guard !Self.atOrBelow(ceiling, floor) else {
            // The device's own limit is already this short: never raise it. Nothing of ours
            // is on the device (re-checked every normal tick, like 2.70.1).
            if isSet {
                original = nil
                ourValue = nil
                if kind == .reset { stats.resets += 1 }
                stats.status = "notNeeded"
                stats.deviceDefaultMs = Self.ms(before)
            }
            return
        }
        let safe = Self.clamp(want, lo: floor, hi: ceiling)
        if isSet {
            floorS = Self.seconds(floor) ?? 0
            ceilS = Self.seconds(ceiling) ?? 0
            stats.ceilingMs = Self.ms(ceiling)
            if kind == .first {
                stats.deviceDefaultMs = Self.ms(before)
                stats.formatMinMs = Self.ms(format.minExposureDuration)
                stats.formatMaxMs = Self.ms(format.maxExposureDuration)
                stats.clamped = abs((Self.ms(floor) ?? 0) - Double(capMs)) > 0.01
            } else {
                stats.resets += 1
            }
        }
        clearSustain()
        guard !Self.sameValue(before, safe) else {
            // Already there (e.g. a dim-room start at the device's own limit): nothing to set.
            if isSet {
                original = before
                adopt(before)
                if kind == .first {
                    stats.appliedMs = Self.ms(before)
                    stats.appliedAt = Self.fin(now - t0)
                    stats.status = "capped"
                }
            }
            return
        }
        device.activeMaxExposureDuration = safe
        lastSetAt = now
        lastSetFrameT = frameT
        let readBack = device.activeMaxExposureDuration
        let changed = !Self.sameValue(readBack, before)
        let ok = Self.near(readBack, safe)
        if isSet {
            recentSets.append(now)
            if stats.setAt.count < Self.maxSetTimes, let at = Self.fin(now - t0) {
                stats.setAt.append(at)
            }
            if kind == .first {
                stats.appliedMs = Self.ms(readBack)
                stats.appliedAt = Self.fin(now - t0)
            }
            guard changed else {
                // The device ignores the setter: nothing of ours is on it, nothing to restore.
                original = nil
                ourValue = nil
                giveUp(kind == .first ? "notApplied" : "gaveUp:notApplied", now: now)
                return
            }
            // The device's own value before THIS set: after a format change that is the new
            // format's default, which is what teardown must put back.
            original = before
            adopt(readBack)
            guard ok else {
                giveUp(kind == .first ? "notApplied" : "gaveUp:notApplied", now: now)
                return
            }
            if kind == .first { stats.status = "capped" }
        } else {
            // Whatever the device holds now is ours (teardown compares with it).
            adopt(readBack)
            if kind == .up {
                stats.stepsUp += 1
                lastUpAt = now
            } else {
                stats.stepsDown += 1
            }
            if stats.steps.count < Self.maxStepLog, let at = Self.fin(now - t0) {
                let logBV = stats.steps.count < Self.stepBVLogSteps
                stats.steps.append(StepPoint(
                    t: at, lim: Self.ms(readBack),
                    iso: step?.iso.flatMap { Self.fin($0) },
                    diso: step?.diso.flatMap { Self.fin($0) },
                    ev: step?.ev.flatMap { Self.fin($0) },
                    bv0: step?.bv.flatMap { Self.fin($0) },
                    bv: logBV ? [] : nil
                ))
                if logBV {
                    bvLogIndex = stats.steps.count - 1
                    bvLogUntil = now + Self.stepBVLogSec
                }
            }
            if !ok { giveUp("gaveUp:stepNotApplied", now: now) }
        }
    }

    /// The device now holds `value` as OURS (teardown restores only while it still does).
    private func adopt(_ value: CMTime) {
        ourValue = value
        if let v = Self.ms(value) { stats.limMsMax = Self.fin(max(stats.limMsMax ?? 0, v)) }
    }

    private func clearSustain() {
        starvedSince = nil
        brightSince = nil
    }

    /// No frame / the same frame again (paused, interrupted): every window starts over.
    private func pauseReset() {
        clearSustain()
        noSignalSince = nil
    }

    /// Records the give-up; the device's own limit goes back on the next tick (outside any lock)
    /// via `restoreAfterGiveUp`.
    private func giveUp(_ status: String, now: CFTimeInterval) {
        gaveUp = true
        clearSustain()
        stats.status = status
        stats.gaveUpAt = Self.fin(now - t0)
    }

    /// After a give-up: put the device's own limit back while ours is on it (review R1: a short
    /// limit left behind keeps a dark room dark for the rest of the scan). Lock busy = retried
    /// every `lockRetrySec`, and teardown tries again anyway.
    private func restoreAfterGiveUp(now: CFTimeInterval) {
        guard let device, let original, let ours = ourValue, now >= nextLockAt else { return }
        if Self.sameValue(original, ours) || Self.restore(device, original: original, ours: ours) {
            self.original = nil
            ourValue = nil
            stats.restored = true
        } else {
            nextLockAt = now + Self.lockRetrySec
        }
    }

    /// Puts `original` back if the device still holds `ours` (else ARKit already set its own
    /// default — leave it). true = done or nothing to do; false = lock failed.
    @discardableResult
    private static func restore(_ device: AVCaptureDevice, original: CMTime, ours: CMTime) -> Bool {
        guard sameValue(device.activeMaxExposureDuration, ours) else { return true }
        do {
            try device.lockForConfiguration()
        } catch {
            return false
        }
        defer { device.unlockForConfiguration() }
        guard sameValue(device.activeMaxExposureDuration, ours) else { return true }
        let format = device.activeFormat
        let lo = format.minExposureDuration
        let hi = format.maxExposureDuration
        if seconds(original) != nil, seconds(lo) != nil, seconds(hi) != nil,
           CMTimeCompare(original, lo) >= 0, CMTimeCompare(original, hi) <= 0 {
            device.activeMaxExposureDuration = original
        } else {
            // Documented reset: kCMTimeInvalid = the device's default for its configuration.
            device.activeMaxExposureDuration = .invalid
        }
        return true
    }

    // MARK: - Helpers

    /// The mode's ms as a CMTime inside the format's exposure range; nil = unusable range.
    private static func clampedCap(_ capMs: Int, _ format: AVCaptureDevice.Format) -> CMTime? {
        let lo = format.minExposureDuration
        let hi = format.maxExposureDuration
        guard seconds(lo) != nil, seconds(hi) != nil, CMTimeCompare(lo, hi) <= 0 else { return nil }
        let want = CMTime(value: CMTimeValue(capMs) * 1000, timescale: 1_000_000)
        if CMTimeCompare(want, lo) <= 0 { return lo }
        if CMTimeCompare(want, hi) >= 0 { return hi }
        return want
    }

    /// `t` clamped to the format's exposure range; nil = unusable range or non-numeric `t`.
    private static func inRange(_ t: CMTime, _ format: AVCaptureDevice.Format) -> CMTime? {
        let lo = format.minExposureDuration
        let hi = format.maxExposureDuration
        guard seconds(t) != nil, seconds(lo) != nil, seconds(hi) != nil, CMTimeCompare(lo, hi) <= 0 else {
            return nil
        }
        return clamp(t, lo: lo, hi: hi)
    }

    /// `t` within lo…hi (exact CMTime comparison; lo ≤ hi, both numeric — callers check);
    /// non-numeric `t` = lo.
    private static func clamp(_ t: CMTime, lo: CMTime, hi: CMTime) -> CMTime {
        guard seconds(t) != nil else { return lo }
        if CMTimeCompare(t, lo) <= 0 { return lo }
        if CMTimeCompare(t, hi) >= 0 { return hi }
        return t
    }

    /// Seconds → CMTime at 1 µs (non-finite / ≤ 0 → .invalid, which `clamp` turns into the floor).
    private static func time(_ s: Double) -> CMTime {
        guard s.isFinite, s > 0 else { return .invalid }
        return CMTime(seconds: s, preferredTimescale: 1_000_000)
    }

    /// `current` is at or below `limit` (+2 % / 20 µs for the device's own rounding).
    private static func atOrBelow(_ current: CMTime, _ limit: CMTime) -> Bool {
        guard let c = seconds(current), let l = seconds(limit) else { return false }
        return c <= l * 1.02 + 0.00002
    }

    private static func sameValue(_ a: CMTime, _ b: CMTime) -> Bool {
        guard let x = seconds(a), let y = seconds(b) else { return false }
        return abs(x - y) <= max(x, y) * 0.02 + 0.00002
    }

    /// Read-back within want ÷/× `appliedTolerance` (+20 µs).
    private static func near(_ readBack: CMTime, _ want: CMTime) -> Bool {
        guard let rb = seconds(readBack), let w = seconds(want) else { return false }
        return rb <= w * appliedTolerance + 0.00002 && rb >= w / appliedTolerance - 0.00002
    }

    /// Finite positive seconds of a numeric CMTime, else nil.
    private static func seconds(_ t: CMTime) -> Double? {
        guard t.isValid, t.isNumeric else { return nil }
        let s = CMTimeGetSeconds(t)
        return s.isFinite && s > 0 ? s : nil
    }

    static func ms(_ t: CMTime) -> Double? {
        seconds(t).flatMap { fin($0 * 1000) }
    }

    /// The device's current ISO (unrounded, activeFormat scale), finite and > 0, else nil.
    private static func deviceISO(_ device: AVCaptureDevice) -> Double? {
        let iso = Double(device.iso)
        return iso.isFinite && iso > 0 ? fin(iso) : nil
    }

    /// shots.json `expMaxMs`: the device's AE limit when the frame is copied (ms); nil = no device
    /// or no numeric limit.
    static func limitMsForShot(_ device: AVCaptureDevice?) -> Float? {
        guard let device, let v = ms(device.activeMaxExposureDuration) else { return nil }
        let f = Float(v)
        return f.isFinite ? f : nil
    }

    /// Rounded to 3 decimals; non-finite → nil.
    private static func fin(_ x: Double) -> Double? {
        guard x.isFinite else { return nil }
        return (x * 1000).rounded() / 1000
    }

    /// Exposure time (ms), ISO and BrightnessValue from ARFrame.exifData (top level or nested
    /// {Exif}); nil = missing / non-finite.
    private static func exifExposure(_ frame: ARFrame) -> Exposure {
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
        var expMs: Double?
        if let e = number(kCGImagePropertyExifExposureTime), e > 0 { expMs = e * 1000 }
        var iso: Double?
        if let i = number(kCGImagePropertyExifISOSpeedRatings), i > 0 { iso = i }
        return (expMs, iso, number(kCGImagePropertyExifBrightnessValue))
    }

    private func publishDebug(_ expo: Exposure, ev: Double?, limitMs: Double?) {
        var s: String
        switch mode {
        case .off: s = stats.source == "server" ? "cap off(srv)" : "cap off"
        case .adaptive4: s = "adp \(capMs)-" + String(format: "%.1f", ceilS * 1000)
        case .hard4, .hard6, .hard8: s = "hard \(capMs)"
        }
        let diso = readDevice.flatMap { Self.deviceISO($0) }
        s += String(format: " lim %.1f · exp %.1f iso %.0f/%.0f ev %.2f bv %.1f",
                    limitMs ?? -1, expo.expMs ?? -1, expo.iso ?? -1, diso ?? -1, ev ?? -99, expo.bv ?? -99)
        s += " · up\(stats.stepsUp) dn\(stats.stepsDown) rs\(stats.resets)"
        s += " over \(stats.framesOverCap)/\(stats.framesSampled) \(stats.status)"
        debugLine = s
    }
}
