import SwiftUI
import RoomPlan

struct ScanDetailView: View {
    let record: ScanRecord
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var account: AccountStore
    @StateObject private var uploader = ScanUploader()

    @State private var mode = 0
    @State private var rooms: [CapturedRoom] = []
    @State private var planImageURL: URL?
    @State private var loadFailed = false
    @State private var showOrderSheet = false

    /// Bản ghi mới nhất từ store (record truyền vào có thể cũ sau khi upload/đặt hàng).
    private var current: ScanRecord {
        store.records.first(where: { $0.id == record.id }) ?? record
    }

    private var folder: URL { store.folderURL(for: record) }
    private var usdzURL: URL { store.usdzURL(for: record) }
    private var videoURL: URL { folder.appendingPathComponent("scan-video.mp4") }
    private var objURL: URL { folder.appendingPathComponent("model.obj") }
    private var planURL: URL { folder.appendingPathComponent("floorplan.png") }

    var body: some View {
        VStack(spacing: 0) {
            Picker(L.t("View mode", "Chế độ xem"), selection: $mode) {
                Text(L.t("3D Model", "Mô hình 3D")).tag(0)
                Text(L.t("Floor Plan", "Mặt bằng 2D")).tag(1)
            }
            .pickerStyle(.segmented)
            .padding()

            if mode == 0 {
                if FileManager.default.fileExists(atPath: usdzURL.path) {
                    USDZPreview(url: usdzURL)
                } else {
                    unavailableView(L.t("3D model file not found", "Không tìm thấy file mô hình 3D"))
                }
            } else {
                floorPlanTab
            }
        }
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                shareMenu
            }
        }
        .safeAreaInset(edge: .bottom) {
            serviceCard
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
        .sheet(isPresented: $showOrderSheet) {
            OrderSheet(record: current) { orderNumber in
                store.setOrderNumber(current, orderNumber: orderNumber)
            }
        }
    }

    // MARK: - Dịch vụ Cedar247

    @ViewBuilder
    private var serviceCard: some View {
        VStack(spacing: 8) {
            if let orderNumber = current.cloudOrderNumber {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox.fill")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("Floor plan ordered", "Đã đặt làm mặt bằng") + " · \(orderNumber)")
                            .font(.subheadline.weight(.semibold))
                        Text(L.t("Track progress in the Orders tab.", "Theo dõi tiến độ ở mục Đơn hàng."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            } else if !account.isSignedIn {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                    Text(L.t(
                        "Sign in (Account tab) to order a professional floor plan from this scan.",
                        "Đăng nhập (mục Tài khoản) để đặt làm bản vẽ mặt bằng chuyên nghiệp từ bản quét này."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                switch uploader.phase {
                case .idle, .failed:
                    if case .failed(let message) = uploader.phase {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Button {
                        startUploadOrOrder()
                    } label: {
                        Label(
                            current.cloudScanId == nil
                                ? L.t("Order Floor Plan", "Đặt làm mặt bằng")
                                : L.t("Order Floor Plan", "Đặt làm mặt bằng"),
                            systemImage: "paperplane.fill"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                case .preparing:
                    progressRow(L.t("Preparing upload…", "Đang chuẩn bị…"), nil)
                case .uploading(let fileName, let index, let total, let fraction):
                    progressRow(
                        L.t("Uploading \(fileName) (\(index)/\(total))", "Đang tải \(fileName) (\(index)/\(total))"),
                        fraction
                    )
                case .finishing:
                    progressRow(L.t("Finishing…", "Đang hoàn tất…"), nil)
                case .done:
                    Button {
                        showOrderSheet = true
                    } label: {
                        Label(L.t("Order Floor Plan", "Đặt làm mặt bằng"), systemImage: "paperplane.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func progressRow(_ label: String, _ fraction: Double?) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                Spacer()
                if let fraction {
                    Text("\(Int(fraction * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
        }
    }

    private func startUploadOrOrder() {
        if current.cloudScanId != nil {
            showOrderSheet = true
            return
        }
        Task {
            if let cloudId = await uploader.upload(record: current, folder: folder) {
                store.setCloudScanId(current, cloudScanId: cloudId)
                showOrderSheet = true
            }
        }
    }

    // MARK: - Mặt bằng

    @ViewBuilder
    private var floorPlanTab: some View {
        if rooms.isEmpty {
            unavailableView(loadFailed
                ? L.t("Could not load scan data", "Không đọc được dữ liệu quét")
                : L.t("Loading…", "Đang tải…"))
        } else {
            let model = FloorPlanModel(rooms: rooms)
            VStack(spacing: 8) {
                if model.areaSquareMeters > 0 {
                    Text(String(format: L.t("Floor area: %.1f m²", "Diện tích sàn: %.1f m²"), model.areaSquareMeters))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ZoomableView {
                    FloorPlanCanvas(model: model)
                }
            }
        }
    }

    private var shareMenu: some View {
        Menu {
            ShareLink(item: usdzURL) {
                Label(L.t("Share 3D model (USDZ)", "Chia sẻ mô hình 3D (USDZ)"), systemImage: "cube")
            }
            // OBJ + video là NGUYÊN LIỆU NỘI BỘ (gửi về đội xử lý qua đơn hàng), không cho khách chia sẻ.
            Button {
                exportFloorPlanImage()
            } label: {
                Label(L.t("Share floor plan (PNG)", "Chia sẻ ảnh mặt bằng (PNG)"), systemImage: "photo")
            }
            .disabled(rooms.isEmpty && !FileManager.default.fileExists(atPath: planURL.path))
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
        if FileManager.default.fileExists(atPath: planURL.path) {
            planImageURL = planURL
            return
        }
        let model = FloorPlanModel(rooms: rooms)
        let exportView = FloorPlanExportView(model: model, title: current.name)
            .frame(width: 1400, height: 1600)
        let renderer = ImageRenderer(content: exportView)
        renderer.scale = 2
        guard let image = renderer.uiImage, let data = image.pngData() else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorPlan-\(record.id.uuidString.prefix(6)).png")
        do {
            try data.write(to: url)
            planImageURL = url
        } catch {
            // Ghi file tạm thất bại thì bỏ qua, menu vẫn dùng lại được.
        }
    }
}

// MARK: - Form đặt hàng

struct OrderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let record: ScanRecord
    let onOrdered: (String) -> Void

    @State private var notes = ""
    @State private var unitSystem = "metric"
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var orderNumber: String?

    var body: some View {
        NavigationStack {
            Form {
                if let orderNumber {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.green)
                            Text(L.t("Order placed!", "Đã đặt hàng!"))
                                .font(.headline)
                            Text(orderNumber)
                                .font(.title3.monospaced().weight(.bold))
                            Text(L.t(
                                "Our team will review your scan and produce the floor plan. Track progress in the Orders tab.",
                                "Đội ngũ Cedar247 sẽ xử lý bản quét và vẽ mặt bằng. Theo dõi tiến độ ở mục Đơn hàng."
                            ))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                } else {
                    Section {
                        Picker(L.t("Units", "Đơn vị đo"), selection: $unitSystem) {
                            Text(L.t("Metric (m)", "Mét (m)")).tag("metric")
                            Text(L.t("Imperial (ft)", "Feet (ft)")).tag("imperial")
                        }
                    } header: {
                        Text(L.t("Floor plan options", "Tùy chọn bản vẽ"))
                    }
                    Section {
                        TextField(
                            L.t("Anything we should know? (optional)", "Ghi chú thêm (không bắt buộc)"),
                            text: $notes,
                            axis: .vertical
                        )
                        .lineLimit(3...6)
                    } header: {
                        Text(L.t("Notes", "Ghi chú"))
                    }
                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle(L.t("Order Floor Plan", "Đặt làm mặt bằng"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(orderNumber == nil ? L.t("Cancel", "Hủy") : L.t("Close", "Đóng")) {
                        dismiss()
                    }
                }
                if orderNumber == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            submit()
                        } label: {
                            if isBusy {
                                ProgressView()
                            } else {
                                Text(L.t("Order", "Đặt hàng")).bold()
                            }
                        }
                        .disabled(isBusy)
                    }
                }
            }
        }
    }

    private func submit() {
        guard let cloudScanId = record.cloudScanId else {
            errorMessage = L.t("Scan is not uploaded yet.", "Bản quét chưa được tải lên.")
            return
        }
        isBusy = true
        errorMessage = nil
        Task {
            do {
                let result = try await APIClient.shared.orderScan(
                    scanId: cloudScanId,
                    notes: notes,
                    unitSystem: unitSystem
                )
                orderNumber = result.orderNumber
                onOrdered(result.orderNumber)
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
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
