import Foundation
import UIKit

/// Điều phối việc gửi 1 bản quét lên server Cedar247:
/// tạo scan → PUT từng file lên R2 (có tiến độ) → báo hoàn tất.
///
/// 2.59: PUTs run on `BackgroundUploads` (background URLSession) — they survive screen lock, app
/// switch and the app being killed. All files are queued at once, while the app is on screen
/// (a transfer created in the background is discretionary). A retry / a later tap RESUMES: the
/// server scan id and the files already on R2 come from `UploadJournal`, expired URLs are
/// re-presigned (`presignScanUploads`), only missing files go up. `/complete` still runs only once
/// EVERY present file has a 2xx — the ordering guarantee of the callers is unchanged.
@MainActor
final class ScanUploader: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case uploading(fileName: String, index: Int, total: Int, fraction: Double)
        case finishing
        case done
        case failed(String)
    }

    @Published var phase: Phase = .idle
    /// Bytes on R2 so far and this scan's total, at every progress publish (2.79.5: OrderSheet
    /// sums the scans of one Place order for its percent and time left).
    var onBytes: (@MainActor (_ sent: Int64, _ total: Int64) -> Void)?

    /// 🔴 Ba loại của RoomPlan/video đã BỎ 11/08 (bản 2.5): `usdz`/`model.usdz`,
    /// `plan`/`floorplan.png`, `rooms`/`rooms.json`. Luồng mesh KHÔNG BAO GIỜ sinh ba file đó, mà
    /// `present` bên dưới đã lọc theo `fileExists` — nên bỏ chúng khỏi danh sách là **no-op với
    /// mọi bản quét đang tạo được**, ✗ đổi hợp đồng app↔server (server vẫn nhận `kinds` bất kỳ).
    /// ⚠ Bản quét CŨ trên máy có `model.usdz`/`floorplan.png` thì nay ba file đó KHÔNG được gửi
    /// lên nữa. Chấp nhận có chủ đích: đội vẽ đọc mesh trong `objzip`, và chủ app là người duy
    /// nhất còn giữ bản quét đời RoomPlan.
    static let fileKinds: [(kind: String, fileName: String)] = [
        ("obj", "model.obj"),
        ("mtl", "model.mtl"),
        ("mesh", "colored-mesh.ply"),
        ("objzip", "model-colored.zip"),   // mô hình màu OBJ+MTL đã nén
        ("video", "scan-video.mp4"),
    ]

    /// Attempts per file for a transient failure (network, 5xx, expired URL).
    private static let maxAttempts = 4

    private struct FileJob {
        let kind: String
        let url: URL
        let size: Int64
    }

    private var sentBytes: [String: Int64] = [:]
    /// Kinds with a 2xx: late progress callbacks of their transfer are ignored.
    private var finished: Set<String> = []
    private var totalBytes: Int64 = 1
    private var filesDone = 0
    private var filesTotal = 0
    private var lastFraction = -1.0

    /// Trả về cloudScanId khi thành công, nil khi thất bại (phase = .failed).
    func upload(record: ScanRecord, folder: URL) async -> String? {
        phase = .preparing
        // Screen awake + background time for the whole run, released on EVERY exit.
        UploadKeepAlive.shared.begin()
        defer { UploadKeepAlive.shared.end() }
        let fm = FileManager.default

        var present = Self.fileKinds.filter { fm.fileExists(atPath: folder.appendingPathComponent($0.fileName).path) }
        // 2.78 (L1): the save moves the PLY into the folder before zipping and deletes it once
        // model-colored.zip is in — killed in between, both stay. The zip holds that same mesh
        // plus the texture shots: it goes alone. (Before 2.78 the PLY reached the folder only
        // after the zip had failed and been deleted, so no older scan has both.)
        if present.contains(where: { $0.kind == "objzip" }) {
            present.removeAll { $0.kind == "mesh" }
        }
        // Bản quét mesh có thể chỉ có model-colored.zip (objzip) hoặc PLY phao (video recorder
        // fail lặng lẽ vẫn upload được) — nên chấp nhận bất kỳ cái nào trong bốn.
        // (Vế `$0.kind == "usdz"` bỏ cùng RoomPlan 11/08.)
        guard present.contains(where: {
            $0.kind == "obj" || $0.kind == "video" || $0.kind == "mesh" || $0.kind == "objzip"
        }) else {
            phase = .failed(String(localized: "No scan files found for this scan."))
            return nil
        }
        let jobs = present.map { file -> FileJob in
            let url = folder.appendingPathComponent(file.fileName)
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            return FileJob(kind: file.kind, url: url, size: size)
        }

        do {
            return try await run(record: record, folder: folder, jobs: jobs, allowFresh: true)
        } catch {
            phase = .failed(error.localizedDescription)
            return nil
        }
    }

    private func run(record: ScanRecord, folder: URL, jobs: [FileJob], allowFresh: Bool) async throws -> String {
        phase = .preparing
        let kinds = jobs.map(\.kind)
        let scanId: String
        var slots: [String: UploadSlot] = [:]
        // Resume only the same set of files; anything else = a fresh server scan.
        if let entry = UploadJournal.entry(for: record.id), Set(entry.kinds) == Set(kinds) {
            scanId = entry.scanId
        } else {
            let created = try await createScan(record: record, folder: folder, kinds: kinds)
            scanId = created.scanId
            UploadJournal.start(record.id, scanId: scanId, kinds: kinds)
            slots = Dictionary(uniqueKeysWithValues: created.uploads.map { ($0.kind, $0) })
        }

        let done = UploadJournal.entry(for: record.id)?.done ?? [:]
        let todo = jobs.filter { done[$0.kind] != $0.size }
        do {
            if todo.contains(where: { slots[$0.kind] == nil }) {
                let fresh = try await apiRetry {
                    try await APIClient.shared.presignScanUploads(scanId: scanId, kinds: todo.map(\.kind))
                }
                for slot in fresh.uploads { slots[slot.kind] = slot }
            }
            try await sendAll(record: record, scanId: scanId, jobs: jobs, todo: todo, slots: slots)
            phase = .finishing
            _ = try await apiRetry { try await APIClient.shared.completeScan(scanId: scanId) }
        } catch let error as APIError where allowFresh && error.statusCode == 404 {
            // Journal points at a scan this account cannot see (signed in with another account):
            // start over ONCE with a new server scan. 🔴 ✗ on 409 `scan_ordered`: that scan is
            // already in an order — a new scan id for the same house = a second order (#20b).
            UploadJournal.clear(record.id)
            return try await run(record: record, folder: folder, jobs: jobs, allowFresh: false)
        }
        UploadJournal.clear(record.id)
        phase = .done
        return scanId
    }

    private func createScan(record: ScanRecord, folder: URL, kinds: [String]) async throws -> CreateScanResponse {
        // Báo cáo chất lượng (nếu có) gửi kèm ngay lúc tạo scan — đội vẽ thấy trên Kanban
        var quality: [String: Any]?
        if let data = try? Data(contentsOf: folder.appendingPathComponent("quality.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            quality = obj
        }
        return try await APIClient.shared.createScan(
            name: record.name,
            roomCount: record.roomCount,
            areaSqm: record.areaSqm ?? 0,
            kinds: kinds,
            // 🔴 CẮM CỨNG "mesh", ✗ đọc `ScanRecord` nữa: trường `captureType` đã xoá khỏi
            // model 11/08 cùng RoomPlan (lý do đầy đủ ở cuối `ScanRecord.swift`). Đây là
            // trường của HỢP ĐỒNG app↔server nên VẪN PHẢI GỬI — bỏ nó là đổi hợp đồng, phải
            // đi đường "SERVER TRƯỚC". Mọi bản quét app tạo ra từ 2026-07-20 đều là "mesh".
            captureType: "mesh",
            quality: quality
        )
    }

    /// Every file of `todo` at once (queued while on screen), each with its own retries.
    /// Throws the first failure; the other transfers keep going and land in the journal.
    private func sendAll(
        record: ScanRecord, scanId: String, jobs: [FileJob], todo: [FileJob], slots: [String: UploadSlot]
    ) async throws {
        totalBytes = max(1, jobs.reduce(0) { $0 + $1.size })
        sentBytes = Dictionary(uniqueKeysWithValues: jobs.map { job in
            (job.kind, todo.contains { $0.kind == job.kind } ? 0 : job.size)
        })
        filesTotal = jobs.count
        filesDone = jobs.count - todo.count
        finished = Set(jobs.map(\.kind)).subtracting(todo.map(\.kind))
        lastFraction = -1
        publishProgress()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for job in todo {
                guard let slot = slots[job.kind] else {
                    throw APIError(message: String(localized: "Upload failed. Please try again."), statusCode: 0)
                }
                group.addTask { @MainActor in
                    try await self.send(job, slot: slot, record: record, scanId: scanId)
                }
            }
            try await group.waitForAll()
        }
    }

    private func send(_ job: FileJob, slot first: UploadSlot, record: ScanRecord, scanId: String) async throws {
        var slot = first
        var attempt = 0
        var represigned = false
        let tag = BackgroundUploads.Tag(recordId: record.id, scanId: scanId, kind: job.kind, size: job.size)
        while true {
            attempt += 1
            do {
                guard let putUrl = URL(string: slot.putUrl) else {
                    throw APIError(message: String(localized: "Invalid upload URL"), statusCode: 0)
                }
                try await BackgroundUploads.shared.upload(
                    file: job.url,
                    putUrl: putUrl,
                    contentType: slot.contentType,
                    tag: tag,
                    appActive: UIApplication.shared.applicationState == .active
                ) { [weak self, kind = job.kind] sent in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.noteSent(kind, sent) }
                    }
                }
                sentBytes[job.kind] = job.size
                finished.insert(job.kind)
                filesDone += 1
                publishProgress()
                return
            } catch {
                let status = (error as? APIError)?.statusCode ?? 0
                // R2 answers an expired / stale signature with 403 (400 for some malformed ones):
                // one fresh URL, then give up — a 403 that survives re-presign is not transient.
                let expired = (status == 403 || status == 400) && !represigned
                guard attempt < Self.maxAttempts, expired || Self.isTransient(error) else { throw error }
                // The file starts again from 0 — only on a retry (2.79.5: a give-up / Cancel no
                // longer flashes a lower percent on Place order just before the error).
                sentBytes[job.kind] = 0
                publishProgress()
                try await Task.sleep(nanoseconds: UInt64(min(attempt * attempt, 9)) * 2_000_000_000)
                if expired || attempt >= 2 {
                    // A retry after a pause may outlive a 1 h URL: re-presign rather than guess.
                    let fresh = try await apiRetry {
                        try await APIClient.shared.presignScanUploads(scanId: scanId, kinds: [job.kind])
                    }
                    guard let s = fresh.uploads.first(where: { $0.kind == job.kind }) else { throw error }
                    slot = s
                    if expired { represigned = true }
                }
            }
        }
    }

    /// A plain API call (presign, /complete) under the same transient-retry rule. A retry waits
    /// for the app to be on screen: a request cut by suspension fails when the app resumes.
    private func apiRetry<T>(_ call: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await call()
            } catch {
                guard attempt < Self.maxAttempts, Self.isTransient(error) else { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                await UploadKeepAlive.untilActive()
                try Task.checkCancellation()
            }
        }
    }

    private static func isTransient(_ error: Error) -> Bool {
        if let e = error as? URLError {
            switch e.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed, .internationalRoamingOff,
                 .callIsActive, .dataNotAllowed, .backgroundSessionWasDisconnected, .resourceUnavailable:
                return true
            default:
                return false
            }
        }
        if let e = error as? APIError {
            return e.statusCode == 408 || e.statusCode == 429 || (500...599).contains(e.statusCode)
        }
        return false
    }

    private func noteSent(_ kind: String, _ sent: Int64) {
        guard case .uploading = phase, sentBytes[kind] != nil, !finished.contains(kind) else { return }
        sentBytes[kind] = sent
        publishProgress()
    }

    /// Whole-scan progress (files run in parallel). Throttled to 0.5 % steps: each publish
    /// redraws the scan screen.
    private func publishProgress() {
        switch phase {
        case .preparing, .uploading: break
        default: return
        }
        let sent = sentBytes.values.reduce(0, +)
        let fraction = min(1, Double(sent) / Double(totalBytes))
        guard abs(fraction - lastFraction) >= 0.005 || fraction >= 1 || lastFraction < 0 else { return }
        lastFraction = fraction
        phase = .uploading(
            fileName: "",
            index: min(filesDone + 1, filesTotal),
            total: filesTotal,
            fraction: fraction
        )
        onBytes?(sent, totalBytes)
    }
}

