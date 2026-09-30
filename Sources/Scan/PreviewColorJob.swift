import Foundation

/// `PreviewColorizer` running beside the OBJ/zip step of `ScanStore.saveMeshScan`.
///
/// A GCD queue of its own, ✗ a Swift Task: the zip step waits for it from inside
/// `ColoredOBJExporter.makeOBJZip` (synchronous, on a cooperative-pool thread) right before the
/// scan report is packed. Waiting on a job that itself needed a pool thread could starve; a GCD
/// thread cannot. The wait is bounded by the colouring's own 10 s budget.
///
/// Lifecycle (all in `saveMeshScan`): start after `mesh-preview.bin` is in the scan folder →
/// `finishAndReport` before packing (report gets `previewColour`) → `cancel` + `finished()`
/// before the function returns, so the texture shots are never deleted under a running job.
final class PreviewColorJob: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var cancelled = false
    private var stats: PreviewColorizer.Stats?

    init(previewURL: URL, shotsDir: URL) {
        group.enter()
        DispatchQueue(label: "cedar.preview-colour", qos: .userInitiated).async { [self] in
            let result = PreviewColorizer.run(previewURL: previewURL, shotsDir: shotsDir) {
                self.isCancelled
            }
            lock.lock()
            stats = result
            lock.unlock()
            group.leave()
        }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var result: PreviewColorizer.Stats? {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    /// BLOCKS the calling thread until the job ends (≤ its 10 s budget + a margin), then writes
    /// `previewColour` into the scan report. Called from the zip step, never from main.
    /// Idempotent (the zip step may run twice).
    func finishAndReport(to reportURL: URL?) {
        if group.wait(timeout: .now() + PreviewColorizer.budgetSeconds + 5) == .timedOut {
            // Should not happen (the job checks its budget per shot / per pass). Stop it; the
            // report says so and the save goes on.
            cancel()
        }
        guard let reportURL else { return }
        Self.patch(reportURL, entry: result?.json ?? ["status": "stillRunning"])
    }

    /// Async wait (no thread blocked) for the end of `saveMeshScan`, at most `seconds` (call
    /// `cancel()` first: the job then stops within one shot / fill pass). Past the limit the
    /// save goes on: a shot file deleted under the job only makes that shot's read fail.
    func finished(within seconds: Double) async {
        // A box, ✗ a captured `var`: Dispatch closures are @Sendable (mutating a captured var
        // there does not compile).
        let once = Once()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global(qos: .userInitiated)) {
                if once.claim() { continuation.resume() }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                if once.claim() { continuation.resume() }
            }
        }
    }

    /// First caller wins (the continuation must resume exactly once).
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    /// Adds `previewColour` to scan-report.json (same pretty, sorted format). Any failure =
    /// report left as it was.
    private static func patch(_ url: URL, entry: [String: Any]) {
        guard let data = try? Data(contentsOf: url),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        object["previewColour"] = entry
        if let note = object["note"] as? String, !note.contains("previewColour") {
            // Array join, ✗ a `+` chain into `Any?` (CI type-check time).
            let addition: String = [
                " previewColour = phone colouring of the in-app 3D preview (app 2.77+): status ",
                "(done / hot / timeout / sparse / tooBig / cancelled / noShots / noPreview / ",
                "failed / writeFailed), ms, shots, shotsUsed, vertices, direct / filled = ",
                "fraction of preview vertices coloured from a shot / after the fill, thermal ",
                "at the end.",
            ].joined()
            object["note"] = note + addition
        }
        guard JSONSerialization.isValidJSONObject(object),
              let out = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? out.write(to: url, options: .atomic)
    }
}
