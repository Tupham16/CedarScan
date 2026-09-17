import ARKit
import QuartzCore
import SwiftUI

/// Scan-start timing probe — MEASUREMENT ONLY (2026-09-17: "4 s from tapping Scan until the
/// mesh shows"). Owner-only BRANCH build; ✗ merge to main with `enabled == true`.
/// Observation only: no hook changes control flow. Main thread only, no locks.
/// `enabled == false` → every hook is an early-out and the label draws nothing.
///
/// Marks (seconds from the first one): tap (address sheet button) · show (`ScanCover.show`) ·
/// appear (`MeshScanFlowView.onAppear`) · run (`arSession.run` returned) · started
/// (`startSession` returned) · loop (first display-link callback after that — a late one means
/// main was blocked) · frame (first ARFrame) · normal (tracking normal) · anchor (first
/// ARMeshAnchor in a frame) · tint (red "unscanned" tint shown) · queued (overlay queued its
/// first geometry build) · drawn (first wireframe geometry assigned; rasterised ≥ 1 frame later).
/// `cam fps` / `mainGapMax` are sampled from the main thread — same reading rule as
/// `ScanPerfProfiler`: a main stall depresses the first and inflates the second.
final class ScanStartProbe: ObservableObject {
    static let enabled = true
    static let shared = ScanStartProbe()

    /// Current run, then the two previous ones — one screenshot carries three starts.
    @Published private(set) var text = ""

    private struct Mark {
        let name: String
        let t: Double
        let note: String
    }

    private var isOpen = false
    private var t0: CFTimeInterval = 0
    private var header = ""
    private var marks: [Mark] = []
    private var history: [String] = []

    private weak var session: ARSession?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var gapMaxMs = 0.0
    private var lastFrameTs: TimeInterval = 0
    private var frames = 0
    private var firstFrameAt: CFTimeInterval = 0

    // MARK: - Hooks

    /// New run with `name` as t = 0 — unless a run opened by the address-sheet tap is still
    /// waiting for its cover (then `name` is just its next mark). Entries that skip the address
    /// sheet ("Scan more", "Scan the rest now") start their run at `show`.
    static func begin(_ name: String) {
        guard enabled else { return }
        let probe = shared
        if probe.isOpen, probe.marks.count == 1, CACurrentMediaTime() - probe.t0 < 5 {
            probe.add(name, note: "")
        } else {
            probe.beginRun(name)
        }
    }

    /// Records `name` once per open run; ignored when no run is open. `note` is only evaluated
    /// when the mark is actually recorded.
    static func mark(_ name: String, note: @autoclosure () -> String = "") {
        guard enabled, shared.isOpen, !shared.has(name) else { return }
        shared.add(name, note: note())
    }

    /// Polls `session` at 60 Hz for the first frame / tracking normal / first mesh anchor.
    /// Stops itself at `drawn` or after 20 s.
    static func watch(_ session: ARSession) {
        guard enabled, shared.isOpen else { return }
        shared.startPolling(session)
    }

    /// Scan over (Stop & Save / Cancel): close its run, so an abandoned one stops accumulating.
    /// The identity check keeps a late teardown from closing the next run.
    static func end(_ session: ARSession) {
        guard enabled, shared.isOpen, shared.session === session else { return }
        shared.close()
    }

    // MARK: - Run

    private func has(_ name: String) -> Bool {
        marks.contains(where: { $0.name == name })
    }

    private func beginRun(_ name: String) {
        stopPolling()
        if !marks.isEmpty {
            history.insert(render(), at: 0)
            if history.count > 2 { history.removeLast() }
        }
        isOpen = true
        t0 = CACurrentMediaTime()
        marks = [Mark(name: name, t: 0, note: "")]
        lastTick = 0
        gapMaxMs = 0
        lastFrameTs = 0
        frames = 0
        firstFrameAt = 0
        let info = ProcessInfo.processInfo
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        header = "probe \(version) thermal=\(Self.label(info.thermalState))"
        if info.isLowPowerModeEnabled { header += " LOW-POWER" }
        publish()
    }

    private func add(_ name: String, note: String) {
        guard !has(name) else { return }
        marks.append(Mark(name: name, t: CACurrentMediaTime() - t0, note: note))
        publish()
    }

    private func close() {
        isOpen = false
        stopPolling()
        publish()
    }

    private func startPolling(_ session: ARSession) {
        stopPolling()
        self.session = session
        lastTick = 0
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopPolling() {
        link?.invalidate()
        link = nil
        session = nil
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        if lastTick > 0 {
            gapMaxMs = max(gapMaxMs, (now - lastTick) * 1000)
        } else {
            add("loop", note: "")
        }
        lastTick = now
        if now - t0 > 20 || has("drawn") {
            close()
            return
        }
        guard let frame = session?.currentFrame else { return }
        if frame.timestamp != lastFrameTs {
            lastFrameTs = frame.timestamp
            frames += 1
            if firstFrameAt == 0 { firstFrameAt = now }
        }
        add("frame", note: "")
        if case .normal = frame.camera.trackingState {
            add("normal", note: "")
        }
        // `frame.anchors` stays empty until the first mesh anchor, and this loop stops looking
        // once it has been seen — cheap.
        if !has("anchor") {
            for anchor in frame.anchors {
                if let mesh = anchor as? ARMeshAnchor {
                    add("anchor", note: "(\(mesh.geometry.vertices.count)v)")
                    break
                }
            }
        }
    }

    // MARK: - Text

    private func publish() {
        text = ([render()] + history).joined(separator: "\n\n")
    }

    private func render() -> String {
        var rows = [header]
        var row: [String] = []
        for mark in marks {
            row.append(mark.name + " " + String(format: "%.2f", mark.t) + mark.note)
            if row.count == 3 {
                rows.append(row.joined(separator: "  "))
                row = []
            }
        }
        if !row.isEmpty { rows.append(row.joined(separator: "  ")) }
        let span = lastTick - firstFrameAt
        if firstFrameAt > 0, span > 0.2 {
            let fps = Int((Double(frames) / span).rounded())
            rows.append("cam \(fps)fps  mainGapMax \(Int(gapMaxMs))ms")
        }
        return rows.joined(separator: "\n")
    }

    private static func label(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// On-screen readout for the owner's screenshot. Draws nothing when the probe is off.
/// Top padding 140 keeps it clear of the coach capsule (`QualityAlertOverlay`, top 64).
struct ScanStartProbeLabel: View {
    @ObservedObject private var probe = ScanStartProbe.shared

    var body: some View {
        if ScanStartProbe.enabled, !probe.text.isEmpty {
            Text(verbatim: probe.text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white)
                .padding(8)
                .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 140)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
