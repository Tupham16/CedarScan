import Foundation

/// Tải file USDZ có texture (do MÁY TRẠM bake) về máy để `USDZPreview` mở bằng QuickLook.
///
/// 🔴 Vì sao phải tải về: `QLPreviewController` chỉ mở FILE CỤC BỘ — đưa URL https vào là màn
/// xem trắng trơn, không lỗi, không log. Đuôi phải là `.usdz` để QuickLook chọn đúng renderer.
///
/// 🔴 Cache nằm ở `.cachesDirectory`, ✗ trong thư mục bản quét:
/// · thư mục bản quét bị `purgeDelivered` xoá TRỌN sau khi đơn được giao;
/// · file này dựng lại được từ R2 nên không đáng để iCloud backup;
/// · caches là chỗ DUY NHẤT iOS được phép tự dọn khi máy hết chỗ (thay vì kill app).
///
/// Đây là chỗ DUY NHẤT trong app tải file về đĩa (mọi URLSession khác là JSON hoặc PUT lên).
@MainActor
final class TexturedModelCache: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// File đã nằm trên đĩa, sẵn sàng mở. Dùng làm `item` của `.sheet(item:)`.
    @Published var readyURL: URL?

    /// Giữ tối đa bấy nhiêu file trong cache. Mỗi file 30–80MB nên không thể để lớn vô hạn;
    /// 3 là đủ cho ca thường gặp nhất (nhà 2–3 tầng, khách xem lần lượt từng tầng).
    private static let keepFiles = 3

    /// Lượt tải ĐANG CHẠY, dùng chung giữa các lần vào/ra màn — khoá theo TÊN FILE ĐÍCH.
    /// 🔴 Vì sao static: `@StateObject` chết khi khách pop về danh sách bản quét, nhưng lượt
    /// tải thì không (cố ý — xem `cancel()`). Không có sổ dùng chung này thì vào lại màn là
    /// `task == nil` → bấm Xem lần nữa = TẢI LẠI cả 75MB lần thứ hai trên 4G, mà lượt đầu
    /// vẫn đang chạy. Chỉ đụng trên main (cả class là @MainActor) nên không cần lock.
    private static var inFlight: [String: Task<DownloadResult, Never>] = [:]

    private var task: Task<Void, Never>?
    /// Khoá của lượt tải instance này đang theo dõi — để `cancel()` gỡ đúng entry.
    private var inFlightKey: String?
    /// Số thứ tự lượt tải. Lượt bị HỦY vẫn chạy tiếp tới chỗ `await` rồi mới thoát, nên nếu
    /// khách bấm Hủy → bấm lại ngay thì phần đuôi của lượt CŨ sẽ chạy SAU khi lượt mới đã bắt
    /// đầu: nó xoá `task` của lượt mới (làm mất luôn nút Hủy) và ghi `phase` cũ đè lên
    /// `.downloading`. So `generation` để phần đuôi của lượt cũ tự im.
    private var generation = 0

    private static var dir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TexturedModels", isDirectory: true)
    }

    /// Băm ỔN ĐỊNH GIỮA CÁC LẦN CHẠY (djb2) cho phần version của tên file.
    /// 🔴 ✗ dùng `hashValue`/`Hasher` của Swift: chúng được gieo NGẪU NHIÊN mỗi lần khởi động
    /// process → tên file đổi sau mỗi lần mở app, cache không bao giờ trúng, tải lại 75MB.
    private static func stableHash(_ s: String) -> String {
        var h: UInt64 = 5381
        for b in s.utf8 {
            h = (h &* 33) &+ UInt64(b)
        }
        return String(h % 0xFFFF_FFFF, radix: 16)
    }

    private static func safeId(_ scanId: String) -> String {
        let safe = scanId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return safe.isEmpty ? "scan" : safe
    }

    /// Đường dẫn cache cho ĐÚNG một URL. Tên mang cả băm của URL vì máy trạm có thể BAKE LẠI:
    /// server đổi `?v=<ms>` trong link, mà nếu tên file chỉ theo scanId thì `existing()` trả
    /// bản CŨ và khách xem mô hình cũ VĨNH VIỄN — sai kiểu im lặng, không ai báo.
    /// Đuôi PHẢI là `.usdz` (QuickLook chọn renderer theo đuôi file cục bộ, không theo URL gốc).
    static func cachedURL(scanId: String, remote: URL) -> URL {
        dir.appendingPathComponent(
            "\(safeId(scanId))-\(stableHash(remote.absoluteString)).usdz"
        )
    }

    /// File của ĐÚNG bản bake này đã có trên đĩa chưa (không đụng mạng).
    static func existing(scanId: String, remote: URL) -> URL? {
        nonEmpty(cachedURL(scanId: scanId, remote: remote))
    }

    /// BẤT KỲ bản đã tải của bản quét này — dùng khi CHƯA hỏi được server (mất mạng): thà cho
    /// khách xem bản đã tải còn hơn không cho xem gì. Lấy bản mới nhất.
    static func anyCached(scanId: String) -> URL? {
        let prefix = safeId(scanId) + "-"
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        return items
            .filter { $0.pathExtension == "usdz" && $0.lastPathComponent.hasPrefix(prefix) }
            .compactMap(nonEmpty)
            .max { a, b in modified(a) < modified(b) }
    }

    private static func nonEmpty(_ url: URL) -> URL? {
        // Đòi file KHÁC RỖNG: lượt tải trước bị giết giữa đường có thể để lại file 0 byte,
        // QuickLook mở ra là màn trắng và khách không có cách nào thử lại.
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > 0 else { return nil }
        return url
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    /// Tải (hoặc dùng lại bản đã cache) rồi gán `readyURL`.
    /// Gọi lại khi đang tải = KHÔNG LÀM GÌ (chống bấm hai lần ra hai lượt tải 75MB).
    func open(scanId: String, remote: URL) {
        // File cục bộ (đường "mất mạng" của loadTexturedURL trỏ thẳng vào cache) → mở luôn,
        // nhưng vẫn qua cửa `nonEmpty`: file 0 byte mở ra là màn TRẮNG, y như mọi đường khác.
        if remote.isFileURL {
            phase = .idle
            if let ok = Self.nonEmpty(remote) {
                readyURL = ok
            } else {
                // Câu chữ này ĐI THẲNG vào dòng lỗi khách đọc → phải qua L.t. Khách của
                // Cedar247 là người nước ngoài, nhánh tiếng Anh MỚI là nhánh thường.
                phase = .failed(L.t("cached file is empty", "file cache rỗng"))
            }
            return
        }
        if let cached = Self.existing(scanId: scanId, remote: remote) {
            phase = .idle
            readyURL = cached
            return
        }
        guard task == nil else { return }
        phase = .downloading
        generation += 1
        let mine = generation
        // Bám vào lượt đang chạy nếu có (khách vừa ra vào lại màn giữa lúc tải), ✗ mở lượt mới.
        let key = Self.cachedURL(scanId: scanId, remote: remote).lastPathComponent
        inFlightKey = key
        let download: Task<DownloadResult, Never>
        if let running = Self.inFlight[key] {
            download = running
        } else {
            // `Task {}` mở trong ngữ cảnh @MainActor thì THỪA HƯỞNG actor đó — không cần
            // gắn nhãn lại, và nhờ vậy việc sửa `Self.inFlight` ở đây là an toàn.
            download = Task {
                let r = await Self.download(scanId: scanId, remote: remote)
                Self.inFlight[key] = nil
                return r
            }
            Self.inFlight[key] = download
        }
        task = Task { [weak self] in
            let result = await download.value
            guard let self, self.generation == mine else { return }
            self.task = nil
            self.inFlightKey = nil
            switch result {
            case .success(let url):
                self.phase = .idle
                self.readyURL = url
            // Bị huỷ (khách bấm Hủy, hoặc màn khác đang bám cùng lượt tải bấm Hủy) → về
            // idle, ✗ hiện dòng lỗi đỏ cho việc chính họ vừa làm.
            case .cancelled:
                self.phase = .idle
            case .failure(let message):
                self.phase = .failed(message)
            }
        }
    }

    /// Hủy lượt tải hiện tại. ⚠ Chỉ hủy khi NGƯỜI DÙNG bấm Hủy — cố ý KHÔNG gọi ở
    /// `onDisappear`: rời màn một nhịp (sang tab Đơn hàng rồi quay lại) mà giết lượt tải là
    /// khách phải tải lại từ đầu 30–75MB. Lượt đang chạy cứ để nó ghi xong vào cache; view
    /// chết thì `[weak self]` làm phần đuôi tự im.
    func cancel() {
        // Hủy CẢ lượt dùng chung: khách bấm Hủy là muốn NGỪNG TỐN DATA, không phải chỉ ẩn
        // thanh chờ. Gỡ khỏi sổ luôn để lần bấm sau mở lượt mới thay vì bám vào lượt đã hủy.
        if let key = inFlightKey {
            Self.inFlight[key]?.cancel()
            Self.inFlight[key] = nil
            inFlightKey = nil
        }
        task?.cancel()
        task = nil
        generation += 1 // phần đuôi của lượt vừa hủy không được ghi gì nữa
        phase = .idle
    }

    private enum DownloadResult {
        case success(URL)
        /// Bị hủy — TÁCH khỏi failure vì nó KHÔNG phải lỗi: lượt tải dùng chung có thể bị màn
        /// khác hủy, lúc đó `Task.isCancelled` của bên quan sát là false nên không tách ra thì
        /// khách nhận một dòng lỗi đỏ ghi "cancelled" (chưa dịch) cho việc mình vừa bấm.
        case cancelled
        case failure(String)
    }

    private static func download(scanId: String, remote: URL) async -> DownloadResult {
        let dest = cachedURL(scanId: scanId, remote: remote)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // `download(for:)` ghi thẳng ra file tạm (KHÔNG nạp 75MB vào RAM như `data(for:)`)
            // và nó CÓ tôn trọng Task.cancel — khác đường upload của app.
            var request = URLRequest(url: remote)
            request.timeoutInterval = 600 // 4G chậm: 75MB có thể mất nhiều phút
            let (tmp, response) = try await URLSession.shared.download(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                try? FileManager.default.removeItem(at: tmp)
                return .failure("HTTP \(http.statusCode)")
            }
            // Thay file cũ NGUYÊN TỬ-ish: xoá rồi move. Nếu move hỏng thì không để lại file
            // rỗng ở đích (existing() đòi size > 0 nên lượt sau vẫn tải lại được).
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            prune(scanId: scanId, keeping: dest)
            return .success(dest)
        } catch {
            if Task.isCancelled { return .cancelled }
            return .failure(error.localizedDescription)
        }
    }

    /// Dọn cache sau khi tải xong: (1) xoá MỌI bản CŨ CỦA CHÍNH bản quét này — sau một lượt
    /// bake lại thì bản cũ chắc chắn vô dụng, để nó lại là ăn mất suất trong ngân sách 3 file;
    /// (2) giữ tổng cộng `keepFiles` file mới nhất. File vừa tải LUÔN được giữ.
    private static func prune(scanId: String, keeping justWritten: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        // So bằng TÊN FILE, ✗ so hai URL: `contentsOfDirectory` trả URL đã phân giải
        // (/private/var/…) còn `justWritten` do mình ghép tay (/var/…) — so URL là không khớp
        // và file VỪA TẢI XONG bị tính vào diện xoá.
        let keepName = justWritten.lastPathComponent
        let others = items.filter { $0.pathExtension == "usdz" && $0.lastPathComponent != keepName }
        let samePrefix = safeId(scanId) + "-"
        var rest: [URL] = []
        for url in others {
            if url.lastPathComponent.hasPrefix(samePrefix) {
                try? fm.removeItem(at: url) // bản bake CŨ của đúng bản quét này
            } else {
                rest.append(url)
            }
        }
        for old in rest.sorted(by: { modified($0) > modified($1) }).dropFirst(max(0, keepFiles - 1)) {
            try? fm.removeItem(at: old)
        }
    }
}
