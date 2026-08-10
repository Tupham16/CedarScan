import Foundation
import ARKit
import QuartzCore
import UIKit
import Darwin

/// Scan-time performance profiler — MEASUREMENT ONLY (added 2026-08-09 for the
/// "mesh drifts within seconds when the phone is already hot" investigation;
/// background in SESSION-HANDOFF §STATE).
///
/// Records, per scan session:
///  - per-tick wall time of every main-thread CADisplayLink loop that runs during a
///    scan (ColorMeshBuilder ~3Hz, MeshOverlayRenderer 30Hz, TextureShotRecorder ~3Hz,
///    ScanVideoRecorder ~8Hz, ScanQualityMonitor ~12Hz),
///  - main-thread hitches (gaps between callbacks of a 60Hz monitor display link),
///  - ARKit camera fps + largest camera-frame gap AS OBSERVED FROM THE MAIN THREAD
///    (a main-thread stall also stalls the sampler, so camGapMax mirrors mainGapMax
///    in stalled rows — the report prints the decoding rule next to the data),
///  - thermal state / Low Power Mode timeline + memory warnings,
///  - tracking-state transitions and session interruptions with timestamps,
///  - 1Hz process CPU / main-thread CPU / memory-footprint samples.
///
/// One plain-text report per scan is written to Documents/perf-logs/.
///
/// 🔴 THERE IS NO LONGER A WAY TO GET THOSE FILES OFF THE PHONE (2026-08-11, build
/// 2.2): the owner used to pull them from the Files app ("On My iPhone" → CedarScan →
/// perf-logs), which only worked because Info.plist carried `UIFileSharingEnabled` +
/// `LSSupportsOpeningDocumentsInPlace`. Both keys were REMOVED at the owner's request
/// — they also exposed Documents/Scans/ (the whole working folder) to every customer.
/// That is why `enabled` below is false: with no retrieval path, a running profiler
/// only writes files nobody can read. To measure again: re-add BOTH keys in
/// project.yml, flip `enabled` back to true, ship that build to the OWNER ONLY, and
/// remove the keys again afterwards. AltStore Release builds have no console, so a
/// file plus those two keys is still the only way out.
///
/// INVARIANTS (do not break):
///  - Observation only. NO behavior change to any scanning code path: each hook is a
///    timestamp pair; the report is formatted and written on a background queue only
///    AFTER the scan has already stopped.
///  - Every mutable field is touched on the MAIN thread only (all hooked loops are
///    main-thread CADisplayLinks; the ARSession delegate and all observers are main
///    queue). There are NO locks — do not add call sites on other threads.
///  - `enabled` is the master switch: when false every hook is a two-instruction
///    early-out. The measurement campaign ENDED 2026-08-10, so the flag is now false —
///    ✗ rip the hooks out, the next perf question will need them again (same rule as
///    `RootView.autoPurgeAfterDelivery`).
final class ScanPerfProfiler {

    /// Master switch for the whole profiler. Compile-time constant so the optimizer
    /// can fold the disabled path to nothing.
    /// OFF since 2026-08-11 (build 2.2) — campaign over AND the log-retrieval path is
    /// gone with the two Info.plist file-sharing keys; see the type doc above.
    static let enabled = false

    /// Identity of a hooked display-link loop. rawValue indexes the accumulator
    /// arrays — keep it dense from 0.
    enum Loop: Int, CaseIterable {
        case colorMesh = 0, overlay, texShot, video, quality

        var shortName: String {
            switch self {
            case .colorMesh: return "cm"
            case .overlay: return "ov"
            case .texShot: return "ts"
            case .video: return "vd"
            case .quality: return "qm"
            }
        }

        var fullName: String {
            switch self {
            case .colorMesh: return "ColorMeshBuilder(~3Hz)"
            case .overlay: return "MeshOverlayRenderer(30Hz)"
            case .texShot: return "TextureShotRecorder(~3Hz)"
            case .video: return "ScanVideoRecorder(~8Hz)"
            case .quality: return "ScanQualityMonitor(~12Hz)"
            }
        }
    }

    private(set) static var shared: ScanPerfProfiler?

    // MARK: - Static hooks (all main thread)

    /// Call right before `arSession.run` so the fragile first seconds of VIO init
    /// land inside the recording window.
    static func start(session: ARSession) {
        guard enabled else { return }
        // A previous instance can only still exist if a scan ended without
        // teardownCommon running — never observed, but never lose its data either.
        shared?.finish(reason: "superseded")
        shared = ScanPerfProfiler(session: session)
    }

