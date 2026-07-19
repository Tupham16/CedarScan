import SwiftUI
import RoomPlan

struct HomeView: View {
    @EnvironmentObject private var store: ScanStore
    @State private var isScanning = false
    @State private var isVideoScanning = false
    @State private var isMeshScanning = false
    @State private var showScanSetup = false
    @State private var pendingScanMode: ScanMode?
    /// Căn nhà (dự án) mà bản quét sắp tới sẽ thuộc về — do ScanAddressView chọn/tạo.
    ///
    /// CỐ Ý KHÔNG XOÁ sau mỗi bản quét: alert "Quét phần còn lại ngay" set `isMeshScanning`
    /// THẲNG, không đi qua màn địa chỉ (xem .alert bên dưới), nên giữ giá trị lại chính là thứ
    /// làm Part 2 rơi vào ĐÚNG căn nhà của Part 1.
    ///
    /// ⚠ GIÁ TRỊ NÀY CÓ THỂ CŨ. Chỉ hai nút "Bắt đầu quét"/"Bỏ qua" trong ScanAddressView mới
    /// ghi đè nó; bấm "Hủy" hoặc vuốt đóng sheet thì nó GIỮ NGUYÊN giá trị của lần quét trước.
    /// Hiện vô hại vì hai đường đó cũng không set `pendingScanMode` nên onDismiss return sớm,
    /// không bản quét nào chạy. NHƯNG: pha sau mà thêm bất kỳ lối vào `isMeshScanning` nào KHÔNG
    /// đi qua ScanAddressView thì bản quét mới sẽ lặng lẽ rơi vào căn nhà của lần quét TRƯỚC ĐÓ
    /// — sai địa chỉ trên thẻ gửi đội vẽ mà không có dấu hiệu gì. Thêm lối vào như vậy thì phải
    /// đặt lại `pendingProjectId` tường minh ở đó.
    @State private var pendingProjectId: UUID?
    @State private var meshCapFollowUp = false
    @State private var showScanNextPart = false
    // Mặc định .high: file KHÔNG nặng thêm so với .medium (hình học y hệt), giá phải trả chỉ
    // là thời gian lưu — mà lúc lưu máy đã đặt xuống. Người dùng cũ còn lưu "light" trong
    // UserDefaults sẽ tự rơi về mặc định này vì rawValue đó không còn khớp case nào.
    @AppStorage("meshQuality") private var meshQuality: MeshQuality = MeshQuality.storageDefault
    @State private var recordToRename: ScanRecord?
    @State private var renameText = ""
    @State private var saveError: String?
    @State private var pendingSaveError: String?
    @State private var showNewProject = false
    @State private var newProjectName = ""
    @State private var showGuide = false
    /// Guide đang mở ở dạng CÓ nút "Bắt đầu quét" (luồng lần đầu) hay chỉ để đọc.
    @State private var guideThenScan = false
    /// Người dùng ĐÃ BẤM nút "Bắt đầu quét" trong guide. Tách khỏi `guideThenScan` vì nút
    /// "Đóng" cũng dismiss cùng một sheet — gộp một cờ thì đóng guide sẽ tự nhảy vào màn quét.
    ///
    /// RESET Ở LỐI VÀO, không chỉ ở onDismiss: nếu có đúng một lần onDismiss không chạy (view
    /// bị dựng lại/đổi identity giữa lúc sheet đang đóng — rất dễ xảy ra khi P3–P6 sắp tới đổi
    /// cấu trúc màn hình) thì cờ kẹt `true`, và lần sau người dùng chỉ mở guide để ĐỌC rồi đóng
    /// lại là app tự nhảy vào màn quét. Đặt lại ở cả hai lối vào biến chuyện đó thành bất khả
    /// thi về cấu trúc, thay vì phải tin rằng onDismiss luôn luôn chạy.
    @State private var startAfterGuide = false

    private var isSupported: Bool { RoomCaptureSession.isSupported }

