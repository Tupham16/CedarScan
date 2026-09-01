import SwiftUI

/// **GỬI BỔ SUNG BẢN QUÉT vào đơn ĐÃ ĐẶT** — chủ app đề xuất 11/08, server đã lên prod cùng ngày
/// (`order-webapp/HANDOFF.md` §7e).
///
/// VẤN ĐỀ THẬT (✗ "cho tiện"): khách đặt hàng xong mới phát hiện quét thiếu. Trước đây đường duy
/// nhất là bấm Share rồi **email** gói mesh cho chủ app — **vỡ ở mốc 25MB của email trong khi gói
/// mesh 40–200MB**. Ca này ĐÃ XẢY RA THẬT (chủ app xác nhận "có rồi").
///
/// 🔴 **KHÔNG THU TIỀN.** Sheet này cố ý KHÔNG có bảng giá, KHÔNG có link thanh toán, KHÔNG chạm
/// `catalog()`. Giá hiện tính **PHẲNG THEO ĐƠN** (không số hạng nào theo số bản quét) nên bổ sung
/// miễn phí không mở lỗ nào — xem §HỆ QUẢ TIỀN của `PLAN-GUI-BO-SUNG-BAN-QUET.md`. Ai định thêm
/// form giá vào đây là đang làm ngược lại quyết định của chủ app.
///
/// 🔴 **LỐI VÀO DUY NHẤT của việc gửi bổ sung** — cả ba màn (`ProjectView`, `ScanDetailView`, màn
/// preview sau khi quét) đều present sheet NÀY. ✗ gõ lại luồng ở màn khác: repo này đã trả giá
/// nhiều lần vì hai màn song sinh trôi khỏi nhau, và ở đây thứ trôi được là cú **đóng dấu số
/// đơn** — thiếu nó thì khách bấm đặt lại và **TRẢ TIỀN HAI LẦN**.
struct SupplementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ScanStore

    /// Bản quét muốn gửi. 🔴 Chỉ giữ `[UUID]` ở call site (`SupplementTarget`) rồi giải sống —
    /// chụp `[ScanRecord]` là đóng băng `cloudScanId`, guard DUY NHẤT chống tải lên lại (bẫy #20b).
    let records: [ScanRecord]
    /// Số đơn của dự án, lấy từ `ScanStore.orderNumber(ofProject:)` — nguồn DUY NHẤT.
    let orderNumber: String

    private enum Phase: Equatable {
        case ready
        case working(String)
        /// Đơn đã giao → đây là "Yêu cầu sửa", ✗ luồng này (chủ app chốt).
        case delivered(String)
        case failed(String)
        case sent(Int)
    }

    @State private var phase: Phase = .ready
    @State private var task: Task<Void, Never>?
    /// Đơn đã giao: GIỮ để mở `RevisionSheet` khi khách bấm nút — 🔴 KHÔNG bind thẳng vào
    /// `.sheet(item:)`, gán nó là sheet tự bật NGAY lúc server trả lỗi, tức khách chưa kịp đọc
    /// câu giải thích "đơn đã giao" đã bị ném vào một form khác.
    @State private var deliveredOrder: OrderDTO?
    /// Chỉ gán khi khách BẤM nút → đây mới là thứ present sheet.
    @State private var revisionTarget: OrderDTO?
    /// Câu dặn thêm cho ca đơn ĐÃ GIAO — `nil` với đơn thường. Chụp từ phản hồi của server
    /// (`wasDelivered`/`movedToFix`), ✗ tự đoán trạng thái đơn ở phía app: app chỉ biết trạng
    /// thái qua `listOrders()`, tức cần mạng và có thể cũ.
    @State private var deliveredNote: String?

    var body: some View {
        NavigationStack {
            Form { content }
                .navigationTitle(String(localized: "Send extra scan"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(String(localized: "Close")) { dismiss() }
                            .disabled(isWorking)
                    }
                }
                // 🔴 Cùng giáo lý với `OrderSheet`/`RevisionSheet` (bẫy #26): vuốt đóng giữa lúc
                // request đang bay là HALF-STATE — server đã nối bản quét vào đơn còn app chưa
                // đóng dấu số đơn, tức khách thấy "chưa đặt" và bấm đặt lần nữa.
                .interactiveDismissDisabled(isWorking)
                .sheet(item: $revisionTarget) { order in
                    RevisionSheet(order: order) {
                        // Yêu cầu sửa đã gửi → đóng luôn cả màn bổ sung. 🔴 HOÃN MỘT NHỊP: tháo
                        // sheet CHA ngay trong callback của sheet CON là đúng họ lỗi trình bày
                        // lồng nhau mà repo đã trả giá ở luồng "Quét thêm".
                        Task { @MainActor in dismiss() }
                    }
                }
        }
        .onDisappear { task?.cancel() }
    }

    private var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        Section {
            ForEach(records) { record in
                Label(record.name, systemImage: "cube.transparent")
                    .font(.subheadline)
            }
        } header: {
            Text(String(localized: "Scans to send"))
        } footer: {
            Text(String(localized: "These will be added to order \(orderNumber) — the one you already placed for this property. No extra charge."))
        }

        switch phase {
        case .ready:
            Section {
                Button {
                    send()
                } label: {
                    Label(String(localized: "Send to order \(orderNumber)"),
                          systemImage: "paperplane.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        case .working(let label):
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(label).font(.subheadline)
                }
            } footer: {
                Text(String(localized: "Keep the app open until this finishes."))
            }
        case .sent(let count):
            Section {
                Label(
                    String(localized: "Sent — \(count) scan(s) added to \(orderNumber)"),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
                Button(String(localized: "Done")) { dismiss() }
            } footer: {
                // 🔴 BA CÂU, ✗ MỘT. Đơn ĐÃ GIAO đi qua đường này từ 19/08, và khách vừa cầm bản
                // vẽ trong tay: nói đúng một câu "đội đã được báo" là để họ tưởng bản vẽ CŨ đã
                // gồm phần mới. Phải nói thẳng là sẽ có bản vẽ CẬP NHẬT gửi lại.
                // ⚠ Và phải nói cả việc link tải bản cũ tạm mất — đó là hệ quả trực tiếp của việc
                // thẻ về cột Fix (`orders/route.ts` chỉ trả `deliveryFiles` khi stage == "done").
                // Khách mở tab Đơn hàng thấy nút Tải biến mất mà không được báo trước là một cú
                // hoảng không đáng có, và là loại việc Support phải trả lời từng người.
                Text(deliveredNote ?? String(localized: "Our team has been notified so the new area goes into your drawing."))
            }
        case .delivered(let message):
            // Chủ app chốt: *"đã giao thì chỉ là yêu cầu sửa"*. SERVER là nơi phán quyết (app chỉ
            // biết trạng thái đơn qua `listOrders()`, tức cần mạng và có thể cũ) — nên nhánh này
            // chỉ chạy khi server ĐÃ nói không.
            Section {
                Text(message).font(.subheadline)
                Button {
                    openRevision()
                } label: {
                    Label(String(localized: "Request a revision"), systemImage: "arrow.uturn.backward")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                Text(String(localized: "Order already delivered"))
            }
        case .failed(let message):
            Section {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                Button(String(localized: "Try again")) { send() }
            }
        }
    }

    /// Ánh xạ SỐ ĐƠN → `orderId` (cuid) rồi gửi.
    ///
    /// 🔴 Vì sao phải ánh xạ: server khoá endpoint theo `orderId` — `Order.number` KHÔNG unique
    /// trong schema nên nó cố ý không nhận số đơn. App thì chỉ lưu `cloudOrderNumber` trong
    /// `meta.json`. Không tốn thêm gì: đằng nào cũng phải online để tải bản quét lên.
    private func send() {
        task?.cancel()
        task = Task { @MainActor in
            phase = .working(String(localized: "Finding your order…"))
            let order: OrderDTO
            do {
                let list = try await APIClient.shared.listOrders()
                guard let found = list.orders.first(where: { $0.orderNumber == orderNumber }) else {
                    phase = .failed(String(localized: "We couldn't find order \(orderNumber) on your account. Please sign in with the account that placed it."))
                    return
                }
                order = found
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
            deliveredOrder = nil

            // Tải lên bản quét CHƯA có trên server. Khuôn `OrderSheet.ensureUploaded` — 🔴 hỏi
            // STORE chứ đừng tin bản ghi truyền vào: `cloudScanId` là guard DUY NHẤT chống tải
            // lại, đọc nhầm bản chụp cũ là gửi lại 40–200MB VÀ đẻ scan id mới trên server (bẫy
            // #20b). `ensureUploaded` phải idempotent, không thì thử-lại-sau-lỗi-mạng đẻ bản sao.
            var cloudIds: [String] = []
            for record in records {
                if Task.isCancelled { phase = .ready; return }
                let live = store.records.first { $0.id == record.id } ?? record
                if let existing = live.cloudScanId {
                    cloudIds.append(existing)
                    continue
                }
                phase = .working(String(localized: "Uploading \(live.name)…"))
                let uploader = ScanUploader()
                guard let cloudId = await uploader.upload(record: live, folder: store.folderURL(for: live)) else {
                    if case .failed(let message) = uploader.phase {
                        phase = .failed("\(live.name): \(message)")
                    } else {
                        phase = .failed(String(localized: "Could not upload \(live.name)."))
                    }
                    return
                }
                store.setCloudScanId(live, cloudScanId: cloudId)
                cloudIds.append(cloudId)
            }
            guard let primary = cloudIds.first else {
                phase = .failed(String(localized: "No scan to send."))
                return
            }

            // 🔴 ĐIỂM KHÔNG QUAY ĐẦU (bẫy #26): từ đây `interactiveDismissDisabled` đã khoá vuốt
            // đóng, và ✗ kiểm `Task.isCancelled` sau cú gọi này — huỷ SAU khi server đã nối bản
            // quét là HALF-STATE (server có, app không đóng dấu → khách gửi lại mãi).
            phase = .working(String(localized: "Sending to \(orderNumber)…"))
            do {
                let result = try await APIClient.shared.supplementScan(
                    orderId: order.orderId,
                    scanId: primary,
                    extraScanIds: Array(cloudIds.dropFirst())
                )
                stamp(result)
                deliveredNote = Self.deliveredNote(for: result)
                // Đếm theo thứ SERVER xác nhận đã nằm trong đơn, ✗ theo số bản quét app gửi đi.
                phase = .sent(result.scanIds?.count ?? records.count)
            } catch let error as APIError where error.code == "order_delivered" {
                deliveredOrder = order
                phase = .delivered(error.message)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Câu dặn thêm cho đơn ĐÃ GIAO. `nil` = đơn thường, dùng câu mặc định.
    ///
    /// 🔴 Đọc `movedToFix` chứ ✗ chỉ `wasDelivered`: đơn đã giao mà thẻ đang ở "hold" thì server
    /// KHÔNG kéo thẻ về hàng sản xuất và việc phải xử lý tay — hứa "sẽ gửi lại bản vẽ cập nhật"
    /// lúc đó là hứa một thứ chưa ai cầm. Server cũ không trả hai khoá này (cả hai Optional) →
    /// `nil` → câu mặc định, đúng hành vi trước 19/08.
    private static func deliveredNote(for result: SupplementScanResponse) -> String? {
        guard result.wasDelivered == true else { return nil }
        if result.movedToFix == true {
            return String(localized: "This order was already delivered, so our team will draw the new area and send you an updated drawing — at no extra charge. While they work on it the download link for the previous drawing is temporarily unavailable.")
        }
        return String(localized: "This order was already delivered. Our team has your new scan and will be in touch — at no extra charge.")
    }

    /// Đóng dấu số đơn lên bản quét vừa gửi.
    ///
    /// 🔴 **BẮT BUỘC, VÀ LÀ VIỆC ĐẮT NHẤT CỦA MÀN NÀY.** Thiếu dấu thì bản quét vẫn hiện "chưa
    /// đặt" ở CẢ NĂM chỗ đọc trạng thái (§MULTI-ACCOUNT: `ScanDetailView.serviceCard`,
    /// `OrderSheet.otherScans`, `ProjectView.orderableScans`, `HomeView.ScanRow`,
    /// `HomeView.projectCountLine`) → khách bấm đặt lần nữa → **TRẢ TIỀN HAI LẦN**. Cùng họ bẫy
    /// #28 và #20b.
    ///
    /// Đối chiếu theo `cloudScanId` do SERVER trả về, ✗ theo thứ tự mảng: server có thể trả tập
    /// khác (nhánh idempotent gộp cả bản đã nối từ lượt trước).
    /// 🔴 `nil` ≠ `[]`. nil = old server without `scanIds` → stamp exactly what was sent;
    /// [] = server explicitly attached nothing → stamp nothing. Folding both into one case
    /// (`?? []` + "empty ⇒ stamp all") marked every scan "ordered" on an empty reply — the
    /// customer never re-sends and the drawing team never gets the mesh.
    private func stamp(_ result: SupplementScanResponse) {
        let stamped = result.scanIds.map { Set($0) }
        for record in records {
            guard let live = store.records.first(where: { $0.id == record.id }) else { continue }
            guard let cloudId = live.cloudScanId else { continue }
            if let stamped, !stamped.contains(cloudId) { continue }
            store.setOrderNumber(live, orderNumber: result.orderNumber)
        }
    }

    /// `deliveredOrder` đã được gán ở nhánh `.delivered`; bấm nút mới present. Gán lại được nhiều
    /// lần (khách đóng `RevisionSheet` rồi bấm lại) vì `sheet(item:)` bắn theo `id` mỗi lần
    /// chuyển từ nil sang giá trị.
    private func openRevision() {
        revisionTarget = deliveredOrder
    }
}
