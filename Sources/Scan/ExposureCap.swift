import Foundation
import ARKit
import AVFoundation
import Combine
import CoreMedia
import ImageIO
import QuartzCore

/// 🧪 TEST-ONLY EXPOSURE CAP (owner 30/09 "ok làm bản thử (2)"; branch `claude/exposure-cap-test`,
/// app 2.70.1). ✗ main, ✗ customers. `testBuild` is the compile-time switch: false = not one
/// device call, no Account row, no report / shots.json key — the app behaves exactly like 2.70.
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
///    after an interruption) → set again, counted (`resets`), at most `maxSets` per scan;
///  - the setter RAISES (ObjC exception = crash, not a throw) outside activeFormat's
///    min…maxExposureDuration and without the configuration lock: the value is clamped to the
///    range read under the lock; an unusable range = give up;
///  - never RAISES the limit (a longer exposure than the device's own = more blur than without
///    the test): device limit already ≤ cap → nothing set ("notNeeded");
///  - only while AE runs (continuous/auto): a locked/custom exposure mode ignores the limit;
///  - restored at teardown (both exits, BEFORE arSession.pause — the device outlives the session)
///    to the value it had before our first set, only if the device still holds OUR value (ARKit
///    may already have put its own default back); a failed restore is retried once 0.5 s later
///    and then at the next scan's start (`stale`).
///  - Kill switch = the Account selector (Off, 7 taps on the version line first): Off never sets
///    anything (it still shows exp/iso in the debug readout and records `expMaxMs`).
///
/// What to expect (the owner's test):
///  - Banding under mains-flickering light (tubes, cheap LED drivers): a 50 Hz supply flickers at
///    100 Hz (10 ms), 60 Hz at 120 Hz (8.3 ms); only an exposure of whole flicker periods averages
///    it out, which is why ARKit's AE sits on 10 ms steps. 4 ms cannot → rows of the rolling
///    shutter see different light → bands in the live view, photos and video. 6 / 8 ms: weaker
///    bands (closer to one period), less blur gain.
///  - Dim rooms: AE runs out of ISO (3200 on the 12 Pro) sooner — ~1.3 stops sooner than at 10 ms,
///    ~2 stops sooner than at 16.4 ms — so frames between BV ≈ −2 and the torch thresholds are
///    darker and noisier than today; ARKit tracks on these frames (test in a dark room).
///  - Auto torch: its signal is EXIF BrightnessValue = APEX scene luminance (Av + Tv − Sv + the
///    metered offset). A shorter exposure with a higher ISO leaves it where it was, and past the
///    ISO limit it keeps following the scene (2.61/2.63 scans: BV fell to −7 in pitch black long
///    after AE had run out). So the cap should not move BV and the torch decides at the same scene
///    brightness. UNMEASURED on a capped device → compare per-shot bv with exp/iso on test orders.
///  - "Turn on lights" coach (ambientIntensity < 250, only when the torch cannot help): that value
///    falls when AE runs out, which now happens sooner → the coach may show in brighter rooms when
///    the auto torch is off / unavailable.
///  - scan-report.json: `exposureCapMs` (the setting, 0 = off) + `exposureCap` (status, figures);
///    shots.json per shot: `expMaxMs` (the device's AE limit in force at capture). exp / iso / bv /
///    blurPx per shot as in 2.70.
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

    /// scan-report.json `exposureCap`. Doubles are rounded and finite (JSONEncoder rule).
    struct Stats: Encodable {
        /// off | noDevice | unsupported | pending | capped | notNeeded | notAutoExposure:<mode>
        /// | lockFailed:<code> | badRange | gaveUp
        var status = "notStarted"
        var capMs = 0
        /// Device limit read back after our (first) set, ms.
        var appliedMs: Double?
        /// Seconds after scan start of the first set.
        var appliedAt: Double?
        /// Device limit before our first set = ARKit's default, ms.
        var deviceDefaultMs: Double?
        var formatMinMs: Double?
        var formatMaxMs: Double?
        /// The cap was outside the format range and got clamped.
        var clamped = false
        /// Times the device limit was found above the cap again (format change / capture restart)
        /// and set again.
        var resets = 0
        var lockFailures = 0
        /// Frames sampled at 2 Hz while the cap is in force and tracking normal…
        var framesSampled = 0
        /// …whose EXIF exposure time was above the cap (+10 % + 0.1 ms) = the limit NOT honoured.
        var framesOverCap = 0
        var expMsMax: Double?
        /// Teardown: true = the old limit is back (or the device already held its own again),
        /// false = restore failed (retried later), nil = nothing to restore.
        var restored: Bool?
    }
    private(set) var stats = Stats()

    static let applyDelaySec: CFTimeInterval = 1.0
    private static let tickSec: TimeInterval = 0.5
    /// Sets per scan (first + resets). A device that resets the limit every second for a minute
    /// is fighting us — stop.
    private static let maxSets = 120
    private static let maxLockFailures = 10

    private weak var arSession: ARSession?
    /// The device we cap; nil = cap off / unsupported / no device.
    private var device: AVCaptureDevice?
    /// ARKit's primary camera, only READ (debug readout shows its limit even with the cap off).
    private var readDevice: AVCaptureDevice?
    private var timer: Timer?
    private var t0: CFTimeInterval = 0
    private var capMs = 0
    private var dueAt: CFTimeInterval = .greatestFiniteMagnitude
    private var debug = false
    private var stopped = false
    private var gaveUp = false
    private var sets = 0
    /// AE needs a few frames to follow a new limit: no honoured-sample right after a set.
    private var lastSetAt: CFTimeInterval = -.greatestFiniteMagnitude
    private var lastFrameT: TimeInterval = -1
    /// Device limit before our first set (restored at teardown) and the value we set last.
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
        if let s = Self.stale, Self.restore(s.device, original: s.original, ours: s.ours) {
            Self.stale = nil
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
        // Nothing to enforce and nothing to show → no timer at all.
        guard device != nil || debug else { return }
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
        // Lock busy right now: one more try shortly, then at the next scan's start.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let s = Self.stale else { return }
            if Self.restore(s.device, original: s.original, ours: s.ours) { Self.stale = nil }
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
        if ready, now >= dueAt, !gaveUp, let device {
            enforce(device, now: now)
        }
        let expo = Self.exifExposure(frame)
        // Honoured? Only while the device holds OUR limit and AE had time to follow it.
        if ready, let device, let ours = ourValue, now - lastSetAt >= 0.5,
           Self.atOrBelow(device.activeMaxExposureDuration, ours),
           let expMs = expo.expMs, let limit = Self.ms(ours) {
            stats.framesSampled += 1
            if expMs > limit * 1.1 + 0.1 { stats.framesOverCap += 1 }
            stats.expMsMax = Self.fin(max(stats.expMsMax ?? 0, expMs))
        }
        if debug { publishDebug(expo) }
    }

    /// Sets the limit when the device's is above the cap (first time or after a reset).
    private func enforce(_ device: AVCaptureDevice, now: CFTimeInterval) {
        // Unlocked reads first: the common case (limit already ours) takes no lock.
        guard let want = Self.clampedCap(capMs, device.activeFormat) else {
            giveUp("badRange")
            return
        }
        let current = device.activeMaxExposureDuration
        if Self.atOrBelow(current, want) {
            if ourValue == nil, stats.status == "pending" {
                // The device's own limit is already this short: never raise it.
                stats.status = "notNeeded"
                stats.deviceDefaultMs = Self.ms(current)
            }
            return
        }
        guard sets < Self.maxSets else {
            giveUp("gaveUp")
            return
        }
        do {
            try device.lockForConfiguration()
        } catch {
            stats.lockFailures += 1
            if ourValue == nil { stats.status = "lockFailed:\((error as NSError).code)" }
            if stats.lockFailures >= Self.maxLockFailures { giveUp(stats.status) }
            return
        }
        defer { device.unlockForConfiguration() }
        // AE must be running for a limit to mean anything (ARKit runs continuous AE). Anything
        // else = someone else drives the exposure: leave it alone for the rest of the scan.
        let mode = device.exposureMode
        guard mode == .continuousAutoExposure || mode == .autoExpose else {
            giveUp("notAutoExposure:\(mode.rawValue)")
            return
        }
        // Again UNDER the lock: the range the setter checks is the one of this moment.
        let format = device.activeFormat
        guard let safe = Self.clampedCap(capMs, format) else {
            giveUp("badRange")
            return
        }
        let before = device.activeMaxExposureDuration
        guard !Self.atOrBelow(before, safe) else { return }
        device.activeMaxExposureDuration = safe
        sets += 1
        lastSetAt = now
        if ourValue == nil {
            original = before
            stats.deviceDefaultMs = Self.ms(before)
            stats.formatMinMs = Self.ms(format.minExposureDuration)
            stats.formatMaxMs = Self.ms(format.maxExposureDuration)
            stats.clamped = abs((Self.ms(safe) ?? 0) - Double(capMs)) > 0.01
            stats.appliedMs = Self.ms(device.activeMaxExposureDuration)
            stats.appliedAt = Self.fin(now - t0)
            stats.status = "capped"
        } else {
            stats.resets += 1
        }
        ourValue = safe
    }

    private func giveUp(_ status: String) {
        gaveUp = true
        stats.status = status
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

    /// Exposure time (ms) and ISO from ARFrame.exifData (top level or nested {Exif}).
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

    private func publishDebug(_ expo: (expMs: Double?, iso: Double?, bv: Double?)) {
        let limit = readDevice.flatMap { Self.ms($0.activeMaxExposureDuration) }
        var s = capMs > 0 ? "cap \(capMs)" : "cap off"
        s += String(format: " lim %.1f · exp %.1f iso %.0f bv %.1f",
                    limit ?? -1, expo.expMs ?? -1, expo.iso ?? -1, expo.bv ?? -99)
        s += " · rs\(stats.resets) over \(stats.framesOverCap)/\(stats.framesSampled) \(stats.status)"
        debugLine = s
    }
}
