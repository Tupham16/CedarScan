import SwiftUI
import RoomPlan

struct HomeView: View {
    @EnvironmentObject private var store: ScanStore
    @State private var isScanning = false
    @State private var isVideoScanning = false
    @State private var recordToRename: ScanRecord?
    @State private var renameText = ""
    @State private var saveError: String?
    @State private var pendingSaveError: String?
    @State private var showNewProject = false
    @State private var newProjectName = ""
    @State private var showGuide = false
    @State private var guideThenScan = false

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
            .sheet(isPresented: $showGuide) {
                if guideThenScan {
                    ScanGuideView { startScanning() }
                } else {
                    ScanGuideView()
                }
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

    private func startScanning() {
        if isSupported {
            isScanning = true
        } else {
            isVideoScanning = true
        }
    }

    private var scanButton: some View {
        Button {
            if UserDefaults.standard.bool(forKey: ScanGuideView.seenKey) {
                startScanning()
            } else {
                guideThenScan = true
                showGuide = true
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
                    if record.cloudOrderNumber != nil {
                        Image(systemName: "shippingbox.fill")
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
            L.t("\(record.roomCount) room(s)", "\(record.roomCount) phòng"),
            record.createdAt.formatted(date: .abbreviated, time: .shortened),
        ]
        if let area = record.areaSqm, area > 0 {
            parts.insert(String(format: "%.0f m²", area), at: 1)
        }
        return parts.joined(separator: " · ")
    }
}
