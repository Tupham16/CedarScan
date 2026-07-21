import ARKit
import SwiftUI

/// Trang một dự án (căn nhà): danh sách bản quét các tầng, quét thêm, đặt hàng cả căn.
struct ProjectView: View {
    @EnvironmentObject private var store: ScanStore
    /// Cần cho CỔNG CHẶN ĐẶT HÀNG ở cuối file. Màn này từng không đọc `AccountStore` một dòng
    /// nào — xem giải thích ở nút "Đặt làm mặt bằng".
    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss
    let projectId: UUID
    /// Đường dẫn điều hướng của NavigationStack đang chứa màn này (sở hữu bởi HomeView) — cần
    /// để màn preview sau khi quét đẩy được sang trang bản quét.
    @Binding var path: NavigationPath

    @State private var isMeshScanning = false
    @State private var showQualityPicker = false
    @State private var showGuide = false
    /// Người dùng đã BẤM "Bắt đầu quét" trong guide (khác với "guide đang mở"). Reset ở LỐI VÀO
    /// chứ không chỉ trong onDismiss — xem giải thích đầy đủ ở HomeView.startAfterGuide.
    @State private var startAfterGuide = false
    /// Khách đã bấm "Bắt đầu quét" ở sheet độ nét — xem HomeView.pendingScanStart.
    @State private var pendingScanStart = false
    /// Khách bấm "Quét thêm khu vực còn thiếu" ở màn preview → mở lại phiên quét cho CÙNG căn.
    @State private var pendingScanMore = false
    /// Bản quét khách vừa bấm "Đặt hàng ngay" ở màn preview.
    @State private var pendingOrderRecord: ScanRecord?
    @State private var meshCapFollowUp = false
    @State private var showScanNextPart = false
    @AppStorage("meshQuality") private var meshQuality: MeshQuality = MeshQuality.storageDefault
    /// Mục tiêu của form đặt hàng: DANH TÍNH các bản quét đã chốt đúng lúc mở form.
    ///
    /// 🔴 Dùng `.sheet(item:)`, KHÔNG dùng `.sheet(isPresented:)` + cờ Bool riêng. Đây là chỗ đã
    /// trả giá một lần: bản trước để `@State showOrderSheet` (Bool) và một `@State` thứ hai chứa
    /// danh sách id, cả hai set CÙNG một nhịp trong `presentOrderSheet()`. Nhưng `.sheet(isPresented:)`
    /// dựng nội dung khi cờ lật true, và ở nhịp đó `@State` thứ hai CHƯA kịp commit — lần ĐẦU mở
    /// form của mỗi `ProjectView` (giá trị còn nil) cho ra một sheet TRẮNG trượt lên rồi phải vuốt
    /// xuống; lần sau đã có giá trị nên hết, mở dự án khác (ProjectView mới) lại nil → trắng lại.
    /// Đúng triệu chứng khách báo trên máy thật, mà hai vòng review đối kháng KHÔNG bắt được vì nó
    /// là race lúc CHẠY, không phải lỗi logic đọc trên máy Windows.
    /// `.sheet(item:)` truyền thẳng `target` (đã unwrap) vào closure nên nội dung LUÔN có dữ liệu
    /// ngay lần đầu — không còn khe nil.
    ///
    /// 🔴 `scanIds` CHỈ giữ `[UUID]`, TUYỆT ĐỐI KHÔNG giữ `[ScanRecord]`. Chụp cả bản ghi là đóng
    /// băng luôn `cloudScanId`, mà `OrderSheet.ensureUploaded` đọc đúng trường đó để biết "tầng này
    /// đã lên server chưa". Đóng băng nó thì lần đặt thứ hai (sau timeout 30s / 403 chưa xác minh /
    /// rớt 4G — đều là ca thật) sẽ TẢI LÊN LẠI 40–200MB mỗi tầng và đẻ scan id MỚI; hai chốt
    /// chống-đơn-trùng phía server đều khoá theo scan id nên id mới lọt cả hai → đơn thứ hai cho
    /// cùng căn nhà, trừ hai lần suất miễn phí. Chốt danh tính, giải GIÁ TRỊ sống mỗi lần render.
    private struct OrderSheetTarget: Identifiable {
        let id = UUID()
        let scanIds: [UUID]
    }
    @State private var orderTarget: OrderSheetTarget?
    /// Cổng đăng nhập/xác minh mở tại chỗ — xem `AccountGateSheet`.
    @State private var showAccountGate = false
    @State private var showLowQualityConfirm = false
    @State private var recordToRename: ScanRecord?
    @State private var renameText = ""
    @State private var showRenameProject = false
    @State private var projectNameText = ""
    @State private var showDeleteConfirm = false
    @State private var pendingSaveError: String?
    @State private var saveError: String?

