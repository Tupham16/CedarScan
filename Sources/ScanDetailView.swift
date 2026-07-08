import SwiftUI
import RoomPlan
import AVKit

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
    @State private var showLowQualityConfirm = false
    @AppStorage("autoStraighten") private var autoStraighten = true

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
            if current.isVideoOnly {
                videoTab
            } else {
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
            guard !current.isVideoOnly else { return }
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
            OrderSheet(
                record: current,
                projectName: store.project(with: current.projectId)?.name
            ) { orderNumber in
                store.setOrderNumber(current, orderNumber: orderNumber)
            }
        }
        // Chặn mềm: chất lượng thấp → khuyên quét lại nhưng vẫn cho gửi (đội vẽ được báo trước)
        .confirmationDialog(
            L.t("Scan quality is low", "Chất lượng bản quét thấp"),
            isPresented: $showLowQualityConfirm,
            titleVisibility: .visible
        ) {
            Button(L.t("Order anyway", "Vẫn đặt hàng")) {
                proceedUploadOrOrder()
            }
            Button(L.t("I'll rescan first", "Để tôi quét lại"), role: .cancel) {}
        } message: {
            Text(L.t(
                "This scan scored \(current.qualityScore ?? 0)/100. Rescanning usually gives a more accurate floor plan. You can still order — our team will be notified about the quality.",
                "Bản quét này được \(current.qualityScore ?? 0)/100 điểm. Quét lại thường cho bản vẽ chính xác hơn. Bạn vẫn có thể đặt — đội xử lý sẽ được báo trước về chất lượng."
            ))
        }
    }

    // MARK: - Dịch vụ Cedar247

    @ViewBuilder
    private var serviceCard: some View {
        VStack(spacing: 8) {
            if let score = current.qualityScore, let grade = current.qualityGrade {
                HStack(spacing: 8) {
                    Image(systemName: current.qualityRescan == true
                        ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .foregroundStyle(gradeColor(grade))
                    Text(L.t("Scan quality: \(score)/100 (\(grade))", "Chất lượng quét: \(score)/100 (\(grade))"))
                        .font(.caption.weight(.semibold))
                    if current.qualityRescan == true {
                        Text(L.t("· rescan recommended", "· nên quét lại"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                }
            }
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
            } else if account.needsVerification {
                HStack(spacing: 8) {
                    Image(systemName: "envelope.badge")
                        .foregroundStyle(.orange)
                    Text(L.t(
                        "Verify your email (Account tab) to place an order.",
                        "Xác minh email (mục Tài khoản) để đặt hàng."
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
        if current.qualityRescan == true && current.cloudOrderNumber == nil {
            showLowQualityConfirm = true
            return
        }
        proceedUploadOrOrder()
    }

    private func proceedUploadOrOrder() {
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

    private func gradeColor(_ grade: String) -> Color {
        switch grade {
        case "A": return .green
        case "B": return .blue
        case "C": return .orange
        default: return .red
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
            let model = FloorPlanModel(rooms: rooms, straighten: autoStraighten)
            VStack(spacing: 8) {
                HStack {
                    if model.areaSquareMeters > 0 {
                        Text(String(format: L.t("Floor area: %.1f m²", "Diện tích sàn: %.1f m²"), model.areaSquareMeters))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(isOn: $autoStraighten) {
                        Text(L.t("Straighten", "Nắn thẳng"))
                            .font(.caption)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .fixedSize()
                }
                .padding(.horizontal)
                ZoomableView {
                    FloorPlanCanvas(model: model)
                }
            }
        }
    }

    /// Bản quét video: xem lại video + lưu ý độ chính xác.
    private var videoTab: some View {
        VStack(spacing: 10) {
            if FileManager.default.fileExists(atPath: videoURL.path) {
                VideoPlayer(player: AVPlayer(url: videoURL))
            } else {
                unavailableView(L.t("Video file not found", "Không tìm thấy file video"))
            }
            Label(
                L.t(
                    "Video walkthrough — measurements will be less accurate than a LiDAR scan.",
                    "Bản quay video — số đo sẽ kém chính xác hơn quét LiDAR."
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
    }

    private var shareMenu: some View {
        Menu {
            if current.isVideoOnly {
                ShareLink(item: videoURL) {
                    Label(L.t("Share video", "Chia sẻ video"), systemImage: "video")
                }
            } else {
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
            }
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
        let model = FloorPlanModel(rooms: rooms, straighten: autoStraighten)
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
    @EnvironmentObject private var store: ScanStore
    let record: ScanRecord
    var projectName: String? = nil // tên dự án/địa chỉ nhà — hiện trên thẻ đơn cho đội xử lý
    var candidateScans: [ScanRecord]? = nil // chế độ dự án: danh sách tầng, chọn sẵn tất cả
    let onOrdered: (String) -> Void

    @State private var catalog: CatalogResponse?
    @State private var loadError: String?

    @State private var packageId = ""
    @State private var selectedAddons: Set<String> = []
    @State private var extraFloors: Set<UUID> = []
    @State private var unitSystem = "metric"
    @State private var language = "English"
    @State private var floorNaming = ""
    @State private var notes = ""
    @State private var couponCode = ""

    @State private var isBusy = false
    @State private var busyLabel: String?
    @State private var errorMessage: String?
    @State private var placedOrder: OrderScanResponse?
    @State private var showTourPhotos = false // mở màn thêm ảnh Virtual Tour ngay sau khi đặt

    /// Các bản quét khác (tầng khác của CÙNG căn nhà) có thể gộp vào đơn này.
    private var otherScans: [ScanRecord] {
        if let candidateScans {
            return candidateScans.filter { $0.id != record.id }
        }
        return store.records.filter {
            $0.id != record.id && $0.cloudOrderNumber == nil && $0.projectId == record.projectId
        }
    }

    private var combinedAreaSqm: Double {
        (record.areaSqm ?? 0)
            + otherScans
                .filter { extraFloors.contains($0.id) }
                .reduce(0) { $0 + ($1.areaSqm ?? 0) }
    }

    private var areaSqFt: Double { combinedAreaSqm * 10.7639 }

    /// Đơn có chứa bản quét CHỈ VIDEO (không LiDAR) → nhắc độ chính xác.
    private var selectionHasVideoScan: Bool {
        record.isVideoOnly || otherScans.contains { extraFloors.contains($0.id) && $0.isVideoOnly }
    }

    private var isFreePromo: Bool {
        (catalog?.freeOrdersRemaining ?? 0) > 0
    }

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
        // Chế độ dự án: chọn sẵn TẤT CẢ các tầng của căn nhà
        if candidateScans != nil && extraFloors.isEmpty {
            extraFloors = Set(otherScans.map(\.id))
        }
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
            if isFreePromo, let remaining = catalog.freeOrdersRemaining, let totalFree = catalog.freeFirstOrders {
                Section {
                    Label {
                        Text(L.t(
                            "This order is FREE! New customers get their first \(totalFree) orders free (\(remaining) left).",
                            "Đơn này MIỄN PHÍ! Khách mới được miễn phí \(totalFree) đơn đầu (còn \(remaining) lượt)."
                        ))
                        .font(.subheadline.weight(.semibold))
                    } icon: {
                        Text("🎁")
                    }
                    .foregroundStyle(.green)
                }
            }
            Section {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(record.name)
                    Spacer()
                    if let area = record.areaSqm, area > 0 {
                        Text(String(format: "%.0f m²", area))
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(otherScans) { scan in
                    Toggle(isOn: Binding(
                        get: { extraFloors.contains(scan.id) },
                        set: { on in
                            if on { extraFloors.insert(scan.id) } else { extraFloors.remove(scan.id) }
                        }
                    )) {
                        HStack {
                            Text(scan.name)
                            Spacer()
                            if let area = scan.areaSqm, area > 0 {
                                Text(String(format: "%.0f m²", area))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text(L.t("Floors in this order", "Các tầng trong đơn này"))
            } footer: {
                if !otherScans.isEmpty && extraFloors.isEmpty {
                    // Nhắc NỔI BẬT: gộp tầng = 1 giá cho cả căn — đừng đặt lẻ từng tầng!
                    Label {
                        Text(L.t(
                            "TIP: One order covers the WHOLE home — select the other floors above instead of ordering them separately!",
                            "MẸO: MỘT đơn tính giá cho CẢ căn nhà — hãy chọn thêm các tầng ở trên thay vì đặt lẻ từng tầng!"
                        ))
                        .font(.footnote.weight(.semibold))
                    } icon: {
                        Text("💡")
                    }
                    .foregroundStyle(.blue)
                } else {
                    Text(otherScans.isEmpty
                        ? L.t(
                            "Scan each floor separately (name them Floor 1, Floor 2…), then order them together here as one home.",
                            "Quét từng tầng riêng (đặt tên Floor 1, Floor 2…) rồi gộp vào một đơn tại đây."
                        )
                        : L.t(
                            "Select the other floors of the same home to order everything together. Total area: \(Int(combinedAreaSqm)) m².",
                            "Chọn các tầng khác của cùng căn nhà để đặt chung một đơn. Tổng diện tích: \(Int(combinedAreaSqm)) m²."
                        ))
                }
            }

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
            } footer: {
                if selectedAddons.contains("tour") {
                    Text(L.t(
                        "🏠 Virtual Tour: after ordering you'll add 1–3 photos per room — we pin them on your floor plan and you get a shareable interactive tour link.",
                        "🏠 Virtual Tour: sau khi đặt, bạn thêm 1–3 ảnh cho mỗi phòng — đội ngũ ghim ảnh lên mặt bằng và bạn nhận link tour tương tác để chia sẻ."
                    ))
                }
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
                TextField(L.t("Coupon code (optional)", "Mã giảm giá (không bắt buộc)"), text: $couponCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            } footer: {
                Text(L.t("The discount is applied on the payment page.", "Giảm giá được áp dụng ở trang thanh toán."))
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
                if selectionHasVideoScan {
                    Label(
                        L.t(
                            "This order includes video-only scans — measurements will be LESS accurate than LiDAR scans.",
                            "Đơn này có bản quay video — số đo sẽ KÉM chính xác hơn quét LiDAR."
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
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
                            if let busyLabel {
                                Text(busyLabel).font(.subheadline)
                            }
                        } else {
                            Text(L.t("Place order", "Đặt hàng") + " · " + (isFreePromo ? L.t("FREE 🎁", "MIỄN PHÍ 🎁") : "$\(totalUSD)"))
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
            if order.free == true {
                Text(L.t("FREE — first-orders promo 🎁", "MIỄN PHÍ — khuyến mãi đơn đầu 🎁"))
                    .font(.headline)
                    .foregroundStyle(.green)
            } else if let total = order.total {
                Text(L.t("Total: $\(total)", "Tổng tiền: $\(total)"))
                    .font(.headline)
            }
            if let discount = order.discount, discount > 0 {
                Text(L.t("Coupon applied: −$\(String(format: "%.2f", discount))",
                         "Đã áp mã giảm: −$\(String(format: "%.2f", discount))"))
                    .font(.subheadline)
                    .foregroundStyle(.green)
            } else if order.couponApplied == false {
                Text(L.t("Coupon code was not valid — full price applies.",
                         "Mã giảm giá không hợp lệ — tính giá đầy đủ."))
                    .font(.footnote)
                    .foregroundStyle(.orange)
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
            } else if order.free != true {
                Text(L.t(
                    "We will email you a payment link shortly.",
                    "Link thanh toán sẽ được gửi qua email trong ít phút."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            // Đơn có Virtual Tour → mời khách thêm ảnh phòng ngay (làm sớm = giao sớm)
            if order.hasTour == true {
                Button {
                    showTourPhotos = true
                } label: {
                    Label(L.t("Add room photos for your tour", "Thêm ảnh phòng cho tour"),
                          systemImage: "photo.on.rectangle.angled")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.indigo)
                .padding(.horizontal)
                Text(L.t(
                    "1–3 photos per room. You can also add them later in the Orders tab.",
                    "1–3 ảnh mỗi phòng. Bạn cũng có thể thêm sau ở mục Đơn hàng."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .sheet(isPresented: $showTourPhotos) {
            if let placedOrder {
                TourPhotosView(orderId: placedOrder.orderId)
            }
        }
    }

    private func submit() {
        isBusy = true
        errorMessage = nil
        let extras = otherScans.filter { extraFloors.contains($0.id) }
        Task {
            // Tải lên mọi bản quét CHƯA có trên server (kể cả bản chính — khi đặt từ trang dự án)
            @MainActor
            func ensureUploaded(_ scan: ScanRecord) async -> String? {
                if let existing = scan.cloudScanId { return existing }
                busyLabel = L.t("Uploading \(scan.name)…", "Đang tải \(scan.name)…")
                let uploader = ScanUploader()
                if let cloudId = await uploader.upload(record: scan, folder: store.folderURL(for: scan)) {
                    store.setCloudScanId(scan, cloudScanId: cloudId)
                    return cloudId
                }
                if case .failed(let message) = uploader.phase {
                    errorMessage = "\(scan.name): \(message)"
                } else {
                    errorMessage = L.t("Could not upload \(scan.name).", "Không tải được \(scan.name).")
                }
                return nil
            }

            guard let primaryCloudId = await ensureUploaded(record) else {
                isBusy = false
                busyLabel = nil
                return
            }
            var extraCloudIds: [String] = []
            for extra in extras {
                guard let cloudId = await ensureUploaded(extra) else {
                    isBusy = false
                    busyLabel = nil
                    return
                }
                extraCloudIds.append(cloudId)
            }

            busyLabel = L.t("Placing order…", "Đang đặt hàng…")
            do {
                let result = try await APIClient.shared.orderScan(
                    scanId: primaryCloudId,
                    extraScanIds: extraCloudIds,
                    packageId: packageId,
                    addonIds: Array(selectedAddons),
                    notes: notes,
                    unitSystem: unitSystem,
                    language: language,
                    floorNaming: floorNaming,
                    projectName: projectName ?? "",
                    coupon: couponCode.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                placedOrder = result
                onOrdered(result.orderNumber)
                for extra in extras {
                    store.setOrderNumber(extra, orderNumber: result.orderNumber)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
            busyLabel = nil
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
