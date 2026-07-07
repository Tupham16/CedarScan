import SwiftUI
import RoomPlan

struct ScanDetailView: View {
    let record: ScanRecord
    @EnvironmentObject private var store: ScanStore

    @State private var mode = 0
    @State private var rooms: [CapturedRoom] = []
    @State private var planImageURL: URL?
    @State private var loadFailed = false

    private var usdzURL: URL { store.usdzURL(for: record) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Chế độ xem", selection: $mode) {
                Text("Mô hình 3D").tag(0)
                Text("Mặt bằng 2D").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()

            if mode == 0 {
                if FileManager.default.fileExists(atPath: usdzURL.path) {
                    USDZPreview(url: usdzURL)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    unavailableView("Không tìm thấy file mô hình 3D")
                }
            } else {
                floorPlanTab
            }
        }
        .navigationTitle(record.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                shareMenu
            }
        }
        .task {
            do {
                rooms = try store.loadRooms(for: record)
            } catch {
                loadFailed = true
            }
        }
        .sheet(item: $planImageURL) { url in
            ShareSheet(items: [url])
        }
    }

    @ViewBuilder
    private var floorPlanTab: some View {
        if rooms.isEmpty {
            unavailableView(loadFailed ? "Không đọc được dữ liệu quét" : "Đang tải…")
        } else {
            let model = FloorPlanModel(rooms: rooms)
            VStack(spacing: 8) {
                if model.areaSquareMeters > 0 {
                    Text(String(format: "Diện tích sàn: %.1f m²", model.areaSquareMeters))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ZoomableView {
                    FloorPlanCanvas(model: model)
                }
            }
            .padding(.bottom)
        }
    }

    private var shareMenu: some View {
        Menu {
            ShareLink(item: usdzURL) {
                Label("Chia sẻ mô hình 3D (USDZ)", systemImage: "cube")
            }
            Button {
                exportFloorPlanImage()
            } label: {
                Label("Chia sẻ ảnh mặt bằng (PNG)", systemImage: "photo")
            }
            .disabled(rooms.isEmpty)
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
    }

    private func unavailableView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    private func exportFloorPlanImage() {
        let model = FloorPlanModel(rooms: rooms)
        let exportView = FloorPlanExportView(model: model, title: record.name)
            .frame(width: 1400, height: 1600)
        let renderer = ImageRenderer(content: exportView)
        renderer.scale = 2
        guard let image = renderer.uiImage, let data = image.pngData() else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatBang-\(record.id.uuidString.prefix(6)).png")
        do {
            try data.write(to: url)
            planImageURL = url
        } catch {
            // Ghi file tạm thất bại thì bỏ qua, menu vẫn dùng lại được.
        }
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}

/// Cho phép phóng to / kéo mặt bằng bằng hai ngón tay.
struct ZoomableView<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1

    var body: some View {
        content
            .scaleEffect(zoom)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        zoom = min(max(lastZoom * value, 1), 6)
                    }
                    .onEnded { _ in
                        lastZoom = zoom
                    }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }
}