    var body: some View {
        NavigationStack {
            Group {
                if store.records.isEmpty && store.projects.isEmpty {
                    emptyState
                } else {
                    mainList
                }
            }
            .navigationTitle("CedarScan")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        guideThenScan = false
                        startAfterGuide = false // xem mục "reset ở LỐI VÀO" ở sheet bên dưới
                        showGuide = true
                    } label: {
                        Label(L.t("How to scan", "Cách quét"), systemImage: "questionmark.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newProjectName = ""
                        showNewProject = true
                    } label: {
                        Label(L.t("New Property", "Dự án mới"), systemImage: "folder.badge.plus")
                    }
                }
            }
            // Bắt đầu quét từ onDismiss, KHÔNG gọi thẳng trong callback của guide: ScanGuideView
            // gọi dismiss() rồi onStart() trong CÙNG một transaction, nên present thẳng ở đó là
            // present-trong-lúc-sheet-đang-đóng — đúng thứ mà chú thích ngay dưới cảnh báo.
            // Hậu quả nếu không sửa: lần cài MỚI đầu tiên, bấm "Hiểu rồi — bắt đầu quét" thì
            // guide đóng mà sheet độ nét không hiện, người dùng phải bấm nút Quét lần hai. Và vì
            // seenKey đã được set TRƯỚC dismiss nên lần hai đi thẳng — lỗi tự lành và không bao
            // giờ tái hiện trên máy đã dùng, tức không thể bắt được bằng test thủ công thông thường.
            .sheet(isPresented: $showGuide, onDismiss: {
                guard startAfterGuide else { return }
                startAfterGuide = false
                startScanning()
            }) {
                if guideThenScan {
                    ScanGuideView { startAfterGuide = true }
                } else {
                    ScanGuideView()
                }
            }
            // Mở cover từ onDismiss của sheet (chờ sheet đóng XONG mới present) —
            // present-trong-lúc-sheet-đang-đóng là kiểu dễ rớt presentation nhất.
            .sheet(isPresented: $showScanSetup, onDismiss: {
                guard let mode = pendingScanMode else { return }
                pendingScanMode = nil
                switch mode {
                case .floorplan: isScanning = true
                case .mesh: isMeshScanning = true
                }
            }) {
                // Không .presentationDetents: đây là Form nhiều mục (địa chỉ + danh sách căn đã
                // có + độ nét), ép .medium là danh sách căn nhà bị bóp còn một hai dòng.
                ScanAddressView { projectId in
                    pendingProjectId = projectId
                    pendingScanMode = .mesh
                }
            }
            .fullScreenCover(isPresented: $isMeshScanning) {
                MeshScanFlowView(quality: meshQuality) { result in
                    do {
                        _ = try await store.saveMeshScan(
                            videoURL: result.videoURL, meshURL: result.meshURL,
                            trackURL: result.trackURL,
                            name: result.name, projectId: pendingProjectId,
                            quality: result.quality
                        )
                        // Nhà rất lớn chạm trần: sau khi cover đóng sẽ mời quét phần còn lại.
                        if result.hitCap { meshCapFollowUp = true }
                    } catch {
                        // Không hiện alert khi cover còn mở — sẽ bị nuốt lúc dismiss.
                        pendingSaveError = error.localizedDescription
                    }
                }
            }
            .onChange(of: isMeshScanning) { _, presented in
                guard !presented else { return }
                if let message = pendingSaveError {
                    pendingSaveError = nil
                    meshCapFollowUp = false
                    saveError = message
                } else if meshCapFollowUp {
                    meshCapFollowUp = false
                    showScanNextPart = true
                }
            }
            .alert(
                L.t("Part of the home is missing", "Còn một phần nhà chưa vào bản quét"),
                isPresented: $showScanNextPart
            ) {
                Button(L.t("Scan the rest now", "Quét phần còn lại ngay")) {
                    isMeshScanning = true
                }
                Button(L.t("Later", "Để sau"), role: .cancel) {}
            } message: {
                Text(L.t(
                    "The 3D model hit its size limit before you finished — the saved part is safe. Scan the remaining area as another scan (name them \"Part 1\", \"Part 2\"…) and they can be merged later.",
                    "Mô hình 3D chạm giới hạn trước khi quét xong — phần đã lưu vẫn an toàn. Hãy quét khu còn lại thành một bản quét khác (đặt tên \"Part 1\", \"Part 2\"…) để ghép lại sau."
                ))
            }
            .fullScreenCover(isPresented: $isVideoScanning) {
                VideoScanFlowView { videoURL, name in
                    do {
                        _ = try store.saveVideoScan(videoURL: videoURL, name: name)
                    } catch {
                        pendingSaveError = error.localizedDescription
                    }
                }
            }
            .onChange(of: isVideoScanning) { _, presented in
                if !presented, let message = pendingSaveError {
                    pendingSaveError = nil
                    saveError = message
                }
            }
            .safeAreaInset(edge: .bottom) {
                scanButton
            }
            .alert(L.t("New Property", "Dự án mới"), isPresented: $showNewProject) {
                TextField(L.t("Address or name (e.g. 1600 College Ave)", "Địa chỉ hoặc tên (vd 1600 College Ave)"), text: $newProjectName)
                Button(L.t("Create", "Tạo")) {
                    store.createProject(name: newProjectName)
                }
                Button(L.t("Cancel", "Hủy"), role: .cancel) {}
            } message: {
                Text(L.t(
                    "A property groups the scans of one home (Floor 1, Floor 2, Shed…) so you can order them together.",
                    "Một dự án gom các bản quét của cùng căn nhà (Floor 1, Floor 2, Shed…) để đặt hàng chung."
                ))
            }
            .alert(L.t("Rename scan", "Đổi tên bản quét"), isPresented: renameAlertBinding) {
                TextField(L.t("New name", "Tên mới"), text: $renameText)
                Button(L.t("Save", "Lưu")) {
                    if let record = recordToRename {
                        store.rename(record, to: renameText)
                    }
                    recordToRename = nil
                }
                Button(L.t("Cancel", "Hủy"), role: .cancel) { recordToRename = nil }
            }
            .alert(L.t("Could not save", "Lỗi khi lưu"), isPresented: saveErrorBinding) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .fullScreenCover(isPresented: $isScanning) {
                ScanFlowView { rooms, videoURL, meshURL, name, quality in
                    do {
                        _ = try await store.save(
                            rooms: rooms, videoURL: videoURL, coloredMeshURL: meshURL,
                            name: name, quality: quality
                        )
                        return true
                    } catch {
                        // Không hiện alert khi cover còn mở — sẽ bị nuốt lúc dismiss.
                        pendingSaveError = error.localizedDescription
                        return false
                    }
                }
            }
            .onChange(of: isScanning) { _, presented in
                if !presented, let message = pendingSaveError {
                    pendingSaveError = nil
                    saveError = message
                }
            }
            .navigationDestination(for: ScanRecord.self) { record in
                ScanDetailView(record: record)
            }
            .navigationDestination(for: ScanProject.self) { project in
                ProjectView(projectId: project.id)
            }
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { recordToRename != nil },
            set: { if !$0 { recordToRename = nil } }
        )
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.metering.matrix")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(L.t("No scans yet", "Chưa có bản quét nào"))
                .font(.title3.weight(.semibold))
            Text(isSupported
                 ? L.t(
                    "Tap the button below to scan your first space, or create a Property folder for a home with several floors.",
                    "Bấm nút bên dưới để quét không gian đầu tiên, hoặc tạo Dự án cho căn nhà nhiều tầng."
                 )
                 : L.t(
                    "This device has no LiDAR sensor, so you can record a guided video walkthrough instead. Note: measurements from video are less accurate than a LiDAR scan (iPhone Pro).",
                    "Máy này không có cảm biến LiDAR — bạn có thể quay video khảo sát theo hướng dẫn thay thế. Lưu ý: số đo từ video kém chính xác hơn quét LiDAR (iPhone Pro)."
                 ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mainList: some View {
        List {
            if !store.projects.isEmpty {
                Section(L.t("Properties", "Dự án (căn nhà)")) {
                    ForEach(store.projects) { project in
                        NavigationLink(value: project) {
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.name)
                                        .font(.headline)
                                    Text(L.t(
                                        "\(store.scans(in: project).count) scan(s)",
                                        "\(store.scans(in: project).count) bản quét"
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            if !store.looseScans.isEmpty {
                Section(store.projects.isEmpty
                        ? L.t("Scans", "Bản quét")
                        : L.t("Not in a property", "Chưa vào dự án")) {
                    ForEach(store.looseScans) { record in
                        ScanRow(
                            record: record,
                            onRename: {
                                renameText = record.name
                                recordToRename = record
                            }
                        )
                    }
                }
            }
        }
    }

    // KHÔNG lọc bản quét đã đặt ra khỏi danh sách này. Từng thử và đó là lỗi CHẶN: `ScanRow` là
    // NavigationLink DUY NHẤT tới ScanDetailView, và `store.delete` chỉ được gọi từ swipe của
    // chính nó — ẩn dòng đi là bản quét mồ côi hoàn toàn, không mở/chia sẻ/xoá được, file 40-200MB
    // kẹt vĩnh viễn. Tab Đơn hàng KHÔNG thay thế được: nó lấy đơn từ server, cần mạng + đăng nhập,
    // và không trỏ về ScanRecord nào trên máy.
    // Cách làm gọn máy ĐÚNG (chủ app chốt 2026-07-19): giữ nguyên hiển thị cho tới khi đơn ĐÃ GIAO,
    // rồi TỰ XOÁ hẳn file — đơn giao được tự nó là bằng chứng dữ liệu đã an toàn trên R2.

    private func startScanning() {
        if isSupported {
            showScanSetup = true
        } else {
            isVideoScanning = true
        }
    }

    private var scanButton: some View {
        Button {
            // Guide chỉ dạy luồng quét 3D LiDAR (đi chậm, giữ 40cm, đừng dừng giữa các tầng,
            // dựng mô hình lúc lưu). Máy KHÔNG có LiDAR đi đường quay video — không có thứ nào
            // trong đó áp dụng được, nên đừng bắt họ đọc rồi rơi vào màn chẳng giống mô tả nào.
            if isSupported && !UserDefaults.standard.bool(forKey: ScanGuideView.seenKey) {
                guideThenScan = true
                startAfterGuide = false // xem mục "reset ở LỐI VÀO" ở sheet bên trên
                showGuide = true
            } else {
                startScanning()
            }
        } label: {
            Label(
                isSupported
                    ? L.t("New scan", "Quét không gian mới")
                    : L.t("Record video walkthrough", "Quay video khảo sát"),
                systemImage: isSupported ? "viewfinder" : "video.fill"
            )
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }
}

/// Một dòng bản quét (dùng chung ở danh sách chính và trang dự án):
/// bấm mở chi tiết, vuốt xoá/đổi tên, nhấn giữ để chuyển vào dự án.
struct ScanRow: View {
    @EnvironmentObject private var store: ScanStore
    let record: ScanRecord
    let onRename: () -> Void

    var body: some View {
        NavigationLink(value: record) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(record.name)
                        .font(.headline)
                    // Nhãn CHỮ chứ không chỉ icon: mở dự án ra phải đọc được NGAY tầng nào đã đặt
                    // rồi, để biết căn nhà còn thiếu tầng nào mà quét thêm. Một icon nhỏ màu xanh
                    // không nói được điều đó.
                    if record.cloudOrderNumber != nil {
                        Label(L.t("Ordered", "Đã đặt"), systemImage: "shippingbox.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    } else if record.cloudScanId != nil {
                        Image(systemName: "checkmark.icloud.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .swipeActions {
            Button(role: .destructive) {
                store.delete(record)
            } label: {
                Label(L.t("Delete", "Xóa"), systemImage: "trash")
            }
            Button {
                onRename()
            } label: {
                Label(L.t("Rename", "Đổi tên"), systemImage: "pencil")
            }
        }
        .contextMenu {
            if !store.projects.isEmpty {
                Menu {
                    ForEach(store.projects) { project in
                        Button(project.name) {
                            store.moveScan(record, to: project)
                        }
                    }
                } label: {
                    Label(L.t("Move to property", "Chuyển vào dự án"), systemImage: "folder")
                }
            }
            if record.projectId != nil {
                Button {
                    store.moveScan(record, to: nil)
                } label: {
                    Label(L.t("Remove from property", "Đưa ra khỏi dự án"), systemImage: "folder.badge.minus")
                }
            }
            Button {
                onRename()
            } label: {
                Label(L.t("Rename", "Đổi tên"), systemImage: "pencil")
            }
        }
    }

    private var subtitle: String {
        var parts = [
            typePart,
            record.createdAt.formatted(date: .abbreviated, time: .shortened),
        ]
        if let area = record.areaSqm, area > 0 {
            parts.insert(String(format: "%.0f m²", area), at: 1)
        }
        return parts.joined(separator: " · ")
    }

    /// Bản mesh/video không có roomCount ý nghĩa — hiện loại (+ mức nét) thay vì "0 phòng".
    /// (Không có mức nét trên dòng thì test 3 mức ra 3 dòng giống hệt nhau.)
    private var typePart: String {
        if record.isMeshOnly {
            let base = L.t("3D mesh", "Mesh 3D")
            // storedLabel (không phải MeshQuality(rawValue:)) — bản quét cũ lưu "light" đã
            // không còn case tương ứng, dùng init thẳng là nhãn mức nét biến mất lặng lẽ.
            guard let raw = record.meshQuality, let tierLabel = MeshQuality.storedLabel(raw) else { return base }
            return base + " (" + tierLabel + ")"
        }
        if record.isVideoOnly {
            return L.t("Video walkthrough", "Video khảo sát")
        }
        return L.t("\(record.roomCount) room(s)", "\(record.roomCount) phòng")
    }
}
