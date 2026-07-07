import SwiftUI
import RoomPlan

struct HomeView: View {
    @EnvironmentObject private var store: ScanStore
    @State private var isScanning = false
    @State private var recordToRename: ScanRecord?
    @State private var renameText = ""
    @State private var saveError: String?
    @State private var pendingSaveError: String?

    private var isSupported: Bool { RoomCaptureSession.isSupported }

    var body: some View {
        NavigationStack {
            Group {
                if store.records.isEmpty {
                    emptyState
                } else {
                    scanList
                }
            }
            .navigationTitle("CedarScan")
            .safeAreaInset(edge: .bottom) {
                scanButton
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
                ScanFlowView { rooms, videoURL, meshURL, name in
                    do {
                        _ = try await store.save(
                            rooms: rooms, videoURL: videoURL, coloredMeshURL: meshURL, name: name
                        )
                    } catch {
                        // Không hiện alert khi cover còn mở — sẽ bị nuốt lúc dismiss.
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
                    "Tap the button below to scan your first space. Walk slowly around the room and point the camera at walls, doors and furniture.",
                    "Bấm nút bên dưới để quét không gian đầu tiên. Đi chậm quanh phòng, hướng camera vào tường, cửa và đồ đạc."
                 )
                 : L.t(
                    "This device has no LiDAR sensor, so scanning is unavailable. You need an iPhone Pro (12 Pro or later) or iPad Pro.",
                    "Thiết bị này không có cảm biến LiDAR nên không quét được. Cần iPhone Pro (12 Pro trở lên) hoặc iPad Pro."
                 ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanList: some View {
        List {
            ForEach(store.records) { record in
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
                        Text(subtitle(for: record))
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
                        renameText = record.name
                        recordToRename = record
                    } label: {
                        Label(L.t("Rename", "Đổi tên"), systemImage: "pencil")
                    }
                }
            }
        }
        .navigationDestination(for: ScanRecord.self) { record in
            ScanDetailView(record: record)
        }
    }

    private func subtitle(for record: ScanRecord) -> String {
        var parts = [
            L.t("\(record.roomCount) room(s)", "\(record.roomCount) phòng"),
            record.createdAt.formatted(date: .abbreviated, time: .shortened),
        ]
        if let area = record.areaSqm, area > 0 {
            parts.insert(String(format: "%.0f m²", area), at: 1)
        }
        return parts.joined(separator: " · ")
    }

    private var scanButton: some View {
        Button {
            isScanning = true
        } label: {
            Label(L.t("New scan", "Quét không gian mới"), systemImage: "viewfinder")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!isSupported)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }
}
