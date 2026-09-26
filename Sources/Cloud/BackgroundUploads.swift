import Foundation
import UIKit

/// Scan-file PUTs on a BACKGROUND URLSession (2.59, owner 26/09). Before: `URLSession.shared` ⇒
/// the phone auto-locked 30–60 s after the scan, the app was suspended, the 80–220 MB upload died
/// and the next tap started from zero. Transfers now run in `nsurlsessiond` while the screen is
/// locked, another app is open, or the app was killed by the system.
///
/// Callers: `ScanUploader` only (order-files / tour photos are small and stay on `APIClient`).
///
/// Three things survive a relaunch, none of them the Swift flow that started the upload:
///  · the transfer itself (tag = `taskDescription`, see `Tag`),
///  · `UploadJournal` — server scan id + kinds already on R2, written HERE on each 2xx, so a later
///    tap resumes (`ScanUploader`) instead of re-sending every file,
///  · the system's completion handler (`AppDelegate` → `systemCompletion`).
/// The order/supplement call is NOT resumed after a relaunch: its choices lived in the sheet. The
/// customer taps again and only the missing files go up.
final class BackgroundUploads: NSObject {
    static let shared = BackgroundUploads()
    static let sessionId = "com.cedar247.cedarscan.scan-uploads"
    /// A background session never fails for lack of network — it waits (up to the resource
    /// timeout). With the app on screen and no byte sent for this long, the WAIT gives up (the
    /// transfer carries on, a later tap re-joins it); otherwise "0 %" forever + screen never sleeps.
    private static let stallSeconds: UInt64 = 60

    /// iOS's "done handling events" handler (`AppDelegate`); main thread only.
    private var systemCompletion: (() -> Void)?
    /// Events drained before `AppDelegate` handed the handler over (session created at launch).
    private var eventsFinished = false

    private var session: URLSession!
    private let lock = NSLock()
    /// Flows waiting on a tag. Several are allowed (same record from two places); all get the result.
    private var waiters: [String: [Int: Waiter]] = [:]
    private var nextWaiterId = 0
    /// Tag → `taskIdentifier` of THE live task this process tracks for it (started or adopted).
    /// A completion from any other task of the tag (stale, from before a relaunch) only counts
    /// for its 2xx; it never clears this or fails the waiters.
    private var launched: [String: Int] = [:]
    /// Bytes sent by the tracked task, per tag (stall watchdog).
    private var sentByKey: [String: Int64] = [:]
    /// Tasks that may be discretionary (created while the app was not active, adopted after a
    /// relaunch, or recreated off-screen): iOS may hold those for hours. On `didBecomeActive` the
    /// ones that have not sent a byte are cancelled and recreated.
    private var createdInBackground: [String: (request: URLRequest, file: URL)] = [:]
    private var replacing: Set<String> = []

