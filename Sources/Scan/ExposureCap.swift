import Foundation
import ARKit
import AVFoundation
import Combine
import CoreMedia
import ImageIO
import QuartzCore

/// 🧪 TEST-ONLY EXPOSURE CAP (owner 30/09 "ok làm bản thử (2)"; branch `claude/exposure-cap-test`,
/// app 2.70.1). ✗ main, ✗ customers. `testBuild` is the compile-time switch: false = not one
/// device call, no Timer, no Account row, no report / shots.json key — the app behaves exactly
/// like 2.70.
///
/// WHY: texture photos are motion-blurred. ARKit's auto-exposure never goes below 10 ms (the 50 Hz
/// anti-flicker step) / 16.4 ms, even in bright rooms, and the phone turns ~31°/s at shot time even
/// in a slow scan → median predicted blur ~7 px. 2.70's choice window + JPEG 0.8 did not visibly
/// help (SESSION-HANDOFF 30/09 "2.70 MEASURED"). Capped at ~4 ms: est. ~7 → ~3 px.
///
/// HOW: auto-exposure stays ON; only its upper limit (`activeMaxExposureDuration`) is lowered on
/// ARKit's own capture device (`configurableCaptureDeviceForPrimaryCamera`, the one 2.54 locks the
/// white balance on), so AE raises the ISO instead of lengthening the shutter. Same pattern and
/// defences as that WB lock (MeshScanController):
///  - set `applyDelaySec` after start, at a tick where tracking is normal and frames advance
///    (paused / interrupted = the same frame again): ARKit configures the device when its capture
///    session starts, and a format change resets the limit to the default;
///  - re-checked every tick (0.5 s): a device limit above ours (format change, capture restart
///    after an interruption) → set again (`resets`, times in `setAt`); ≥ `loopSets` sets within
///    `loopWindowSec` = something keeps undoing it → give up (each set is an exposure step);
///  - the setter RAISES (ObjC exception = crash, not a throw) outside activeFormat's
///    min…maxExposureDuration and without the configuration lock: the value is clamped to the
///    range read under the lock; an unusable range = give up;
///  - `ourValue` = what the device READS BACK after the set (it may round); a read-back far above
///    the cap = the setter is ignored → give up ("notApplied");
///  - never RAISES the limit (a longer exposure than the device's own = more blur than without
///    the test): device limit already ≤ cap → nothing set ("notNeeded");
///  - only while AE runs (continuous/auto): a locked/custom exposure mode ignores the limit;
///  - restored at teardown (both exits, BEFORE arSession.pause — the device outlives the session)
///    to the device's own value before our LAST set, only if the device still holds OUR value
///    (ARKit may already have put its own default back); a failed restore is retried 0.5 s later
///    and then at the next scan's start (`stale`; still stuck there = `staleAtStart`).
///  - Kill switch = the Account selector (Off, 7 taps on the version line first): Off never sets
///    anything (it still traces exp/iso/bv, shows the debug readout and records `expMaxMs`, so an
///    Off scan is the A/B baseline).
///
/// What to expect (the owner's test; review R1 corrected the numbers):
///  - Banding under mains-flickering light (tubes, cheap LED drivers): a 50 Hz supply flickers at
///    100 Hz (10 ms), 60 Hz at 120 Hz (8.3 ms); only an exposure of whole flicker periods averages
///    it out, which is why ARKit's AE sits on 10 ms steps. 4 ms cannot → rows of the rolling
///    shutter see different light → bands in the live view, photos and video (and a brightness
///    ripple under ARKit's feature tracking). 6 / 8 ms: weaker bands, less blur gain.
///  - Darker frames from BV ≈ −0.7 down: at f/1.6 and ISO 3200 (12 Pro) AE runs out of ISO at
///    BV ≈ −0.7 at 4 ms (−1.3 at 6, −1.7 at 8, −2.0 at 10, −2.7 at 16.4 ms). Below that every frame
///    gets up to 2 stops (4 ms vs 16.4) fewer photons than today → darker, noisier; a lit room at
///    BV 0 already runs ~ISO 2000 (bigger JPEGs).
///  - 🔴 TRACKING RISK in dim rooms: the auto torch keeps its BV thresholds (−2.5 after 2 s,
///    −4.5 at once), tuned on uncapped frames — "ARKit tracked fine at BV −3…−4.25" was measured
///    WITHOUT a cap. Under a 4 ms cap a BV −4.4 room gives the tracker what BV −6.4 gave before
///    (the BV −7 stretch of #LS-MUJNJUQ56 drifted ~20 cm unflagged) while the torch waits 2 s.
///    Deliberately NO guard in this build (review R1 verdict: it would hide what the dark-room test
///    measures, and a guard keyed on ISO headroom oscillates); a product version needs a guard
///    keyed on BV with hysteresis around the cap's run-out BV. Owner: dark-room test (Off vs 4 ms)
///    BEFORE a real order at 4 ms.
///  - Auto torch signal: EXIF BrightnessValue is computed from what the sensor MEASURES (old data:
///    with exp/ISO pinned at 16.4 ms / 3200, BV still ran −2.9…−7 and followed ARKit's
///    exposureOffset one-for-one), so the cap should not move BV — the torch decides at the same
///    SCENE brightness (see the risk above for what that means for the image). Untested edge:
///    pitch black at 4 ms needs ~2 stops deeper metering than ever seen; if metering bottoms out,
///    pitch black could read above −4.5 and the torch would wait for the 2 s tier. `trace` below
///    (1 Hz bv / exp / iso / ev) answers it.
///  - "Turn on lights" coach (ambientIntensity < 250, only when the torch cannot help): that value
///    falls when AE runs out, now ~2 stops sooner → it shows in brighter rooms when the auto torch
///    is off / unavailable.
///  - scan-report.json: `exposureCapMs` (the setting, 0 = off) + `exposureCap` (status, limits,
///    set times, frames sampled / over the cap / at the cap / at max ISO, 1 Hz trace); shots.json
///    per shot: `expMaxMs` (the device's AE limit in force at capture). exp / iso / bv / blurPx per
///    shot as in 2.70.
///
/// MAIN THREAD ONLY (own Timer on main, like the other scan loops). Reads `arSession.currentFrame`,
/// never takes the session delegate.
final class ExposureCap: ObservableObject {
    /// 🔴 Compile-time switch. true ONLY on the test branch; false everywhere else.
    static let testBuild = true
    /// UserDefaults key of the Account selector (Int ms, 0 = off).
    static let settingKey = "scanExposureCapMs"
    static let choices = [0, 4, 6, 8]
    /// Default of this test build (owner: 4 ms first; 6 / 8 if banding shows).
    static let defaultMs = 4