/// The scans one tap uploads at once (2.79.5, owner 05/11): percent over all of them by bytes and
/// the time left from their real speed. Place order (`OrderSheet`) and Send extra scan
/// (`SupplementSheet`) keep one in @State while uploading, fed by each `ScanUploader.onBytes`.
struct UploadProgress {
    private var bytes: [UUID: (sent: Int64, total: Int64)]
    /// (time, bytes sent over all scans) of the last 30 s.
    private var samples: [(at: TimeInterval, sent: Int64)] = []

    /// Every scan at 0 of an unknown total until its uploader reports.
    init(_ scans: [UUID]) {
        bytes = Dictionary(scans.map { ($0, (sent: Int64(0), total: Int64(0))) }) { a, _ in a }
    }

    /// 0…1; 0 until every scan has its total, so the percent never drops when a second floor starts.
    var fraction: Double {
        guard let total = knownTotal else { return 0 }
        return min(1, Double(sentAll) / Double(total))
    }

    /// "About N min left. " + `keep`, the time from the real speed of the last 30 s (a fixed
    /// "1–2 minutes" is wrong on a slow link); `keep` alone before 5 s of it.
    /// shortcut: no clock — a dead link freezes the line with the bar until the stall watchdog
    /// (BackgroundUploads, 60 s) fails the batch; add a TimelineView if that shows up in tests.
    func line(keep: String) -> String {
        guard let total = knownTotal, let first = samples.first, let last = samples.last,
              last.at - first.at >= 5, last.sent > first.sent else { return keep }
        let speed = Double(last.sent - first.sent) / (last.at - first.at)
        let seconds = Double(max(0, total - last.sent)) / speed
        if seconds < 60 {
            return String(localized: "Less than a minute left.") + " " + keep
        }
        let minutes = Int((seconds / 60).rounded())
        return String(localized: "About \(minutes) min left.") + " " + keep
    }

    /// One scan's `ScanUploader.onBytes`.
    mutating func note(_ id: UUID, sent: Int64, total: Int64) {
        let before = bytes[id]?.sent ?? 0
        bytes[id] = (sent, total)
        let now = Date().timeIntervalSinceReferenceDate
        // A retry back to 0, a re-joined transfer or a resumed floor's done files: not speed.
        if sent < before || Double(sent - before) > 0.02 * Double(total) {
            samples = []
        }
        samples.removeAll { now - $0.at > 30 }
        samples.append((now, sentAll))
    }

    private var sentAll: Int64 { bytes.values.reduce(0) { $0 + $1.sent } }

    /// nil while any scan's total is unknown (or there is nothing to send).
    private var knownTotal: Int64? {
        guard !bytes.values.contains(where: { $0.total <= 0 }) else { return nil }
        let total = bytes.values.reduce(Int64(0)) { $0 + $1.total }
        return total > 0 ? total : nil
    }
}