    private struct Waiter {
        let continuation: CheckedContinuation<Void, Error>
        let progress: @Sendable (Int64) -> Void
    }

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionId)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.timeoutIntervalForResource = 12 * 3600
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
    }

    /// Call once at launch so completions queued while the app was dead are delivered (journal).
    func reconnect() { _ = session }

    /// Main thread. Called by `AppDelegate.handleEventsForBackgroundURLSession`.
    func setSystemCompletion(_ handler: @escaping () -> Void) {
        if eventsFinished {
            eventsFinished = false
            handler()
        } else {
            systemCompletion = handler
        }
    }

    /// PUT `file` to `putUrl`. Joins a transfer still running for the same tag instead of starting
    /// a second one. `progress` = bytes sent, on a background queue. Task cancellation / a stall
    /// stop the WAIT only: the transfer carries on and its 2xx still lands in the journal.
    func upload(
        file: URL,
        putUrl: URL,
        contentType: String,
        tag: Tag,
        appActive: Bool,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        var request = URLRequest(url: putUrl)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let key = tag.string
        let handle = WaitHandle()
        let watchdog = Task { @MainActor [weak self] in
            var lastSent: Int64 = -1
            var idle: UInt64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, !Task.isCancelled else { return }
                let sent = self.sentBytes(key)
                if UIApplication.shared.applicationState != .active || sent != lastSent {
                    lastSent = sent
                    idle = 0
                    continue
                }
                idle += 10
                if idle >= Self.stallSeconds {
                    self.endWait(key, handle, APIError(
                        message: String(localized: "Upload failed. Please try again."),
                        statusCode: 0, code: "stalled"
                    ))
                    return
                }
            }
        }
        defer { watchdog.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                nextWaiterId += 1
                handle.id = nextWaiterId
                waiters[key, default: [:]][handle.id] = Waiter(continuation: c, progress: progress)
                lock.unlock()
                if Task.isCancelled {
                    endWait(key, handle, CancellationError())
                    return
                }
                startOrAttach(key, request: request, file: file, appActive: appActive)
            }
        } onCancel: {
            endWait(key, handle, CancellationError())
        }
    }

    /// Waiter id; written and read under `lock` (cancel handler / watchdog race the registration).
    private final class WaitHandle {
        var id = 0
    }

    private func sentBytes(_ key: String) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return sentByKey[key] ?? 0
    }

    /// Ends ONE wait with `error` (no-op if it already ended or is not registered yet).
    private func endWait(_ key: String, _ handle: WaitHandle, _ error: Error) {
        lock.lock()
        let w = waiters[key]?.removeValue(forKey: handle.id)
        if waiters[key]?.isEmpty == true { waiters[key] = nil }
        lock.unlock()
        w?.continuation.resume(throwing: error)
    }

    /// Caller holds `lock`; resume the result OUTSIDE it.
    private func takeWaiters(_ key: String) -> [Waiter] {
        waiters.removeValue(forKey: key).map { Array($0.values) } ?? []
    }

    private static func resume(_ ws: [Waiter], _ error: Error?) {
        for w in ws {
            if let error { w.continuation.resume(throwing: error) } else { w.continuation.resume() }
        }
    }

    private static let fileGone = APIError(
        message: String(localized: "No scan files found for this scan."), statusCode: 0
    )

    private func startOrAttach(_ key: String, request: URLRequest, file: URL, appActive: Bool) {
        lock.lock()
        let mine = launched[key] != nil
        lock.unlock()
        if mine { return }
        // Tasks from before a relaunch are only visible through the session.
        session.getAllTasks { [self] tasks in
            lock.lock()
            guard waiters[key]?.isEmpty == false else { lock.unlock(); return }
            if launched[key] != nil { lock.unlock(); return }
            if let old = tasks.first(where: {
                $0.taskDescription == key && ($0.state == .running || $0.state == .suspended)
            }) {
                launched[key] = old.taskIdentifier
                sentByKey[key] = old.countOfBytesSent
                // The old process may have created it off-screen (discretionary): same swap as
                // `didBecomeActive`, with today's (fresh) URL.
                let swap = appActive && old.countOfBytesSent == 0
                    && FileManager.default.fileExists(atPath: file.path)
                if swap {
                    createdInBackground[key] = (request, file)
                    replacing.insert(key)
                }
                lock.unlock()
                if swap { old.cancel() }
                return
            }
            // Finished between the caller's journal check and now (e.g. while the app was dead).
            if UploadJournal.isDone(key) {
                let ws = takeWaiters(key)
                lock.unlock()
                Self.resume(ws, nil)
                return
            }
            // `uploadTask(fromFile:)` on a missing file: fail here, never hand it to the session.
            guard FileManager.default.fileExists(atPath: file.path) else {
                let ws = takeWaiters(key)
                lock.unlock()
                Self.resume(ws, Self.fileGone)
                return
            }
            let task = session.uploadTask(with: request, fromFile: file)
            task.taskDescription = key
            launched[key] = task.taskIdentifier
            sentByKey[key] = 0
            if !appActive { createdInBackground[key] = (request, file) }
            lock.unlock()
            task.resume()
        }
    }

    @objc private func didBecomeActive() {
        // A flag left by a foreground drain must not short-cut the next background wake.
        eventsFinished = false
        lock.lock()
        let keys = Set(createdInBackground.keys)
        lock.unlock()
        guard !keys.isEmpty else { return }
        session.getAllTasks { [self] tasks in
            for task in tasks {
                guard let key = task.taskDescription, keys.contains(key),
                      task.state == .running || task.state == .suspended else { continue }
                lock.lock()
                let tracked = launched[key] == task.taskIdentifier
                if tracked, task.countOfBytesSent == 0, createdInBackground[key] != nil {
                    replacing.insert(key)
                    lock.unlock()
                    task.cancel()
                } else {
                    if tracked { createdInBackground[key] = nil }
                    lock.unlock()
                }
            }
        }
    }
}

extension BackgroundUploads: URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard let key = task.taskDescription else { return }
        lock.lock()
        guard launched[key] == task.taskIdentifier else { lock.unlock(); return }
        sentByKey[key] = totalBytesSent
        let ws = waiters[key].map { Array($0.values) } ?? []
        lock.unlock()
        ws.forEach { $0.progress(totalBytesSent) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription else { return }
        // Woken in the background: give the waiting flow time to reach /complete. On main, so
        // the expiration handler cannot run before the id is stored.
        DispatchQueue.main.async { MainActor.assumeIsolated { UploadKeepAlive.shared.renew() } }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let ok = error == nil && (200...299).contains(status)

        lock.lock()
        if ok { UploadJournal.markDone(key) }
        guard launched[key] == task.taskIdentifier else {
            // Stale transfer of this tag (e.g. delivered after a relaunch while a newer one runs):
            // its 2xx still means the file is on R2; its failure means nothing.
            let ws = ok ? takeWaiters(key) : []
            lock.unlock()
            Self.resume(ws, nil)
            return
        }
        launched[key] = nil
        sentByKey[key] = nil
        if replacing.remove(key) != nil, (error as? URLError)?.code == .cancelled,
           let redo = createdInBackground[key],
           FileManager.default.fileExists(atPath: redo.file.path) {
            // Swapped for a copy created now — the waiters keep waiting. Stays in
            // `createdInBackground`: if the app left the screen meanwhile, the next activation
            // swaps it again (only while it has sent nothing).
            let fresh = session.uploadTask(with: redo.request, fromFile: redo.file)
            fresh.taskDescription = key
            launched[key] = fresh.taskIdentifier
            sentByKey[key] = 0
            lock.unlock()
            fresh.resume()
            return
        }
        createdInBackground[key] = nil
        let ws = takeWaiters(key)
        lock.unlock()

        let result: Error? = ok ? nil : (error ?? APIError(
            message: String(localized: "Upload failed. Please try again."),
            statusCode: status
        ))
        Self.resume(ws, result)
    }
}