    private var project: ScanProject? { store.project(with: projectId) }
    private var scans: [ScanRecord] { project.map { store.scans(in: $0) } ?? [] }
    private var orderableScans: [ScanRecord] { scans.filter { $0.cloudOrderNumber == nil } }
    /// Xem ghi chú ở `HomeView.isSupported` — hỏi ARKit, không hỏi RoomPlan.
    private var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    var body: some View {
        content
            // Dự án bị dọn (mọi tầng đã giao) trong lúc màn này đang mở → thoát ra.
            // NavigationStack giữ `ScanProject` trong path nên màn KHÔNG tự pop: tiêu đề thành
            // trắng, danh sách rỗng, mà nút "Quét căn nhà này" vẫn đó và trỏ vào một projectId
            // không còn tồn tại. Xảy ra thật khi app quay lại foreground lúc khách đang ở đây.
            // KHÔNG dismiss khi đang present cover quét: view này SỞ HỮU cover, pop nó là tháo
            // luôn phiên quét đang chạy. `ScanStore.beginBusy()` đã chặn dọn suốt phiên quét nên
            // ca này gần như không xảy ra, nhưng đây là lớp thứ hai — pop nhầm lúc đang quét là
            // mất trắng 10–30 phút đi bộ, đắt hơn nhiều so với việc nán lại một màn rỗng.
            .onChange(of: project == nil) { _, gone in
                if gone && !isMeshScanning { dismiss() }
            }
            // Cover đóng mà dự án đã biến mất trong lúc đó → giờ mới thoát.
            .onChange(of: isMeshScanning) { _, presented in
                if !presented && project == nil { dismiss() }
            }
    }