    /// The selected cap in ms (0 = off); always 0 outside the test build. Read at scan start.
    static var settingMs: Int {
        guard testBuild else { return 0 }
        guard let v = UserDefaults.standard.object(forKey: settingKey) as? Int, choices.contains(v) else {
            return defaultMs
        }
        return v
    }

    /// Debug readout (only with the hidden debug flag): cap, device limit, exp/iso of the frame.
    @Published private(set) var debugLine: String?

    /// One 1 Hz sample (seconds since scan start; raw EXIF bv, exposure ms, ISO; ARKit
    /// exposureOffset; the device limit in ms). Absent keys = not available.
    struct TracePoint: Encodable {
        let t: Double
        let bv: Double?
        let exp: Double?
        let iso: Double?
        let ev: Double?
        let lim: Double?
    }

    /// scan-report.json `exposureCap`. Doubles are rounded and finite (JSONEncoder rule).
    struct Stats: Encodable {
        /// notStarted | off | noDevice | unsupported | pending | capped | notNeeded | notApplied
        /// | notAutoExposure:<mode> | lockFailed:<code> | badRange | gaveUp:lockFailed
        /// | gaveUp:resetLoop
        var status = "notStarted"
        var capMs = 0
        /// Device limit read back after our first set, ms.
        var appliedMs: Double?
        /// Seconds after scan start of the first set.
        var appliedAt: Double?
        /// Seconds after scan start of every set (first + resets), ≤ `maxSetTimes`.
        var setAt: [Double] = []
        /// Seconds after scan start of a give-up.
        var gaveUpAt: Double?
        /// Device limit before our first set = ARKit's default, ms.
        var deviceDefaultMs: Double?
        var formatMinMs: Double?
        var formatMaxMs: Double?
        var formatMaxISO: Double?
        /// The cap was outside the format range and got clamped.
        var clamped = false
        /// Times the device limit was found above the cap again (format change / capture restart)
        /// and set again.
        var resets = 0
        var lockFailures = 0
        /// A limit left by an earlier scan (failed restore) was still on the device at start —
        /// this scan's numbers may not be what the setting says (per-shot `expMaxMs` tells).
        var staleAtStart = false
        /// Frames sampled at 2 Hz while the cap is in force and tracking normal…
        var framesSampled = 0
        /// …whose EXIF exposure time was above the cap (+10 % + 0.1 ms) = the limit NOT honoured;
        var framesOverCap = 0
        /// …at ≥ 0.8 × the cap = the cap was actually binding (a bright room never reaches it);
        var framesAtCap = 0
        /// …at ≥ 0.95 × the format's max ISO = AE had run out (darker than uncapped).
        var framesIsoMax = 0
        var expMsMax: Double?
        /// Teardown: true = the old limit is back (or the device already held its own again),
        /// false = restore failed (retried later), nil = nothing to restore.
        var restored: Bool?
        /// 1 Hz, whole scan (also with the cap Off = the A/B baseline), ≤ `traceMax` points.
        var trace: [TracePoint] = []
    }
    private(set) var stats = Stats()

