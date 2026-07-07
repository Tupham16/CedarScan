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
            .alert("Đổi tên bản quét", isPresented: renameAlertBinding) {
                TextField("Tên mới", text: $renameText)
                Button("Lưu") {
                    if let record = recordToRename {
                        store.rename(record, to: renameText)
                    }
                    recordToRename = nil
                }
                Button("Hủy", role: .cancel) { recordToRename = nil }
            }
            .alert("Lỗi khi lưu", isPresented: saveErrorBinding) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .fullScreenCover(isPresented: $isScanning) {
                ScanFlowView { rooms in
                    do {
                        _ = try await store.save(rooms: rooms)
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
            Text("Chưa có bản quét nào")
                .font(.title3.weight(.semibold))
            Text(isSupported
                 ? "Bấm nút bên dưới để quét không gian đầu tiên. Đi chậm quanh phòng, hướng camera vào tường, cửa và đồ đạc."
                 : "Thiết bị này không có cảm biến LiDAR nên không quét được. Cần iPhone Pro (12 Pro trở lên) hoặc iPad Pro.")
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
                        Text(record.name)
                            .font(.headline)
                        Text("\(record.roomCount) phòng · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        store.delete(record)
                    } label: {
                        Label("Xóa", systemImage: "trash")
                    }
                    Button {
                        renameText = record.name
                        recordToRename = record
                    } label: {
                        Label("Đổi tên", systemImage: "pencil")
                    }
                }
            }
        }
        .navigationDestination(for: ScanRecord.self) { record in
            ScanDetailView(record: record)
        }
    }

    private var scanButton: some View {
        Button {
            isScanning = true
        } label: {
            Label("Quét không gian mới", systemImage: "viewfinder")
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