    private var content: some View {
        Group {
            if scans.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        ForEach(scans) { record in
                            ScanRow(
                                record: record,
                                onRename: {
                                    renameText = record.name
                                    recordToRename = record
                                }
                            )
                        }
                    } footer: {
                        Text(L.t(
                            "Give each scan a clear name (Whole home, Part 1, Shed…) so we can assemble the home correctly.",
                            "Đặt tên rõ cho từng bản quét (Cả căn, Part 1, Nhà kho…) để đội xử lý ghép nhà chính xác."
                        ))
                    }
                }
            }
        }
        .navigationTitle(project?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        projectNameText = project?.name ?? ""
                        showRenameProject = true
                    } label: {
                        Label(L.t("Rename property", "Đổi tên dự án"), systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label(L.t("Delete property", "Xóa dự án"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomButtons
        }
        .alert(L.t("Rename property", "Đổi tên dự án"), isPresented: $showRenameProject) {
            TextField(L.t("Name", "Tên"), text: $projectNameText)
            Button(L.t("Save", "Lưu")) {
                if let project { store.renameProject(project, to: projectNameText) }
            }
            Button(L.t("Cancel", "Hủy"), role: .cancel) {}
        }
        .alert(L.t("Delete this property?", "Xóa dự án này?"), isPresented: $showDeleteConfirm) {
            Button(L.t("Delete", "Xóa"), role: .destructive) {
                if let project { store.deleteProject(project) }
                dismiss()
            }
            Button(L.t("Cancel", "Hủy"), role: .cancel) {}
        } message: {
            Text(L.t(
                "Scans inside will NOT be deleted — they move back to the main list.",
                "Các bản quét bên trong KHÔNG bị xóa — chúng trở về danh sách chính."
            ))
        }
        .alert(L.t("Rename scan", "Đổi tên bản quét"), isPresented: renameAlertBinding) {
            TextField(L.t("New name", "Tên mới"), text: $renameText)
            Button(L.t("Save", "Lưu")) {
                if let record = recordToRename { store.rename(record, to: renameText) }
                recordToRename = nil
            }
            Button(L.t("Cancel", "Hủy"), role: .cancel) { recordToRename = nil }
        }
        .alert(L.t("Could not save", "Lỗi khi lưu"), isPresented: saveErrorBinding) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        // Bắt đầu quét từ onDismiss chứ không từ callback của guide — ScanGuideView gọi
        // dismiss() rồi onStart() cùng một transaction, present thẳng ở đó là present-trong-
        // lúc-sheet-đang-đóng. Xem giải thích đầy đủ ở HomeView.
        .sheet(isPresented: $showGuide, onDismiss: {
            guard startAfterGuide else { return }
            startAfterGuide = false
            startScanning()
        }) {
            ScanGuideView { startAfterGuide = true }
        }
        // Mở cover từ onDismiss của sheet (chờ sheet đóng XONG mới present) — như HomeView.
        .sheet(isPresented: $showQualityPicker, onDismiss: {
            guard pendingScanStart else { return }
            pendingScanStart = false
            isMeshScanning = true
        }) {
            ScanQualityPickerView {
                pendingScanStart = true
            }
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(
            isPresented: $isMeshScanning,
            // Mở lại phiên quét cho "Quét thêm" PHẢI chờ cover đóng HẲN (onDismiss), không được
            // set cờ trong onChange bên dưới: onChange chạy ngay lúc binding lật false, và set lại
            // true trong cùng nhịp đó thì SwiftUI gộp false→true thành KHÔNG ĐỔI — cover không bao
            // giờ được tháo và dựng lại, nên nó treo nguyên ở màn preview của bản quét vừa xong.
            onDismiss: {
                guard pendingScanMore else { return }
                pendingScanMore = false
                isMeshScanning = true
            }
        ) {
            MeshScanFlowView(
                quality: meshQuality,
                onOrderNow: { record in pendingOrderRecord = record },
                onScanMore: { pendingScanMore = true }
            ) { result in
                do {
                    let saved = try await store.saveMeshScan(
                        videoURL: result.videoURL, meshURL: result.meshURL,
                        trackURL: result.trackURL,
                        name: result.name, projectId: projectId, quality: result.quality
                    )
                    if result.hitCap { meshCapFollowUp = true }
                    return saved
                } catch {
                    pendingSaveError = error.localizedDescription
                    return nil
                }
            }
        }
        .onChange(of: isMeshScanning) { _, presented in
            guard !presented else { return }
            if let message = pendingSaveError {
                pendingSaveError = nil
                meshCapFollowUp = false
                pendingOrderRecord = nil
                pendingScanMore = false
                saveError = message
            } else if pendingScanMore {
                // Việc mở lại phiên quét do onDismiss của cover lo. Ở đây chỉ dọn các ý định khác
                // để chúng không nổ chồng lên phiên quét mới.
                meshCapFollowUp = false
                pendingOrderRecord = nil
            } else if meshCapFollowUp {
                // Xem giải thích thứ tự ưu tiên ở HomeView.
                meshCapFollowUp = false
                showScanNextPart = true
            } else {
                goToPendingOrder()
            }
        }
        .alert(
            L.t("Part of the home is missing", "Còn một phần nhà chưa vào bản quét"),
            isPresented: $showScanNextPart
        ) {
            Button(L.t("Scan the rest now", "Quét phần còn lại ngay")) {
                pendingOrderRecord = nil
                isMeshScanning = true
            }
            Button(L.t("Scan later", "Quét sau"), role: .cancel) {
                goToPendingOrder()
            }
        } message: {
            Text(L.t(
                "The 3D model hit its size limit before you finished — the saved part is safe. Scan the remaining area as another scan (name them \"Part 1\", \"Part 2\"…) and they can be merged later.",
                "Mô hình 3D chạm giới hạn trước khi quét xong — phần đã lưu vẫn an toàn. Hãy quét khu còn lại thành một bản quét khác (đặt tên \"Part 1\", \"Part 2\"…) để ghép lại sau."
            ))
        }
        .sheet(item: $orderTarget) { target in
            orderSheetBody(target)
        }
        .sheet(isPresented: $showAccountGate, onDismiss: {
            // Qua được cổng thì ĐI TIẾP việc khách đang làm dở, đừng bắt họ bấm lại đúng cái nút
            // vừa bấm.
            //
            // Màn này khác `ScanDetailView` ở chỗ nguy hiểm: ở đó thẻ dịch vụ vẽ THEO TRẠNG THÁI
            // nên cổng vừa đóng là dòng chữ + nút "Đăng nhập" tự biến thành nút "Đặt làm mặt bằng"
            // ngay tại chỗ vừa bấm — khách thấy rõ mình vừa tiến một bước. Ở đây nhãn nút KHÔNG
            // phụ thuộc `account`, nên thiếu đoạn này thì đăng nhập xong màn hình không đổi MỘT
            // PIXEL: khách đọc thành "đăng ký xong vẫn không đặt được" rồi bỏ đi.
            //
            // 🔴 Phải nằm ở `onDismiss`, KHÔNG được đổi sang `.onChange` của trạng thái tài khoản:
            // mở sheet thứ hai trong lúc sheet thứ nhất chưa tháo xong là đúng họ lỗi trình bày
            // lồng nhau mà repo đã trả giá ở luồng "Quét thêm" (SESSION-HANDOFF mục 2.E).
            // 🔴 Điều kiện ở đây HẸP HƠN guard ở nút bấm, và đó là CỐ Ý — đừng "sửa cho khớp".
            // Hai chỗ hỏi hai câu khác nhau:
            //  · Nút bấm hỏi "có CHẶN khách không?" → chỉ `isSignedIn`. Gác thêm `needsVerification`
            //    ở đó là khoá nhầm người đã xác minh khi cờ còn cũ (giải thích dài ở nút).
            //  · Chỗ này hỏi "có TỰ ĐI TIẾP HỘ khách không?" → phải đủ điều kiện đặt hàng thật.
            //    Gác hẹp ở đây KHÔNG chặn ai: khách bấm lại nút là qua ngay, vì nút chỉ gác
            //    `isSignedIn`. Nên hướng sai duy nhất có thể xảy ra là "bắt bấm thêm một lần".
            //
            // Vì sao phải hẹp: `isSignedIn` bật lên NGAY GIỮA LÚC sheet còn mở — khách đăng ký
            // xong thì rơi sang màn nhập mã, sheet chưa đóng vì chưa đủ điều kiện. Từ giây đó MỌI
            // kiểu đóng sheet đều thoả `isSignedIn`, kể cả VUỐT XUỐNG hoặc bấm "Hủy" — tức đúng
            // lúc khách vừa nói THÔI thì form đặt hàng lại tự bật ra, rồi kết thúc bằng lỗi server
            // vì chưa xác minh. Gác hẹp là để cú rút lui đó được tôn trọng.
            guard account.isSignedIn, !account.needsVerification else { return }
            startOrderFlow()
        }) {
            AccountGateSheet()
        }
    }

    /// Mở luồng đặt hàng SAU khi đã qua cổng tài khoản.
    ///
    /// Dùng chung cho nút bấm và cho `onDismiss` của cổng: hai lối vào phải cư xử y hệt. Tách ra
    /// để không lối nào lỡ quên bước cảnh báo chất lượng thấp.
    private func startOrderFlow() {
        // Chặn mềm: có bản quét chất lượng thấp → khuyên quét lại, vẫn cho gửi
        if orderableScans.contains(where: { $0.qualityRescan == true }) {
            showLowQualityConfirm = true
        } else {
            presentOrderSheet()
        }
    }

    /// LỐI VÀO DUY NHẤT của form đặt hàng.
    ///
    /// Mọi chỗ muốn mở sheet phải gọi hàm này, ĐỪNG gán `orderTarget` thẳng ở nơi khác: đóng gói
    /// việc chốt danh tính vào một chỗ. Có đúng hai lối vào (nút "Đặt làm mặt bằng" và nút "Vẫn
    /// đặt hàng" của cảnh báo chất lượng thấp), và lối thứ hai đã một lần bị bỏ quên khi sửa lối
    /// thứ nhất.
    private func presentOrderSheet() {
        // Tập rỗng thì không có gì để đặt. Nút gọi hàm này vốn đã ẩn khi rỗng, nên đây là lớp thứ
        // hai — fail-closed. Tính `ids` TRƯỚC rồi mới dựng target: gán `orderTarget` là thao tác
        // DUY NHẤT bật sheet (sheet(item:) hiện khi item != nil), nên target phải đủ dữ liệu ngay.
        let ids = orderableScans.map(\.id)
        guard !ids.isEmpty else { return }
        orderTarget = OrderSheetTarget(scanIds: ids)
    }

    /// Nội dung form đặt hàng: DANH TÍNH chốt lúc mở (trong `target`), GIÁ TRỊ đọc SỐNG từ store
    /// mỗi lần render.
    ///
    /// Tách thành hàm nhận `target` theo đúng lệ của repo — biểu thức SwiftUI lồng nhiều tầng là
    /// thứ CI này từng chết vì "Swift type-check timeout". Cũng vì lẽ đó mà gọi `liveScans(of:)`
    /// HAI LẦN thay vì hứng vào một `let` cục bộ: khai báo cục bộ trong thân ViewBuilder là đúng
    /// mẫu bị cấm ở `ScanAddressView.expandRow`. Gọi hai lần vô hại — cùng một nhịp render, cùng
    /// một trạng thái store.
    ///
    /// 🔴 KHÔNG có callback đóng dấu "đã đặt" ở đây, và đừng thêm lại. Chỗ này từng chạy
    /// `for record in orderableScans { store.setOrderNumber(...) }`, tức đóng dấu lên cả tầng
    /// khách vừa BỎ CHỌN trong form — hậu quả ghi đầy đủ ở `OrderSheet.submit()`, nơi duy nhất
    /// biết khách đã tick những tầng nào và nay tự lo việc đóng dấu.
    @ViewBuilder
    private func orderSheetBody(_ target: OrderSheetTarget) -> some View {
        if let primary = liveScans(of: target).first {
            OrderSheet(
                record: primary,
                projectName: project?.name,
                candidateScans: liveScans(of: target)
            )
        }
    }

    /// Giải danh tính đã chốt thành bản ghi SỐNG. Bản quét bị dọn mất giữa chừng thì rơi khỏi
    /// danh sách (compactMap) thay vì kéo theo dữ liệu ma.
    private func liveScans(of target: OrderSheetTarget) -> [ScanRecord] {
        target.scanIds.compactMap { id in store.records.first { $0.id == id } }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(get: { recordToRename != nil }, set: { if !$0 { recordToRename = nil } })
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(L.t("No scans in this property yet", "Dự án chưa có bản quét nào"))
                .font(.headline)
            Text(L.t(
                "Scan the whole home in one continuous pass — multiple floors are fine. If it's very large, split it into several scans (Part 1, Part 2…). Or long-press an existing scan in the main list to move it here.",
                "Quét liền một mạch cả căn nhà là tốt nhất (kể cả nhiều tầng). Nhà quá lớn thì chia thành nhiều bản quét (Part 1, Part 2…). Hoặc nhấn giữ bản quét có sẵn ở danh sách chính để chuyển vào đây."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Tách khỏi thân nút để guide gọi lại được từ onDismiss.
    /// Reset hai cờ ở LỐI VÀO — xem giải thích đầy đủ ở HomeView.startScanning.
    private func startScanning() {
        pendingScanStart = false
        pendingOrderRecord = nil
        pendingScanMore = false
        showQualityPicker = true
    }

    /// Xem HomeView.goToPendingOrder — cùng một việc, trên cùng một NavigationStack.
    private func goToPendingOrder() {
        guard let record = pendingOrderRecord else { return }
        pendingOrderRecord = nil
        path.append(record)
    }

    /// Lặp lại lời giải thích ở ĐÂY chứ không trông vào việc người dùng đã đọc ở trang chủ.
    ///
    /// Từng viết comment "vào được màn này nghĩa là đã qua trang chủ, nơi đã nói rõ lý do" —
    /// SAI: lời giải thích đầy đủ của trang chủ nằm trong `emptyState`, mà `emptyState` chỉ hiện
    /// khi CẢ records LẪN projects đều rỗng. Chỉ cần tạo một dự án là nó biến mất VĨNH VIỄN.
    /// Mà nút "Dự án mới" lại KHÔNG bị khoá theo isSupported, nên đường đó rất dễ đi vào.
    @ViewBuilder
    private var unsupportedNote: some View {
        if !isSupported {
            Text(L.t(
                "This iPhone has no LiDAR sensor. CedarScan needs an iPhone Pro (12 Pro or newer).",
                "iPhone này không có cảm biến LiDAR. CedarScan cần iPhone bản Pro (12 Pro trở lên)."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
    }

    private var bottomButtons: some View {
        VStack(spacing: 8) {
            unsupportedNote
            Button {
                // Guide lần đầu Y HỆT HomeView. Trước P3 màn này KHÔNG hề kiểm seenKey: khách
                // tạo Dự án trước rồi quét từ đây sẽ không bao giờ đọc hướng dẫn, và vì seenKey
                // vẫn false nên lần sau quét từ Home guide mới nhảy ra — sau khi bản quét đầu
                // tiên đã hỏng.
                if !UserDefaults.standard.bool(forKey: ScanGuideView.seenKey) {
                    startAfterGuide = false
                    showGuide = true
                } else {
                    startScanning()
                }
            } label: {
                Label(L.t("Scan this property", "Quét căn nhà này"), systemImage: "viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            // Máy không LiDAR: khoá nút (luồng quay video đã gỡ 2026-07-19).
            .disabled(!isSupported)

            if !orderableScans.isEmpty {
                Button {
                    // 🔴 CỔNG CHẶN TÀI KHOẢN — ĐỨNG TRƯỚC cả cảnh báo chất lượng. Chưa đăng nhập
                    // thì hỏi chuyện "có muốn quét lại không" là vô nghĩa: khách còn chưa có tài
                    // khoản để đặt.
                    //
                    // Cổng này TỪNG KHÔNG TỒN TẠI và đó là ngõ cụt tệ nhất của luồng đặt hàng.
                    // `OrderSheet` KHÔNG tự kiểm tra đăng nhập (nó chỉ khai `store`), nên nút này
                    // mở thẳng sheet → `.task` gọi `catalog()` với token nil → hỏng → khách thấy
                    // chuỗi lỗi thô kèm nút "Thử lại" bấm mãi không bao giờ chạy được, và KHÔNG
                    // câu nào nhắc tới đăng nhập. Khách không hiểu vì sao mình bị chặn.
                    //
                    // Lỗi tồn tại được là vì màn này là BẢN SAO gần-y-hệt của HomeView và cổng
                    // chặn chỉ được thêm ở `ScanDetailView.serviceCard`. Ai sửa luồng đặt hàng ở
                    // một bên thì phải soi bên kia — hai đường vào cùng một `OrderSheet`.
                    //
                    // 🔴 CHỈ gác `isSignedIn`, CỐ Ý KHÔNG gác `needsVerification` — đừng "thêm cho
                    // nhất quán với ScanDetailView". Đã thử và phải gỡ ra sau ba vòng review:
                    // `emailVerified` chỉ đúng sau khi `refresh()` nói chuyện được với server, mà
                    // `refresh()` nuốt lỗi mạng. Gác thêm cờ đó nghĩa là khách ĐÃ xác minh, mở app
                    // ở công trường sóng yếu, bị khoá khỏi nút đặt hàng của cả căn nhà — một hồi
                    // quy do chính cổng chặn tạo ra, vì màn này TRƯỚC GIỜ KHÔNG chặn xác minh.
                    // Mọi cách chống đỡ (lưu cờ xuống đĩa, cờ "đã biết chắc", fail-open, thêm mốc
                    // thử lại) đều đẻ ra lỗi mới ở vòng sau — nặng nhất là làm `VerifyEmailView`
                    // biến mất khỏi app vì `needsVerification` là lối vào DUY NHẤT tới nó.
                    //
                    // Ngõ cụt cần sửa ở đây là "chưa đăng nhập → sheet lỗi thô + Thử lại vô tận",
                    // và nó thuộc về `isSignedIn`. Việc chưa xác minh vẫn để server từ chối như
                    // trước bản vá — chưa đẹp, nhưng KHÔNG phải hồi quy, và có việc riêng theo dõi.
                    guard account.isSignedIn else {
                        showAccountGate = true
                        return
                    }
                    startOrderFlow()
                } label: {
                    Label(
                        L.t("Order Floor Plan (\(orderableScans.count) scan(s))",
                            "Đặt làm mặt bằng (\(orderableScans.count) bản quét)"),
                        systemImage: "paperplane.fill"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .confirmationDialog(
                    L.t("Some scans have low quality", "Có bản quét chất lượng thấp"),
                    isPresented: $showLowQualityConfirm,
                    titleVisibility: .visible
                ) {
                    Button(L.t("Order anyway", "Vẫn đặt hàng")) {
                        presentOrderSheet()
                    }
                    Button(L.t("I'll rescan first", "Để tôi quét lại"), role: .cancel) {}
                } message: {
                    Text(L.t(
                        "Rescanning the flagged floors usually gives a more accurate floor plan: \(lowQualityNames). You can still order — our team will be notified.",
                        "Quét lại các tầng bị đánh dấu thường cho bản vẽ chính xác hơn: \(lowQualityNames). Bạn vẫn có thể đặt — đội xử lý sẽ được báo trước."
                    ))
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private var lowQualityNames: String {
        orderableScans.filter { $0.qualityRescan == true }.map(\.name).joined(separator: ", ")
    }
}