    static let applyDelaySec: CFTimeInterval = 1.0
    private static let tickSec: TimeInterval = 0.5
    /// ≥ this many sets within `loopWindowSec` = a reset loop: give up.
    private static let loopSets = 10
    private static let loopWindowSec: CFTimeInterval = 30
    private static let maxSetTimes = 100
    private static let maxLockFailures = 10
    private static let traceMax = 3600
    /// A read-back above cap × this = the setter did not take.
    private static let appliedTolerance = 1.25

    private weak var arSession: ARSession?
    /// The device we cap; nil = cap off / unsupported / no device.
    private var device: AVCaptureDevice?
    /// ARKit's primary camera, only READ (trace / readout show its limit even with the cap off).
    private var readDevice: AVCaptureDevice?
    private var timer: Timer?
    private var t0: CFTimeInterval = 0
    private var capMs = 0
    private var dueAt: CFTimeInterval = .greatestFiniteMagnitude
    private var debug = false
    private var stopped = false
    private var gaveUp = false
    private var recentSets: [CFTimeInterval] = []
    /// AE needs a few frames to follow a new limit: no honoured-sample right after a set.
    private var lastSetAt: CFTimeInterval = -.greatestFiniteMagnitude
    private var lastTraceAt: CFTimeInterval = -.greatestFiniteMagnitude
    private var lastFrameT: TimeInterval = -1
    /// Device's own limit before our last set (restored at teardown) and the value the device
    /// read back after it.
    private var original: CMTime?
    private var ourValue: CMTime?

    /// A restore that failed at the end of an earlier scan (lock busy): retried at the next start.
    private static var stale: (device: AVCaptureDevice, original: CMTime, ours: CMTime)?

    // MARK: - Lifecycle (main)

