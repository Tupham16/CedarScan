import Foundation
import ARKit
import UIKit

/// `scan-report.json` — small per-scan diagnostics, packed into model-colored.zip through
/// `extraFiles` (same road as camera-track.json; ScanUploader.fileKinds untouched).
/// Why (owner 26/09): he installs Release via AltStore and cannot read console logs, so drift
/// and holes were guessed. The old on-phone perf profiler (off since 2.2: no way to get its files
/// off the phone; removed in 2.78) is replaced by this, which rides with the scan.
///
/// Rules:
///  - MAIN THREAD ONLY (ARSession delegate = main queue, Timers on main, notifications hopped
///    to main). No locks.
///  - Observation only: no hook changes scan behaviour; everything here is try?/optional.
///  - 🔴 PRIVACY: no location, address, scan/property name, account or device identifier.
///    Privacy "Information the app captures" names exactly: device model, iOS and app version,
///    duration, tracking and temperature states, error codes (owner approved 26/09). A new
///    field of ANOTHER kind = legal text + App Store answers first.
///  - JSONEncoder throws on non-finite Double: every Double goes through `fin()`. A failed
///    encode = no report; the scan saves as before.
///  - The workstation (texbake/cut-worker) does NOT read this file yet (phase rule 26/09).
final class ScanSessionReport {
    /// Same timebase as ARFrame.timestamp (mach uptime).
    private let t0 = CACurrentMediaTime()
    /// Set by `markStopped()` (Stop & Save pressed): duration ends here and later hooks
    /// (tracking changes during pause/save) are ignored.
    private var stoppedAt: Double?

    // Tracking: seconds per state label, closed on every change and at `finish`.
    private var trackingLabel = "notAvailable"
    private var trackingSince: CFTimeInterval
    private var trackingSeconds: [String: Double] = [:]
    private var trackingChanges = 0

    private struct Interruption: Encodable {
        let start: Double
        var end: Double?
        /// Seconds after the interruption ended until tracking was normal again; nil = never
        /// (or the scan stopped first).
        var relocalizedAfter: Double?
        /// The 10 s relocalize timer found tracking still not normal ("tracking lost" banner).
        var timedOut: Bool
    }
    private var interruptions: [Interruption] = []

    private struct Stamp: Encodable {
        let t: Double
        let v: String
    }
    private var thermal: [Stamp] = []
    private var errors: [Stamp] = []
    private var memoryWarnings = 0
    private var observers: [NSObjectProtocol] = []
    private static let maxStamps = 200

    // White balance (item 2, 26/09).
    var whiteBalanceStatus = "notAttempted"
    var whiteBalanceLockedAt: Double?
    var whiteBalanceGains: [Float]?
    var whiteBalanceRelocks = 0