    static func stop(reason: String) {
        guard enabled, let profiler = shared else { return }
        shared = nil
        profiler.finish(reason: reason)
    }

    /// Top of a hooked tick. Pair with `tickEnd` in a `defer` so early `guard`
    /// returns are counted too (idle ticks are data: they show a loop was scheduled).
    @inline(__always)
    static func tickBegin() -> CFTimeInterval {
        guard enabled, shared != nil else { return 0 }
        return CACurrentMediaTime()
    }

    @inline(__always)
    static func tickEnd(_ loop: Loop, _ t0: CFTimeInterval) {
        guard t0 > 0, let profiler = shared, !profiler.finished else { return }
        profiler.record(loop: loop, ms: (CACurrentMediaTime() - t0) * 1000)
    }

    static func noteTracking(_ state: ARCamera.TrackingState) {
        guard enabled, let profiler = shared else { return }
        profiler.addEvent("tracking=\(trackingLabel(state))")
    }

    static func noteEvent(_ label: String) {
        guard enabled, let profiler = shared else { return }
        profiler.addEvent(label)
    }

    // MARK: - Instance state (main thread only)

    private weak var session: ARSession?
    private let t0: CFTimeInterval
    private let startDate: Date
    private let fileURL: URL
    private let mainThreadPort: mach_port_t
    private var finished = false

    private var monitorLink: CADisplayLink?
    private var observers: [NSObjectProtocol] = []

    private var thermalNow: ProcessInfo.ThermalState
    private var lowPowerNow: Bool

    private struct Event {
        let t: Double
        let label: String
    }
    /// Slow-tick events draw from their OWN sub-budget (maxSlowEvents) inside the
    /// shared cap, so lifecycle events (tracking/thermal/interruption) always have
    /// at least maxEvents - maxSlowEvents slots no matter how pathological the run.
    private static let maxEvents = 2000
    private static let maxSlowEvents = 1400
    private var slowEventCount = 0
    private var events: [Event] = []
    private var eventsDropped = false

    private struct LoopAgg {
        var count = 0
        var totalMs = 0.0
        var maxMs = 0.0
    }

    /// One row per wall-clock second. Seconds can SKIP when the main thread stalls
    /// longer than a second — the monitor link that drives rollover is itself blocked.
    private struct Row {
        var sec: Int
        var thermal: String
        var lowPower: Bool
        var camFrames: Int
        var camGapMaxMs: Int
        var mainGapMaxMs: Int
        var hitch25: Int
        var hitch100: Int
        var cpuProcPct: Int
        var cpuMainPct: Int
        var memMB: Int
        var loops: [LoopAgg]
    }
    private static let maxRows = 3700 // > 1 hour; test scans are minutes
    private var rows: [Row] = []
    private var rowsDropped = false

    // Current-second accumulators, reset at each rollover.
    private var curSec = 0
    private var curLoops = [LoopAgg](repeating: LoopAgg(), count: Loop.allCases.count)
    private var curGapMax = 0.0
    private var curHitch25 = 0
    private var curHitch100 = 0
    private var curCamFrames = 0
    private var curCamGapMax = 0.0
    private var lastMonitor: CFTimeInterval = 0
    private var lastCamTs: TimeInterval = 0
    /// Set to "now" at every app re-activation. ARKit re-serves the PRE-PAUSE frame
    /// for a while after resume (documented in TextureShotRecorder), so frames
    /// stamped before this guard only re-arm the camera baseline — they must never
    /// book a gap or count as delivered frames, or every lock/call/app-switch would
    /// fabricate a giant "camera gap" in a row the READING RULE says to trust.
    /// ARFrame.timestamp and CACurrentMediaTime share the mach-uptime timebase.
    private var camResumeGuard: CFTimeInterval = 0
    /// Last second a slow-tick event was emitted, per loop — rate-limits the event
    /// stream to 1/loop/second so a saturated hot run cannot flood the event budget
    /// and starve out tracking/interruption events (each row's per-loop maxMs still
    /// records every second's worst tick regardless).
    private var lastSlowEventSec = [Int](repeating: -1, count: Loop.allCases.count)

