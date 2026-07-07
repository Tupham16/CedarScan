import SwiftUI
import RoomPlan

/// Trang một dự án (căn nhà): danh sách bản quét các tầng, quét thêm, đặt hàng cả căn.
struct ProjectView: View {
    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss
    let projectId: UUID

    @State private var isScanning = false
    @State private var showOrderSheet = false
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
    private var isSupported: Bool { RoomCaptureSession.isSupported }

    var body: some View {
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
        .fullScreenCover(isPresented: $isScanning) {
            ScanFlowView { rooms, videoURL, meshURL, name in
                do {
                    _ = try await store.save(
                        rooms: rooms, videoURL: videoURL, coloredMeshURL: meshURL,
                        name: name, projectId: projectId
                    )
                } catch {
                    pendingSaveError = error.localizedDescription
                }
            }
        }
        .onChange(of: isScanning) { _, presented in
            if !presented, let message = pendingSaveError {
                pendingSaveError = nil
                saveError = message
            }
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

    private var bottomButtons: some View {
        VStack(spacing: 8) {
            Button {
                isScanning = true
            } label: {
                Label(L.t("Scan this property", "Quét căn nhà này"), systemImage: "viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isSupported)

            if !orderableScans.isEmpty {
                Button {
                    showOrderSheet = true
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
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }
}