    init() {
        trackingSince = t0
        thermal.append(Stamp(t: 0, v: Self.thermalLabel(ProcessInfo.processInfo.thermalState)))
        let nc = NotificationCenter.default
        // thermalStateDidChange is posted on an arbitrary thread → hop to main.
        observers.append(nc.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.stamp(\.thermal, Self.thermalLabel(ProcessInfo.processInfo.thermalState))
        })
        observers.append(nc.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.memoryWarnings += 1
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Seconds since the report started (≈ session start).
    var now: Double { CACurrentMediaTime() - t0 }

    private func stamp(_ list: ReferenceWritableKeyPath<ScanSessionReport, [Stamp]>, _ v: String) {
        guard stoppedAt == nil, self[keyPath: list].count < Self.maxStamps else { return }
        let entry = Stamp(t: Self.fin(now) ?? 0, v: v)
        self[keyPath: list].append(entry)
    }

    // MARK: - Hooks (main)

    func markStopped() {
        guard stoppedAt == nil else { return }
        closeTracking()
        stoppedAt = now
    }

    func noteTracking(_ state: ARCamera.TrackingState) {
        guard stoppedAt == nil else { return }
        let label = Self.trackingLabel(state)
        // While interrupted the time stays under "interrupted"; remember the latest state
        // for when the interruption ends.
        if labelBeforeInterruption != nil {
            labelBeforeInterruption = label
            return
        }
        if label == "normal", let i = interruptions.indices.last,
           let end = interruptions[i].end, interruptions[i].relocalizedAfter == nil {
            interruptions[i].relocalizedAfter = Self.fin(now - end)
        }
        guard label != trackingLabel else { return }
        closeTracking()
        trackingLabel = label
        trackingChanges += 1
    }

    /// Label in force before the interruption (ARKit sends no tracking change while
    /// interrupted, so that time is booked under "interrupted" instead).
    private var labelBeforeInterruption: String?

    func noteInterrupted() {
        guard stoppedAt == nil else { return }
        if labelBeforeInterruption == nil {
            closeTracking()
            labelBeforeInterruption = trackingLabel
            trackingLabel = "interrupted"
        }
        guard interruptions.count < Self.maxStamps else { return }
        interruptions.append(Interruption(start: Self.fin(now) ?? 0, timedOut: false))
    }

    func noteInterruptionEnded() {
        guard stoppedAt == nil else { return }
        if let previous = labelBeforeInterruption, trackingLabel == "interrupted" {
            closeTracking()
            trackingLabel = previous
        }
        labelBeforeInterruption = nil
        guard let i = interruptions.indices.last, interruptions[i].end == nil else { return }
        interruptions[i].end = Self.fin(now)
    }

    /// Relocalize timer (10 s after the interruption ended) fired.
    func noteRelocalizeCheck(normal: Bool) {
        guard stoppedAt == nil, let i = interruptions.indices.last, let end = interruptions[i].end else { return }
        if normal {
            if interruptions[i].relocalizedAfter == nil {
                interruptions[i].relocalizedAfter = Self.fin(now - end)
            }
        } else {
            interruptions[i].timedOut = true
        }
    }

    func noteError(_ error: Error) {
        guard stoppedAt == nil else { return }
        let ns = error as NSError
        stamp(\.errors, "\(ns.domain):\(ns.code)")
    }

    private func closeTracking() {
        let t = CACurrentMediaTime()
        trackingSeconds[trackingLabel, default: 0] += max(0, t - trackingSince)
        trackingSince = t
    }

    // MARK: - Output

    /// Texture-shot figures handed back by `TextureShotRecorder.finish` (ioQueue-made, value type).
    struct ShotStats: Encodable {
        /// shots.json written = the texture package rides in the zip. false with kept > 0 =
        /// the package was dropped at finish (e.g. encode failure) — the counts below are
        /// what it held.
        var packageWritten = false
        var taken = 0
        var kept = 0
        var thinningEvents = 0
        var writeFailures = 0
        var withDepth = 0
        var withExposure = 0
        var withWhiteBalance = 0
        /// Kept shots taken with the torch lit (auto torch, 26/09).
        var withTorch = 0
        /// m ↔ m2 (pose at capture vs. final ARKit anchor pose at stop).
        var withFinalPose = 0
        var poseDelta: PoseDelta?
        /// 2.78: ticks at which a due shot waited on the `maxPendingEncodes` gate (main-thread
        /// count, filled in by `TextureShotRecorder.finish`).
        var encodeBusyTicks = 0
    }

    struct PoseDelta: Encodable {
        let n: Int
        let moveCmMedian: Double?
        let moveCmP95: Double?
        let moveCmMax: Double?
        let turnDegMedian: Double?
        let turnDegP95: Double?
        let turnDegMax: Double?
    }

    private struct File: Encodable {
        let version: Int
        let note: String
        let device: String
        let ios: String
        let app: String
        let build: String
        let durationSec: Double?
        let trackingSec: [String: Double]
        let trackingChanges: Int
        let interruptions: [Interruption]
        let thermal: [Stamp]
        let memoryWarnings: Int
        let sessionErrors: [Stamp]
        let hitCap: Bool
        let vertexCount: Int
        let fastSave: Bool
        let textureShots: ShotStats?
        let whiteBalance: WhiteBalance
        /// Auto torch (26/09): status, level, switch counts, lit seconds.
        let torch: AutoTorch.Stats
        /// Exposure cap (ExposureCap; test builds 2.70.1 / 2.70.2, every build since 2.73): the
        /// floor / fixed limit in ms (0 = off), the mode (adaptive | hard | off) and its
        /// status/figures (`exposureCap.source` = default | server | debug). nil = key absent.
        let exposureCapMs: Int?
        let exposureCapMode: String?
        let exposureCap: ExposureCap.Stats?
    }

    private struct WhiteBalance: Encodable {
        let status: String
        let lockedAt: Double?
        let gains: [Float]?
        let relocks: Int
    }

    /// Appended to `note` when the report has an `exposureCap` block. An array join, not a long
    /// `+` chain (Swift type-check time on CI).
    private static let exposureCapNote: String = [
        " exposureCapMode = adaptive (auto-exposure limit starts at exposureCapMs, ",
        "is raised up to the device default only while ISO is at max and frames are ",
        "underexposed, lowered again when ISO has headroom) | hard (fixed at exposureCapMs) | ",
        "off; exposureCapMs = floor / fixed limit (ms, 0 = off); exposureCap = how it went ",
        "(source = default | server (kill switch) | debug (owner picker), ",
        "status, device default / applied limit ms, set times, frames sampled / over / at the ",
        "limit / at max ISO, exifIsoMax, ceilingMs, stepsUp / stepsDown, steps = t (s), lim (ms ",
        "after the step), iso (EXIF), diso (device ISO the loop used), ev, bv0 (EXIF BV at the ",
        "step) and for the first 12 steps bv = EXIF BV at ~10 Hz for 1 s after it) and trace = ",
        "(empty when source = server) 1 Hz t (s), raw EXIF bv, exp (ms), iso (EXIF), ",
        "diso (device ISO), ev (ARKit ",
        "exposureOffset = auto-exposure target offset, EV), lim (device auto-exposure limit ms).",
    ].joined()

    /// 2.78. Array join, ✗ a `+` chain (CI type-check time).
    private static let encodeBusyNote: String = [
        " textureShots.encodeBusyTicks (app 2.78+) = shot ticks (3 Hz) at which a due texture ",
        "shot waited because 3 JPEG encodes were still pending (one wait can count several ticks).",
    ].joined()

    /// Writes the report to a temp file; nil on any failure (the scan saves without it).
    func write(
        hitCap: Bool, vertexCount: Int, fastSave: Bool, shots: ShotStats?, torch: AutoTorch.Stats,
        exposureCap: ExposureCap.Stats?
    ) -> URL? {
        markStopped()
        let secs = trackingSeconds.compactMapValues { Self.fin($0) }
        var note: String = "CedarScan scan diagnostics. Times in seconds since session start. "
            + "trackingSec = time per ARKit tracking state. poseDelta = texture shot pose "
            + "at capture (m) vs final ARKit anchor pose at stop (m2): cm / degrees. "
            + "torch.trace = auto-torch signal at 1 Hz: t (s), bv (smoothed EXIF "
            + "BrightnessValue), d (near LiDAR depth m, -1 none), on (torch lit). "
            + "Not read by the workstation yet."
        if exposureCap != nil {
            note += Self.exposureCapNote
        }
        note += Self.encodeBusyNote
        let file = File(
            version: 1,
            note: note,
            device: Self.deviceModel(),
            ios: UIDevice.current.systemVersion,
            app: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
            durationSec: stoppedAt.flatMap { Self.fin($0) },
            trackingSec: secs,
            trackingChanges: trackingChanges,
            interruptions: interruptions,
            thermal: thermal,
            memoryWarnings: memoryWarnings,
            sessionErrors: errors,
            hitCap: hitCap,
            vertexCount: vertexCount,
            fastSave: fastSave,
            textureShots: shots,
            whiteBalance: WhiteBalance(
                status: whiteBalanceStatus,
                lockedAt: whiteBalanceLockedAt.flatMap { Self.fin($0) },
                gains: whiteBalanceGains.flatMap { g in g.allSatisfy { $0.isFinite } ? g : nil },
                relocks: whiteBalanceRelocks
            ),
            torch: {
                var t = torch
                t.onSec = Self.fin(t.onSec) ?? 0
                t.level = t.level.flatMap { $0.isFinite ? $0 : nil }
                return t
            }(),
            exposureCapMs: exposureCap?.capMs,
            exposureCapMode: exposureCap?.mode,
            exposureCap: exposureCap
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-report-\(UUID().uuidString.prefix(8)).json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: url, options: [.atomic])
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    // MARK: - Save timings (2.78)

    /// Clock of the `save` block — same monotonic clock as `now`. Only DIFFERENCES are written
    /// (durations, covered by the privacy text), never a reading of the clock itself.
    static func clock() -> CFTimeInterval { CACurrentMediaTime() }

    /// Whole milliseconds since `start` (a `clock()` reading); 0 if not a sane duration.
    static func ms(since start: CFTimeInterval) -> Int {
        let value = (CACurrentMediaTime() - start) * 1000
        guard value.isFinite, value > 0, value < 1e12 else { return 0 }
        return Int(value.rounded())
    }

    /// Merges `fields` (Int / String values only) into the report's `save` block, and sets
    /// `totalMs` = `exportMs` + `storeMs` once both are there. Two writers, in order:
    /// `MeshScanController.stopAndExport` (awaited, off main) and the zip step of
    /// `ScanStore.saveMeshScan` right before packing (after `PreviewColorJob` wrote
    /// `previewColour`). Blocking file I/O — never on main. Atomic rewrite; any failure = the
    /// report stays as it was, the save goes on.
    static func patchSave(_ url: URL?, _ fields: [String: any Sendable]) {
        guard let url, !fields.isEmpty,
              let data = try? Data(contentsOf: url),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        var save = (object["save"] as? [String: Any]) ?? [:]
        for (key, value) in fields {
            save[key] = value
        }
        if let exportMs = save["exportMs"] as? Int, let storeMs = save["storeMs"] as? Int {
            save["totalMs"] = exportMs + storeMs
        }
        object["save"] = save
        if let note = object["note"] as? String, !note.contains(saveNote) {
            object["note"] = note + saveNote
        }
        guard JSONSerialization.isValidJSONObject(object),
              let out = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
              )
        else { return }
        try? out.write(to: url, options: .atomic)
    }

    /// Appended to `note` by the first `patchSave`. Array join (CI type-check time).
    private static let saveNote: String = [
        " save (app 2.78+) = how long Stop & Save took on this phone, ms: stopMs = until the ",
        "video and texture shots were closed; plyMs = mesh file; previewMs = grey 3D preview ",
        "(preview = quadric / cluster / none, previewVertices = vertices written, 0 = no preview ",
        "file); exportMs = all of these; storeMs = moving the files + reading the mesh + writing ",
        "the OBJ, until packing (objMs = reading + writing of the attempt that was packed, ",
        "zipAttempts = 1 or 2); totalMs = exportMs + storeMs. Packing (copy + compress) runs ",
        "after this file is written and is not included. video = ok / noFrames / notStarted / ",
        "failed / noRecorder (videoWriterStatus = AVAssetWriter.Status raw value, videoError = ",
        "error domain:code, then the underlying one).",
    ].joined()

    // MARK: - Helpers

    /// Finite → rounded to 3 decimals; non-finite → nil (JSONEncoder would throw).
    static func fin(_ x: Double) -> Double? {
        guard x.isFinite else { return nil }
        return (x * 1000).rounded() / 1000
    }

    /// Hardware model identifier, e.g. "iPhone16,1" — not a device identifier.
    static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        let name = withUnsafeBytes(of: &info.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return name.isEmpty ? "?" : name
    }

    static func trackingLabel(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: return "normal"
        case .notAvailable: return "notAvailable"
        case .limited(let reason):
            switch reason {
            case .initializing: return "limited.initializing"
            case .excessiveMotion: return "limited.excessiveMotion"
            case .insufficientFeatures: return "limited.insufficientFeatures"
            case .relocalizing: return "limited.relocalizing"
            @unknown default: return "limited.other"
            }
        }
    }

    static func thermalLabel(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