extension BackgroundUploads: URLSessionDelegate {
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [self] in
            guard let done = systemCompletion else {
                eventsFinished = true
                return
            }
            systemCompletion = nil
            done()
        }
    }
}

extension BackgroundUploads {
    /// `taskDescription` of a transfer: which record, which server scan, which file, which size.
    /// The size makes a re-saved file (different bytes) a different transfer.
    struct Tag {
        let recordId: UUID
        let scanId: String
        let kind: String
        let size: Int64

        var string: String { "v1|\(recordId.uuidString)|\(scanId)|\(kind)|\(size)" }

        init(recordId: UUID, scanId: String, kind: String, size: Int64) {
            self.recordId = recordId
            self.scanId = scanId
            self.kind = kind
            self.size = size
        }

        init?(_ s: String) {
            let p = s.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard p.count == 5, p[0] == "v1", let id = UUID(uuidString: p[1]), let size = Int64(p[4]) else { return nil }
            self.init(recordId: id, scanId: p[2], kind: p[3], size: size)
        }
    }
}

/// Which files of a scan already reached R2, per local record. One entry = one server scan id not
/// yet `/complete`d by the app. UserDefaults: thread-safe, and it survives the app being killed.
/// Cleared by `ScanUploader` once `/complete` answers (then `cloudScanId` is the guard, trap #20b).
enum UploadJournal {
    private static let key = "scanUploadJournal.v1"
    private static let lock = NSLock()

    struct Entry: Codable {
        var scanId: String
        var kinds: [String]
        /// kind → file size that reached R2.
        var done: [String: Int64]
        var updated: Date
    }

    static func entry(for recordId: UUID) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return load()[recordId.uuidString]
    }

    static func start(_ recordId: UUID, scanId: String, kinds: [String]) {
        lock.lock(); defer { lock.unlock() }
        var all = load()
        all[recordId.uuidString] = Entry(scanId: scanId, kinds: kinds, done: [:], updated: Date())
        save(all)
    }

    static func clear(_ recordId: UUID) {
        lock.lock(); defer { lock.unlock() }
        var all = load()
        all[recordId.uuidString] = nil
        save(all)
    }

    static func markDone(_ tagString: String) {
        guard let tag = BackgroundUploads.Tag(tagString) else { return }
        lock.lock(); defer { lock.unlock() }
        var all = load()
        guard var e = all[tag.recordId.uuidString], e.scanId == tag.scanId else { return }
        e.done[tag.kind] = tag.size
        e.updated = Date()
        all[tag.recordId.uuidString] = e
        save(all)
    }

    static func isDone(_ tagString: String) -> Bool {
        guard let tag = BackgroundUploads.Tag(tagString) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let e = load()[tag.recordId.uuidString], e.scanId == tag.scanId else { return false }
        return e.done[tag.kind] == tag.size
    }

    private static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let all = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return all
    }

    private static func save(_ all: [String: Entry]) {
        // A server scan left pending for 30 days is not worth resuming (and bounds the store).
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        let kept = all.filter { $0.value.updated > cutoff }
        if let data = try? JSONEncoder().encode(kept) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// While an upload/order flow runs: screen stays awake in the foreground, and the app holds
/// background time (renewed when a transfer completes in the background, and right before the
/// order call) so the flow can finish. Ref-counted: nested flows (OrderSheet → ScanUploader)
/// share it. MAIN THREAD only. 🔴 Every `begin()` needs its `end()` on EVERY exit — use `defer`.
@MainActor
final class UploadKeepAlive {
    static let shared = UploadKeepAlive()

    private var holders = 0
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var savedIdleTimer = false

    func begin() {
        holders += 1
        if holders == 1 {
            savedIdleTimer = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        }
        renew()
    }

    func end() {
        holders = max(0, holders - 1)
        guard holders == 0 else { return }
        UIApplication.shared.isIdleTimerDisabled = savedIdleTimer
        expire()
    }

    /// No-op when nobody holds it or background time is already held. One is held at a time and
    /// an ended one never expires ⇒ the expiration handler ends the held one.
    func renew() {
        guard holders > 0, bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "scan-upload") {
            MainActor.assumeIsolated { UploadKeepAlive.shared.expire() }
        }
    }

    private func expire() {
        let id = bgTask
        bgTask = .invalid
        if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
    }

    /// Returns once the app is on screen. The step that takes money (or stamps an order) runs
    /// in the foreground: a request cut by suspension after the server acted = half-state (#26).
    static func untilActive() async {
        while UIApplication.shared.applicationState != .active {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}