    /// Scan start, right after `arSession.run` (MeshScanController.startSession).
    func start(device primary: AVCaptureDevice?, arSession session: ARSession) {
        guard Self.testBuild, t0 == 0 else { return }
        t0 = CACurrentMediaTime()
        arSession = session
        readDevice = primary
        debug = UserDefaults.standard.bool(forKey: "scanDebugReadout")
        if let s = Self.stale {
            if Self.restore(s.device, original: s.original, ours: s.ours) {
                Self.stale = nil
            } else {
                stats.staleAtStart = true
            }
        }
        capMs = Self.settingMs
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
        // Always in the test build (cheap, 2 Hz): the trace of an Off scan is the A/B baseline.
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
        if debugLine != nil { debugLine = nil }
        if let device, let original, let ourValue {
            self.original = nil
            self.ourValue = nil
            if Self.restore(device, original: original, ours: ourValue) {
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
        if let device, let original, let ourValue {
            _ = Self.restore(device, original: original, ours: ourValue)
        }
    }

    // MARK: - Loop (main, 2 Hz)

    private func tick() {
        guard !stopped, let frame = arSession?.currentFrame else { return }
        let t = frame.timestamp
        // Paused / interrupted = the same frame again: no set, no sample.
        let advancing = t != lastFrameT
        lastFrameT = t
        var normal = false
        if case .normal = frame.camera.trackingState { normal = true }
        let ready = advancing && normal
        let now = CACurrentMediaTime()
        // Read once ARKit's format is surely in place (right after `run` it may not be yet).
        if ready, stats.formatMaxISO == nil, let readDevice {
            stats.formatMaxISO = Self.fin(Double(readDevice.activeFormat.maxISO))
        }
        if ready, now >= dueAt, !gaveUp, let device {
            enforce(device, now: now)
        }
        let expo = Self.exifExposure(frame)
        let limitMs = readDevice.flatMap { Self.ms($0.activeMaxExposureDuration) }
        // Honoured? Only while the device holds OUR limit and AE had time to follow it.
        if ready, let device, let ours = ourValue, now - lastSetAt >= 0.5,
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
        if advancing, now - lastTraceAt >= 0.95, stats.trace.count < Self.traceMax {
            lastTraceAt = now
            let ev = Double(frame.camera.exposureOffset)
            stats.trace.append(TracePoint(
                t: Self.fin(now - t0) ?? 0,
                bv: expo.bv.flatMap { Self.fin($0) },
                exp: expo.expMs.flatMap { Self.fin($0) },
                iso: expo.iso.flatMap { Self.fin($0) },
                ev: Self.fin(ev),
                lim: limitMs
            ))
        }
        if debug { publishDebug(expo, limitMs: limitMs) }
    }

    /// Sets the limit when the device's is above the cap (first time or after a reset).
    private func enforce(_ device: AVCaptureDevice, now: CFTimeInterval) {
        // Unlocked reads first: the common case (limit already ours) takes no lock.
        guard let want = Self.clampedCap(capMs, device.activeFormat) else {
            giveUp("badRange", now: now)
            return
        }
        let current = device.activeMaxExposureDuration
        if Self.atOrBelow(current, ourValue ?? want) {
            if ourValue == nil, stats.status == "pending" {
                // The device's own limit is already this short: never raise it.
                stats.status = "notNeeded"
                stats.deviceDefaultMs = Self.ms(current)
            }
            return
        }
        recentSets.removeAll { now - $0 > Self.loopWindowSec }
        guard recentSets.count < Self.loopSets else {
            giveUp("gaveUp:resetLoop", now: now)
            return
        }
        do {
            try device.lockForConfiguration()
        } catch {
            stats.lockFailures += 1
            if ourValue == nil { stats.status = "lockFailed:\((error as NSError).code)" }
            if stats.lockFailures >= Self.maxLockFailures {
                giveUp(ourValue == nil ? stats.status : "gaveUp:lockFailed", now: now)
            }
            return
        }
        defer { device.unlockForConfiguration() }
        // AE must be running for a limit to mean anything (ARKit runs continuous AE). Anything
        // else = someone else drives the exposure: leave it alone for the rest of the scan.
        let mode = device.exposureMode
        guard mode == .continuousAutoExposure || mode == .autoExpose else {
            giveUp("notAutoExposure:\(mode.rawValue)", now: now)
            return
        }
        // Again UNDER the lock: the range the setter checks is the one of this moment.
        let format = device.activeFormat
        guard let safe = Self.clampedCap(capMs, format) else {
            giveUp("badRange", now: now)
            return
        }
        let before = device.activeMaxExposureDuration
        guard !Self.atOrBelow(before, ourValue ?? safe) else { return }
        device.activeMaxExposureDuration = safe
        recentSets.append(now)
        lastSetAt = now
        if stats.setAt.count < Self.maxSetTimes, let at = Self.fin(now - t0) {
            stats.setAt.append(at)
        }
        let readBack = device.activeMaxExposureDuration
        let first = ourValue == nil
        if first {
            stats.deviceDefaultMs = Self.ms(before)
            stats.formatMinMs = Self.ms(format.minExposureDuration)
            stats.formatMaxMs = Self.ms(format.maxExposureDuration)
            stats.clamped = abs((Self.ms(safe) ?? 0) - Double(capMs)) > 0.01
            stats.appliedMs = Self.ms(readBack)
            stats.appliedAt = Self.fin(now - t0)
        } else {
            stats.resets += 1
        }
        // Did it take? A read-back far above the cap = the device ignores the setter: nothing of
        // ours is on it, nothing to restore.
        guard let rb = Self.seconds(readBack), let sf = Self.seconds(safe),
              rb <= sf * Self.appliedTolerance + 0.00002 else {
            if first {
                giveUp("notApplied", now: now)
            } else {
                // The reset did not take: our value is gone from the device either way.
                original = nil
                ourValue = nil
                giveUp("gaveUp:notApplied", now: now)
            }
            return
        }
        // The device's own value before THIS set: after a format change that is the new
        // format's default, which is what teardown must put back.
        original = before
        ourValue = readBack
        if first { stats.status = "capped" }
    }

    private func giveUp(_ status: String, now: CFTimeInterval) {
        gaveUp = true
        stats.status = status
        stats.gaveUpAt = Self.fin(now - t0)
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
        if let o = seconds(original), let lo = seconds(format.minExposureDuration),
           let hi = seconds(format.maxExposureDuration), o >= lo, o <= hi {
            device.activeMaxExposureDuration = original
        } else {
            // Documented reset: kCMTimeInvalid = the device's default for its configuration.
            device.activeMaxExposureDuration = .invalid
        }
        return true
    }

    // MARK: - Helpers

    /// The cap as a CMTime inside the format's exposure range; nil = unusable range.
    private static func clampedCap(_ capMs: Int, _ format: AVCaptureDevice.Format) -> CMTime? {
        let lo = format.minExposureDuration
        let hi = format.maxExposureDuration
        guard let loS = seconds(lo), let hiS = seconds(hi), loS > 0, loS <= hiS else { return nil }
        let wantS = Double(capMs) / 1000
        if wantS <= loS { return lo }
        if wantS >= hiS { return hi }
        return CMTime(value: CMTimeValue(capMs) * 1000, timescale: 1_000_000)
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

    /// Finite positive seconds of a numeric CMTime, else nil.
    private static func seconds(_ t: CMTime) -> Double? {
        guard t.isValid, t.isNumeric else { return nil }
        let s = CMTimeGetSeconds(t)
        return s.isFinite && s > 0 ? s : nil
    }

    static func ms(_ t: CMTime) -> Double? {
        seconds(t).flatMap { fin($0 * 1000) }
    }

    /// shots.json `expMaxMs`: the device's AE limit at capture (ms); nil outside the test build.
    static func limitMsForShot(_ device: AVCaptureDevice?) -> Float? {
        guard testBuild, let device, let v = ms(device.activeMaxExposureDuration) else { return nil }
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
    private static func exifExposure(_ frame: ARFrame) -> (expMs: Double?, iso: Double?, bv: Double?) {
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

    private func publishDebug(_ expo: (expMs: Double?, iso: Double?, bv: Double?), limitMs: Double?) {
        var s = capMs > 0 ? "cap \(capMs)" : "cap off"
        s += String(format: " lim %.1f · exp %.1f iso %.0f bv %.1f",
                    limitMs ?? -1, expo.expMs ?? -1, expo.iso ?? -1, expo.bv ?? -99)
        s += " · rs\(stats.resets) over \(stats.framesOverCap)/\(stats.framesSampled) \(stats.status)"
        debugLine = s
    }
}
