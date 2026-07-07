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

// MARK: - Form đặt hàng (kiểu CubiCasa: gói + add-on + giá, lưu mặc định cho lần sau)

struct OrderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let record: ScanRecord
    let onOrdered: (String) -> Void

    @State private var catalog: CatalogResponse?
    @State private var loadError: String?

    @State private var packageId = ""
    @State private var selectedAddons: Set<String> = []
    @State private var unitSystem = "metric"
    @State private var language = "English"
    @State private var floorNaming = ""
    @State private var notes = ""

    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var placedOrder: OrderScanResponse?

    private var areaSqFt: Double { (record.areaSqm ?? 0) * 10.7639 }

    private var totalUSD: Int {
        guard let catalog else { return 0 }
        var total = catalog.packages.first(where: { $0.id == packageId })?.price ?? 0
        for addon in catalog.addons where selectedAddons.contains(addon.id) {
            total += addon.price
        }
        if let surcharge = catalog.areaSurcharges
            .filter({ areaSqFt > $0.overSqFt && $0.fee > 0 })
            .max(by: { $0.overSqFt < $1.overSqFt }) {
            total += surcharge.fee
        }
        return total
    }

    var body: some View {
        NavigationStack {
            Group {
                if let placedOrder {
                    successView(placedOrder)
                } else if let catalog {
                    orderForm(catalog)
                } else if let loadError {
                    VStack(spacing: 12) {
                        Text(loadError)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(L.t("Retry", "Thử lại")) {
                            self.loadError = nil
                            Task { await loadCatalog() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(24)
                } else {
                    ProgressView(L.t("Loading options…", "Đang tải bảng giá…"))
                }
            }
            .navigationTitle(L.t("Order Floor Plan", "Đặt làm mặt bằng"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(placedOrder == nil ? L.t("Cancel", "Hủy") : L.t("Close", "Đóng")) {
                        dismiss()
                    }
                }
            }
            .task {
                await loadCatalog()
            }
        }
    }

    private func loadCatalog() async {
        do {
            let result = try await APIClient.shared.catalog()
            catalog = result
            // Điền mặc định: lựa chọn lần trước > gói default > gói đầu
            let d = result.defaults
            if let saved = d?.packageId, result.packages.contains(where: { $0.id == saved }) {
                packageId = saved
            } else {
                packageId = result.packages.first(where: { $0.isDefault })?.id
                    ?? result.packages.first?.id ?? ""
            }
            let validAddonIds = Set(result.addons.map(\.id))
            selectedAddons = Set((d?.addonIds ?? []).filter { validAddonIds.contains($0) })
            if let u = d?.unitSystem, u == "imperial" || u == "metric" { unitSystem = u }
            if let lang = d?.language, !lang.isEmpty { language = lang }
            if let fn = d?.floorNaming { floorNaming = fn }
        } catch {
            loadError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func orderForm(_ catalog: CatalogResponse) -> some View {
        Form {
            Section {
                ForEach(catalog.packages) { pkg in
                    Button {
                        packageId = pkg.id
                    } label: {
                        HStack {
                            Image(systemName: packageId == pkg.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(.tint)
                            Text(pkg.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("$\(pkg.price)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(L.t("Package", "Gói dịch vụ"))
            }

            Section {
                ForEach(catalog.addons) { addon in
                    Toggle(isOn: Binding(
                        get: { selectedAddons.contains(addon.id) },
                        set: { on in
                            if on { selectedAddons.insert(addon.id) } else { selectedAddons.remove(addon.id) }
                        }
                    )) {
                        HStack {
                            Text(addon.name)
                            Spacer()
                            Text("+$\(addon.price)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(L.t("Add-ons", "Dịch vụ thêm"))
            }

            Section {
                Picker(L.t("Units", "Đơn vị đo"), selection: $unitSystem) {
                    Text(L.t("Metric (m)", "Mét (m)")).tag("metric")
                    Text(L.t("Imperial (ft)", "Feet (ft)")).tag("imperial")
                }
                TextField(L.t("Language (e.g. English)", "Ngôn ngữ bản vẽ (vd English)"), text: $language)
                TextField(L.t("Floor naming style (optional)", "Kiểu đặt tên tầng (không bắt buộc)"), text: $floorNaming)
                TextField(
                    L.t("Anything we should know? (optional)", "Ghi chú thêm (không bắt buộc)"),
                    text: $notes,
                    axis: .vertical
                )
                .lineLimit(3...6)
            } header: {
                Text(L.t("Preferences (saved for next time)", "Tùy chọn (lưu cho lần sau)"))
            }

            Section {
                if let surcharge = catalog.areaSurcharges
                    .filter({ areaSqFt > $0.overSqFt && $0.fee > 0 })
                    .max(by: { $0.overSqFt < $1.overSqFt }) {
                    HStack {
                        Text(L.t(
                            "Large property fee (over \(Int(surcharge.overSqFt)) sq ft)",
                            "Phụ phí nhà lớn (trên \(Int(surcharge.overSqFt)) sq ft)"
                        ))
                        .font(.footnote)
                        Spacer()
                        Text("+$\(surcharge.fee)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Button {
                    submit()
                } label: {
                    HStack {
                        if isBusy {
                            ProgressView().tint(.white)
                        } else {
                            Text(L.t("Place order", "Đặt hàng") + " · $\(totalUSD)")
                                .font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets())
                .disabled(isBusy || packageId.isEmpty)
            } footer: {
                Text(L.t(
                    "You will get a secure payment link (Stripe/PayPal) after placing the order.",
                    "Sau khi đặt sẽ có link thanh toán bảo mật (Stripe/PayPal)."
                ))
            }
        }
    }

    @ViewBuilder
    private func successView(_ order: OrderScanResponse) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
            Text(L.t("Order placed!", "Đã đặt hàng!"))
                .font(.title3.weight(.bold))
            Text(order.orderNumber)
                .font(.title3.monospaced().weight(.bold))
            if let total = order.total {
                Text(L.t("Total: $\(total)", "Tổng tiền: $\(total)"))
                    .font(.headline)
            }
            Text(L.t(
                "Our team will start after payment is received. Track progress in the Orders tab.",
                "Đội ngũ Cedar247 sẽ bắt đầu sau khi nhận thanh toán. Theo dõi tiến độ ở mục Đơn hàng."
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)

            if let payString = order.paymentUrl, let payURL = URL(string: payString) {
                Button {
                    openURL(payURL)
                } label: {
                    Label(L.t("Pay Now", "Thanh toán ngay"), systemImage: "creditcard.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
            } else {
                Text(L.t(
                    "We will email you a payment link shortly.",
                    "Link thanh toán sẽ được gửi qua email trong ít phút."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .padding(24)
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
                    packageId: packageId,
                    addonIds: Array(selectedAddons),
                    notes: notes,
                    unitSystem: unitSystem,
                    language: language,
                    floorNaming: floorNaming
                )
                placedOrder = result
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