    private init(session: ARSession) {
        self.session = session
        t0 = CACurrentMediaTime()
        startDate = Date()
        // pthread_mach_thread_np does NOT mint a new port right (unlike
        // mach_thread_self) — nothing to deallocate.
        mainThreadPort = pthread_mach_thread_np(pthread_self())
        fileURL = Self.logDirectory.appendingPathComponent(
            "CedarScan-perf-\(Self.fileStamp.string(from: startDate)).txt")
        thermalNow = ProcessInfo.processInfo.thermalState
        lowPowerNow = ProcessInfo.processInfo.isLowPowerModeEnabled
        addEvent("profiler-start thermal=\(Self.thermalLabel(thermalNow)) lowPower=\(lowPowerNow)")

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.thermalNow = ProcessInfo.processInfo.thermalState
            self.addEvent("thermal=\(Self.thermalLabel(self.thermalNow))")
        })
        observers.append(center.addObserver(
            forName: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lowPowerNow = ProcessInfo.processInfo.isLowPowerModeEnabled
            self.addEvent("lowPower=\(self.lowPowerNow)")
        })
        observers.append(center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.addEvent("memory-warning")
        })
        observers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.addEvent("app-resign-active")
        })
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Display links are paused while the app is inactive (call, lock, app
            // switch). Without these resets the first tick after resume would book the
            // whole pause as one giant fake main-thread hitch + camera gap and pollute
            // the SUMMARY totals. lastMonitor is re-armed to NOW (not 0) so a REAL
            // main-thread stall between this notification and the first resumed tick
            // is still measured; camResumeGuard makes stale pre-pause frames
            // baseline-only. The pause itself stays visible via the app-resign/active
            // event pair and the skipped sec numbers.
            let now = CACurrentMediaTime()
            self.lastMonitor = now
            self.camResumeGuard = now
            self.addEvent("app-active (gap baselines reset)")
        })

        let link = CADisplayLink(target: self, selector: #selector(monitorTick(_:)))
        // Pinned to 60: the panel rate of every current target device. An open range
        // would let a ProMotion panel run at 120Hz just for this probe.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        monitorLink = link
    }

    // MARK: - Recording

    private func addEvent(_ label: String) {
        guard events.count < Self.maxEvents else {
            eventsDropped = true
            return
        }
        events.append(Event(t: CACurrentMediaTime() - t0, label: label))
    }

    private func record(loop: Loop, ms: Double) {
        let i = loop.rawValue
        curLoops[i].count += 1
        curLoops[i].totalMs += ms
        if ms > curLoops[i].maxMs { curLoops[i].maxMs = ms }
        // A single tick this long is a story of its own — pin it to the timeline.
        // Rate-limited to 1/loop/second AND capped by the slow-tick sub-budget: a hot
        // run with sustained slow ticks must never crowd tracking-state transitions
        // out of the event list (per-row maxMs keeps recording regardless).
        if ms > 80, lastSlowEventSec[i] != curSec {
            if slowEventCount < Self.maxSlowEvents {
                lastSlowEventSec[i] = curSec
                slowEventCount += 1
                addEvent("slow-tick \(loop.shortName)=\(Int(ms))ms")
            } else if slowEventCount == Self.maxSlowEvents {
                // One-shot marker, drawn from the lifecycle share of the budget —
                // without it, slow-ticks vanishing mid-timeline reads as "device
                // recovered" instead of "sub-budget exhausted".
                slowEventCount += 1
                addEvent("slow-tick events truncated at \(Self.maxSlowEvents); per-row maxMs still complete")
            }
        }
    }

    @objc private func monitorTick(_ link: CADisplayLink) {
        guard !finished else { return }
        let now = CACurrentMediaTime()
        // Rollover BEFORE booking: a gap is attributed to the row where it ENDED.
        // Matters for post-resume stalls — they must land in a trusted row, not in
        // the pre-pause row the READING RULE tells the reader to exclude.
        let sec = Int(now - t0)
        if sec > curSec {
            closeRow()
            curSec = sec
        }
        if lastMonitor > 0 {
            let gap = (now - lastMonitor) * 1000
            if gap > curGapMax { curGapMax = gap }
            if gap > 25 { curHitch25 += 1 }   // missed >= 1 frame at 60Hz
            if gap > 100 { curHitch100 += 1 } // user-visible hitch
        }
        lastMonitor = now
        // Distinct ARFrame timestamps per second ~= camera fps (ceiling 60 at 60Hz
        // sampling). Read-only peek, frame released within this callback.
        // Frames stamped at/before camResumeGuard are stale pre-pause re-serves:
        // baseline-only (no gap, no count) — see the field's comment.
        if let ts = session?.currentFrame?.timestamp, ts != lastCamTs {
            if ts > camResumeGuard, lastCamTs > camResumeGuard {
                let gap = (ts - lastCamTs) * 1000
                if gap > curCamGapMax { curCamGapMax = gap }
            }
            lastCamTs = ts
            if ts > camResumeGuard { curCamFrames += 1 }
        }
    }

    private func closeRow() {
        let cpu = sampleCPU()
        let row = Row(
            sec: curSec,
            thermal: Self.thermalLabel(thermalNow),
            lowPower: lowPowerNow,
            camFrames: curCamFrames,
            camGapMaxMs: Int(curCamGapMax.rounded()),
            mainGapMaxMs: Int(curGapMax.rounded()),
            hitch25: curHitch25,
            hitch100: curHitch100,
            cpuProcPct: cpu.proc,
            cpuMainPct: cpu.main,
            memMB: memoryFootprintMB(),
            loops: curLoops
        )
        if rows.count < Self.maxRows {
            rows.append(row)
        } else {
            rowsDropped = true
        }
        curLoops = [LoopAgg](repeating: LoopAgg(), count: Loop.allCases.count)
        curGapMax = 0
        curHitch25 = 0
        curHitch100 = 0
        curCamFrames = 0
        curCamGapMax = 0
    }

    private func finish(reason: String) {
        guard !finished else { return }
        addEvent("profiler-stop reason=\(reason) thermal=\(Self.thermalLabel(ProcessInfo.processInfo.thermalState))")
        closeRow() // flush the partial last second
        finished = true
        monitorLink?.invalidate()
        monitorLink = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()

        // Snapshot value types, then leave the main thread alone — the export/save
        // pipeline is about to start. Header strings are captured HERE because
        // UIDevice is a UIKit main-thread object; the writer runs on a background queue.
        let snapshot = Snapshot(
            fileURL: fileURL,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            device: Self.deviceModel(),
            osVersion: UIDevice.current.systemVersion,
            cores: ProcessInfo.processInfo.activeProcessorCount,
            startDate: startDate,
            durationSec: CACurrentMediaTime() - t0,
            reason: reason,
            rows: rows,
            rowsDropped: rowsDropped,
            events: events,
            eventsDropped: eventsDropped
        )
        DispatchQueue.global(qos: .utility).async {
            Self.writeReport(snapshot)
        }
    }

    // MARK: - CPU / memory sampling (1Hz, main thread, ~tens of us)

    private func sampleCPU() -> (proc: Int, main: Int) {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let threads = list else {
            return (-1, -1)
        }
        defer {
            // task_threads mints a send right per thread AND a vm allocation for the
            // list — leak either and 30 min of 1Hz sampling piles up thousands.
            for i in 0..<Int(count) {
                mach_port_deallocate(mach_task_self_, threads[i])
            }
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threads)),
                vm_size_t(count) * vm_size_t(MemoryLayout<thread_t>.stride)
            )
        }
        var procPct = 0.0
        var mainPct = -1.0
        for i in 0..<Int(count) {
            var info = thread_basic_info_data_t()
            var infoCount = mach_msg_type_number_t(
                MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            guard kr == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else { continue }
            let pct = Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            procPct += pct
            if threads[i] == mainThreadPort { mainPct = pct }
        }
        return (Int(procPct.rounded()), mainPct < 0 ? -1 : Int(mainPct.rounded()))
    }

    private func memoryFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint / (1024 * 1024))
    }

    // MARK: - Report writing (background queue, after the scan has stopped)

    private struct Snapshot {
        let fileURL: URL
        let appVersion: String
        let device: String
        let osVersion: String
        let cores: Int
        let startDate: Date
        let durationSec: Double
        let reason: String
        let rows: [Row]
        let rowsDropped: Bool
        let events: [Event]
        let eventsDropped: Bool
    }

    private static func writeReport(_ s: Snapshot) {
        var out = ""
        out.reserveCapacity(32 * 1024 + s.rows.count * 160)
        out += "CedarScan perf log v1\n"
        out += "app \(s.appVersion) device \(s.device) ios \(s.osVersion)\n"
        out += "start \(iso.string(from: s.startDate)) duration \(f1(s.durationSec))s reason=\(s.reason)\n"
        out += "cores \(s.cores)\n"

        out += "\n== EVENTS ==\n"
        for e in s.events {
            out += "+\(f3(e.t)) \(e.label)\n"
        }
        if s.eventsDropped { out += "(events truncated at \(maxEvents))\n" }

        out += "\n== PER-SECOND ==\n"
        out += "(sec numbers can SKIP where the main thread stalled >1s)\n"
        out += "(READING RULE: camFps/camGapMax are sampled FROM the main thread. A main-thread\n"
        out += " stall depresses camFps and inflates camGapMax mechanically, so camGapMax ~= mainGapMax\n"
        out += " proves nothing about the camera. Trust camera degradation only where camGapMax >>\n"
        out += " mainGapMax in the same row, or camFps is low while mainGapMax stays ~16ms.\n"
        out += " Rows bracketed by app-resign-active/app-active or session-interrupted events\n"
        out += " cover a paused app — exclude them.)\n"
        out += "sec,thermal,lp,camFps,camGapMax,mainGapMax,h25,h100,cpuProc,cpuMain,memMB"
        for loop in Loop.allCases {
            out += ",\(loop.shortName)N,\(loop.shortName)Tot,\(loop.shortName)Max"
        }
        out += "\n"
        for r in s.rows {
            out += "\(r.sec),\(r.thermal),\(r.lowPower ? 1 : 0),\(r.camFrames),\(r.camGapMaxMs)"
            out += ",\(r.mainGapMaxMs),\(r.hitch25),\(r.hitch100),\(r.cpuProcPct),\(r.cpuMainPct),\(r.memMB)"
            for agg in r.loops {
                out += ",\(agg.count),\(f1(agg.totalMs)),\(f1(agg.maxMs))"
            }
            out += "\n"
        }
        if s.rowsDropped { out += "(rows truncated at \(maxRows))\n" }

        out += "\n== SUMMARY ==\n"
        let dur = max(s.durationSec, 0.001)
        for loop in Loop.allCases {
            var ticks = 0
            var busy = 0.0
            var maxMs = 0.0
            var busyFirst10 = 0.0
            for r in s.rows {
                let agg = r.loops[loop.rawValue]
                ticks += agg.count
                busy += agg.totalMs
                if agg.maxMs > maxMs { maxMs = agg.maxMs }
                if r.sec < 10 { busyFirst10 += agg.totalMs }
            }
            let mean = ticks > 0 ? busy / Double(ticks) : 0
            out += "\(loop.fullName): ticks \(ticks), busy \(f1(busy))ms"
            out += " (\(f1(busy / dur / 10))% of scan), mean \(f2(mean))ms, max \(f1(maxMs))ms"
            out += ", first10s \(f1(busyFirst10))ms\n"
        }
        var h25 = 0
        var h100 = 0
        var camTotal = 0
        var camFirst10 = 0
        var first10Rows = 0
        for r in s.rows {
            h25 += r.hitch25
            h100 += r.hitch100
            camTotal += r.camFrames
            if r.sec < 10 {
                camFirst10 += r.camFrames
                first10Rows += 1
            }
        }
        out += "main hitches: >25ms \(h25), >100ms \(h100)\n"
        // Mean over OBSERVED seconds (rows), not wall duration — an app pause emits
        // no rows, and dividing by wall time would halve the "fps" of a healthy
        // camera after a mid-scan phone call.
        out += "camera fps: mean \(f1(Double(camTotal) / Double(max(s.rows.count, 1))))"
        out += " over \(s.rows.count) observed sec"
        if first10Rows > 0 {
            out += ", first10s \(f1(Double(camFirst10) / Double(first10Rows)))"
        }
        out += " (main-thread-sampled — apply the READING RULE above before blaming the camera)\n"

        let fm = FileManager.default
        try? fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try? out.data(using: .utf8)?.write(to: s.fileURL, options: .atomic)
        pruneOldLogs()
    }

    /// Keep the newest 20 logs — filenames embed the timestamp so name order is
    /// chronological order.
    private static func pruneOldLogs() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: logDirectory.path) else { return }
        let logs = names.filter { $0.hasPrefix("CedarScan-perf-") }.sorted()
        guard logs.count > 20 else { return }
        for name in logs.prefix(logs.count - 20) {
            try? fm.removeItem(at: logDirectory.appendingPathComponent(name))
        }
    }

    // MARK: - Formatting helpers

    private static var logDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("perf-logs", isDirectory: true)
    }

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone.current
        return f
    }()

    private static func f1(_ x: Double) -> String { String(format: "%.1f", x) }
    private static func f2(_ x: Double) -> String { String(format: "%.2f", x) }
    private static func f3(_ x: Double) -> String { String(format: "%.3f", x) }

    private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func trackingLabel(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: return "normal"
        case .notAvailable: return "notAvailable"
        case .limited(let reason):
            switch reason {
            case .initializing: return "limited(initializing)"
            case .excessiveMotion: return "limited(excessiveMotion)"
            case .insufficientFeatures: return "limited(insufficientFeatures)"
            case .relocalizing: return "limited(relocalizing)"
            @unknown default: return "limited(unknown)"
            }
        @unknown default: return "unknown"
        }
    }

    private static func deviceModel() -> String {
        var sys = utsname()
        uname(&sys)
        var machine = sys.machine
        return withUnsafeBytes(of: &machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
