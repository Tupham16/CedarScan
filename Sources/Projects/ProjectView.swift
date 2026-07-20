import ARKit
import SwiftUI

/// Trang một dự án (căn nhà): danh sách bản quét các tầng, quét thêm, đặt hàng cả căn.
struct ProjectView: View {
    @EnvironmentObject private var store: ScanStore
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
    /// Bản quét khách vừa bấm "Đặt hàng ngay" ở màn preview.
    @State private var pendingOrderRecord: ScanRecord?
    @State private var meshCapFollowUp = false
    @State private var showScanNextPart = false
    @AppStorage("meshQuality") private var meshQuality: MeshQuality = MeshQuality.storageDefault
    @State private var showOrderSheet = false
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
                            "Name each scan by floor (Floor 1, Floor 2, Shed…) so we can assemble the home correctly.",
                            "Đặt tên từng bản quét theo tầng (Floor 1, Floor 2, Shed…) để đội xử lý ghép nhà chính xác."
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
        .fullScreenCover(isPresented: $isMeshScanning) {
            MeshScanFlowView(
                quality: meshQuality,
                onOrderNow: { record in pendingOrderRecord = record }
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
                saveError = message
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
        .sheet(isPresented: $showOrderSheet) {
            if let primary = orderableScans.first {
                OrderSheet(
                    record: primary,
                    projectName: project?.name,
                    candidateScans: orderableScans
                ) { orderNumber in
                    for record in orderableScans {
                        store.setOrderNumber(record, orderNumber: orderNumber)
                    }
                }
            }
        }
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
                "Scan each floor of this home (name them Floor 1, Floor 2…), or long-press an existing scan in the main list to move it here.",
                "Quét từng tầng của căn nhà (đặt tên Floor 1, Floor 2…), hoặc nhấn giữ bản quét có sẵn ở danh sách chính để chuyển vào đây."
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
                    // Chặn mềm: có bản quét chất lượng thấp → khuyên quét lại, vẫn cho gửi
                    if orderableScans.contains(where: { $0.qualityRescan == true }) {
                        showLowQualityConfirm = true
                    } else {
                        showOrderSheet = true
                    }
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
                        showOrderSheet = true
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
