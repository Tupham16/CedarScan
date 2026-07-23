import SwiftUI
import AVKit
import UniformTypeIdentifiers // UTType — suy ra MIME + giới hạn loại file cho .fileImporter
// UIKit tường minh cho `UIImage`. SwiftUI/AVKit vẫn kéo UIKit vào (`UIApplication` ở
// MeshScanFlowView chỉ với SwiftUI+ARKit là tiền lệ đang build xanh), nhưng file này vừa mất
// `import RoomPlan` — dựa vào một import gián tiếp mà mình không kiểm soát là thứ chỉ phát hiện
// được sau 10 phút CI.
import UIKit

struct ScanDetailView: View {
    let record: ScanRecord
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var uploader = ScanUploader()

    @State private var mode = 0
    @State private var planImageURL: URL?
    /// Ảnh mặt bằng của bản quét RoomPlan CŨ, đọc từ floorplan.png trên đĩa. Nạp MỘT LẦN vào
    /// state chứ không gọi trong body: body dựng lại nhiều lần mỗi giây suốt lúc upload.
    @State private var legacyPlanImage: UIImage?
    /// Trình phát video, dựng MỘT LẦN trong `.task`.
    ///
    /// Trước đây là `VideoPlayer(player: AVPlayer(url: videoURL))` viết thẳng trong body → mỗi
    /// lần SwiftUI dựng lại body là một AVPlayer MỚI, tức video nhảy về giây 0. Nó âm ỉ vì hiếm
    /// khi có gì làm body chạy lại; nhưng từ 2026-07-20 "Đặt hàng ngay" đẩy khách THẲNG vào đây
    /// và việc đầu tiên họ làm là bấm đặt — `uploader.phase` bắn `.uploading(fraction:)` mỗi nhịp
    /// tiến độ, tức body dựng lại nhiều lần mỗi giây suốt lúc tải 40–200MB.
    @State private var player: AVPlayer?
    @State private var showOrderSheet = false
    /// Cổng đăng nhập/xác minh mở tại chỗ — xem `AccountGateSheet`.
    @State private var showAccountGate = false
    @State private var showLowQualityConfirm = false
    @State private var coloredZipExists = false
    @State private var coloredGLBExists = false
    /// Bản sao zip mang TÊN BẢN QUÉT để chia sẻ ra ngoài (Floor 1.zip thay vì
    /// model-colored.zip). nil → dùng file gốc.
    @State private var meshShareURL: URL?

    /// Bản ghi mới nhất từ store (record truyền vào có thể cũ sau khi upload/đặt hàng).
    ///
    /// `?? record` là bản chụp GIÁ TRỊ lúc push (NavigationPath giữ nó, không phụ thuộc store),
    /// nên khi bản quét bị dọn mất thì màn này vẫn render dữ liệu cũ như không có chuyện gì —
    /// xem `stillExists` bên dưới.
    private var current: ScanRecord {
        store.records.first(where: { $0.id == record.id }) ?? record
    }

    /// Bản quét còn trong store không. Việc dọn-sau-khi-giao (RootView.purgeDeliveredScans) có
    /// thể nổ ngay dưới chân màn này: app quay lại foreground trong lúc khách đang mở chi tiết.
    /// Không tự đóng thì họ ngồi nhìn một bản quét mà mọi file đã biến mất — bấm gì cũng hỏng.
    private var stillExists: Bool {
        store.records.contains { $0.id == record.id }
    }

    private var folder: URL { store.folderURL(for: record) }
    private var usdzURL: URL { store.usdzURL(for: record) }
    private var videoURL: URL { folder.appendingPathComponent("scan-video.mp4") }
    private var objURL: URL { folder.appendingPathComponent("model.obj") }
    private var planURL: URL { folder.appendingPathComponent("floorplan.png") }
    private var plyURL: URL { folder.appendingPathComponent("colored-mesh.ply") }
    private var coloredZipURL: URL { folder.appendingPathComponent("model-colored.zip") }
    private var coloredGLBURL: URL { folder.appendingPathComponent("model-colored.glb") }

    var body: some View {
        VStack(spacing: 0) {
            if current.isVideoOnly {
                videoTab
            } else if current.isMeshOnly {
                meshTab
            } else {
                legacyTab
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
            // Tự chừa chỗ cho thanh tab — cùng lý do với `ProjectView`, xem
            // `CedarTabBar.reservedHeight`. Ở đây thứ bị che là NÚT ĐẶT HÀNG trong `serviceCard`,
            // tức đường tiền, nên nó còn đắt hơn ca của ProjectView.
            serviceCard
                .padding(.bottom, CedarTabBar.reservedHeight)
        }
        // Bản quét bị dọn (đơn đã giao) trong lúc màn này đang mở → thoát ra, đừng để khách
        // ngồi trước một bản quét mà mọi file đã biến mất.
        //
        // HOÃN MỘT NHỊP + kiểm lại, cùng lý do với `ProjectView.leaveDeadProject()`: `dismiss()`
        // rơi vào giữa cú push là pop một view controller mà push của nó chưa xong.
        .onChange(of: stillExists) { _, exists in
            guard !exists else { return }
            Task { @MainActor in
                guard !stillExists else { return }
                dismiss()
            }
        }
        // Không pause là video chạy tiếp sau khi rời màn (AVPlayer sống theo @State, không theo
        // view hiển thị) — giữ decoder H.264 và ngốn pin trong lúc khách đã sang chỗ khác.
        .onDisappear {
            player?.pause()
        }
        // Chỉ ĐỌC cờ tồn tại của các file phụ — KHÔNG tự dựng GLB/zip từ PLY nữa. Nhánh mesh đã
        // bỏ việc đó từ trước (vận hành chỉ giữ OBJ + video); từ 2026-07-20 nhánh bản-quét-cũ
        // cũng bỏ, để hai nhánh cùng một luật: màn này CHỈ XEM thứ đã có trên đĩa, không sinh
        // thêm file. Bản cũ nào từng dựng được GLB/zip thì file vẫn nằm đó và vẫn hiện trong
        // menu chia sẻ; bản chưa có thì còn USDZ + ảnh mặt bằng để chia sẻ.
        .task {
            // ⚠ `.task` (không id) KHÔNG phải "chạy một lần theo identity" — SwiftUI huỷ nó ở
            // onDisappear và CHẠY LẠI mỗi lần view appear lại (chuyển sang tab Đơn hàng rồi quay về).
            // Nên mọi việc TỐN KÉM hoặc PHÁ TRẠNG THÁI phải có guard idempotent: không thì `player`
            // dựng mới = video nhảy về giây 0 giữa lúc khách đang xem, và `prepareNamedZip()` copy
            // lại bản zip 40–200MB mỗi lượt quay lại. Các dòng `fileExists` bên dưới rẻ + idempotent
            // nên để nguyên.
            //
            // Dựng player trước mọi nhánh vì bản quét video-only cũng cần, nhưng CHỈ cho hai loại
            // thật sự có khu video: bản quét cũ đời RoomPlan đi vào `legacyTab` (3D + mặt bằng),
            // không có chỗ nào phát video nên cấp phát AVPlayer ở đó là thừa.
            // KHÔNG tự phát — màn này là nơi xem lại theo ý khách, khác màn preview sau khi quét.
            if player == nil, current.isMeshOnly || current.isVideoOnly,
               FileManager.default.fileExists(atPath: videoURL.path) {
                player = AVPlayer(url: videoURL)
            }
            guard !current.isVideoOnly else { return }
            coloredGLBExists = FileManager.default.fileExists(atPath: coloredGLBURL.path)
            coloredZipExists = FileManager.default.fileExists(atPath: coloredZipURL.path)
            if coloredZipExists, meshShareURL == nil {
                meshShareURL = prepareNamedZip()
            }
            guard !current.isMeshOnly else { return }
            // Bản quét RoomPlan cũ: nạp sẵn ảnh mặt bằng đã render từ hồi còn RoomPlan.
            // Gọi thẳng trên main, KHÔNG cần Task.detached: `UIImage(contentsOfFile:)` chỉ đọc
            // header rồi giải mã LƯỜI lúc vẽ (UIKit tự làm việc đó ngoài main), nên nó rẻ.
            // Đẩy sang detached chỉ đổi lấy một câu hỏi Sendable về UIImage mà không được gì.
            if legacyPlanImage == nil {
                legacyPlanImage = UIImage(contentsOfFile: planURL.path)
            }
        }
        .sheet(item: $planImageURL) { url in
            ShareSheet(items: [url])
        }
        .sheet(isPresented: $showOrderSheet) {
            // Không còn callback "đã đặt" ở đây: `OrderSheet.submit()` tự đóng dấu số đơn cho
            // đúng tập bản quét trong đơn. Đừng thêm lại — giải thích ở `OrderSheet.submit()`.
            OrderSheet(
                record: current,
                projectName: store.project(with: current.projectId)?.name
            )
        }
        .sheet(isPresented: $showAccountGate) {
            AccountGateSheet()
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

    /// Dòng "bị chặn vì tài khoản" kèm NÚT mở cổng đăng nhập/xác minh ngay tại chỗ.
    ///
    /// Trước 2026-07-20 đây chỉ là chữ xám cỡ `.caption` bảo khách tự đi tìm "mục Tài khoản" —
    /// không nút, và không code nào trong app chuyển tab được. Khách vừa quét xong 10–30 phút,
    /// bấm "Đặt hàng ngay", rồi nhận đúng một dòng chữ thay cho nút đặt hàng.
    ///
    /// Giữ nguyên dòng chữ giải thích BÊN TRÊN nút chứ không bỏ đi cho gọn: nút "Đăng nhập" đứng
    /// một mình ở màn bản quét không nói được vì sao tự dưng phải đăng nhập, mà lý do ("để đặt
    /// bản vẽ") mới là thứ khiến khách chịu bỏ công gõ email.
    @ViewBuilder
    private func accountGateRow(
        icon: String,
        iconTint: Color,
        message: String,
        action: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconTint)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Button {
                showAccountGate = true
            } label: {
                Text(action)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        }
    }

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
                    // `.tint` chứ không phải `.blue` cứng — xem giải thích ở `HomeView.mainList`.
                    Image(systemName: "shippingbox.fill")
                        .foregroundStyle(.tint)
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
                // Câu chữ đã BỎ phần "(mục Tài khoản)": giờ đã có nút mở thẳng màn đăng nhập ngay
                // tại chỗ, chỉ đường sang tab khác vừa thừa vừa SAI (sheet không chuyển tab).
                accountGateRow(
                    icon: "person.crop.circle.badge.exclamationmark",
                    iconTint: .secondary,
                    message: L.t(
                        "Sign in to order a professional floor plan from this scan.",
                        "Đăng nhập để đặt làm bản vẽ mặt bằng chuyên nghiệp từ bản quét này."
                    ),
                    action: L.t("Sign in", "Đăng nhập")
                )
            } else if account.needsVerification {
                accountGateRow(
                    icon: "envelope.badge",
                    iconTint: .orange,
                    message: L.t(
                        "Verify your email to place an order.",
                        "Xác minh email để đặt hàng."
                    ),
                    action: L.t("Verify email", "Xác minh email")
                )
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
                // KHÔNG in tên file (model-colored.zip / colored-mesh.ply / scan-video.mp4):
                // đó là chuyện nội bộ, khách không cần biết app gửi những gì. Giữ (n/tổng) +
                // thanh tiến độ để khách biết còn phải chờ bao lâu — đó là thứ họ thật sự cần.
                case .uploading(_, let index, let total, let fraction):
                    progressRow(
                        L.t("Sending your scan… (\(index)/\(total))", "Đang gửi bản quét… (\(index)/\(total))"),
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

    // MARK: - Bản quét RoomPlan CŨ (chỉ còn xem lại)

    /// Bản quét đời RoomPlan (`captureType` nil hoặc "lidar"). App KHÔNG tạo được loại này nữa
    /// từ 2026-07-20 — màn này tồn tại CHỈ để khách còn mở/chia sẻ/đặt hàng bản đã có trên máy.
    ///
    /// Giữ nguyên hai tab quen thuộc thay vì rút gọn theo file đang có: bố cục đổi theo dữ liệu
    /// là thứ khách đọc thành "app mất tính năng". Tab nào thiếu file thì nói thẳng ra.
    /// Mặt bằng 2D giờ là ẢNH ĐÃ RENDER SẴN (floorplan.png ghi lúc quét) chứ không vẽ lại bằng
    /// Canvas: dữ liệu để vẽ nằm trong rooms.json và cần `CapturedRoom` của RoomPlan để đọc.
    /// Vì thế nút "Nắn thẳng" cũng biến mất — nắn thẳng là phép tính trên hình học RoomPlan.
    private var legacyTab: some View {
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
                legacyPlanTab
            }
        }
    }

    @ViewBuilder
    private var legacyPlanTab: some View {
        if let image = legacyPlanImage {
            ZoomableView {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            }
        } else if FileManager.default.fileExists(atPath: planURL.path) {
            unavailableView(L.t("Loading…", "Đang tải…"))
        } else {
            // Nói luôn rằng dữ liệu không mất: rooms.json vẫn nằm trong thư mục và vẫn được
            // `ScanUploader` gửi lên (kind "rooms"). Thiếu câu này khách đọc thành "app làm mất dữ liệu".
            unavailableView(L.t(
                "No saved floor plan image. Your scan data is still sent to our drafting team when you order.",
                "Không có ảnh mặt bằng đã lưu. Dữ liệu bản quét vẫn được gửi tới đội vẽ khi bạn đặt hàng."
            ))
        }
    }

    /// Bản quét MESH 3D: video walkthrough + hướng dẫn chia sẻ mô hình màu.
    /// (Không có floorplan/USDZ — mesh màu là sản phẩm chính, xem bằng menu chia sẻ.)
    private var meshTab: some View {
        VStack(spacing: 10) {
            videoArea(missing: L.t("No walkthrough video in this scan", "Bản quét này không có video"))
            meshInfoFooter
        }
    }

    /// Khu vực video dùng chung cho bản quét mesh và bản quét video cũ — một chỗ dựng player,
    /// một chỗ xử lý ca thiếu file.
    @ViewBuilder
    private func videoArea(missing: String) -> some View {
        if let player {
            VideoPlayer(player: player)
        } else if FileManager.default.fileExists(atPath: videoURL.path) {
            // File có, `.task` chưa chạy xong — một nhịp thôi.
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            unavailableView(missing)
        }
    }

    private var meshInfoFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(meshTitle, systemImage: "cube.transparent")
                .font(.caption.weight(.semibold))
            Text(meshFooterText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    /// Chỉ hứa đúng file đang có: OBJ (chuẩn mới / bản cũ có GLB-zip), PLY (bản phao khi
    /// chuyển OBJ lỗi), hoặc chỉ video (quét dừng quá sớm).
    private var meshFooterText: String {
        if FileManager.default.fileExists(atPath: objURL.path) || coloredGLBExists || coloredZipExists {
            return L.t(
                "Share the colored 3D model (OBJ) from the share menu. This scan type has no floor plan.",
                "Chia sẻ mô hình 3D màu (OBJ) từ menu chia sẻ. Loại bản quét này không có bản vẽ mặt bằng."
            )
        }
        if FileManager.default.fileExists(atPath: plyURL.path) {
            return L.t(
                "Share the raw 3D mesh (PLY) from the share menu. This scan type has no floor plan.",
                "Chia sẻ mesh thô (PLY) từ menu chia sẻ. Loại bản quét này không có bản vẽ mặt bằng."
            )
        }
        return L.t(
            "This scan has video only — no 3D model was captured.",
            "Bản quét này chỉ có video — chưa thu được mô hình 3D."
        )
    }

    private var meshTitle: String {
        let base = L.t("3D mesh scan", "Bản quét Mesh 3D")
        // storedLabel: giữ nhãn cho bản quét cũ lưu rawValue "light" (case đã bỏ 2026-07-19).
        guard let raw = current.meshQuality, let tierLabel = MeshQuality.storedLabel(raw) else { return base }
        return base + " · " + tierLabel
    }

    /// Bản quét video: xem lại video + lưu ý độ chính xác.
    private var videoTab: some View {
        VStack(spacing: 10) {
            videoArea(missing: L.t("Video file not found", "Không tìm thấy file video"))
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
            } else if current.isMeshOnly {
                meshShareItems
            } else {
                legacyShareItems
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
    }

    /// Menu chia sẻ cho bản quét RoomPlan CŨ.
    ///
    /// MỌI mục đều gác `fileExists`, kể cả USDZ — trước đây `ShareLink(item: usdzURL)` đứng vô
    /// điều kiện vì luồng RoomPlan luôn ghi model.usdz. Nay không còn luồng nào ghi nó, nên bản
    /// quét thiếu file (export USDZ từng lỗi, hoặc file bị xoá) sẽ mở ra bảng chia sẻ rỗng —
    /// khách bấm Chia sẻ, được một hộp thoại không làm gì, và không hiểu vì sao.
    @ViewBuilder
    private var legacyShareItems: some View {
        if FileManager.default.fileExists(atPath: usdzURL.path) {
            ShareLink(item: usdzURL) {
                Label(L.t("Share 3D model (USDZ)", "Chia sẻ mô hình 3D (USDZ)"), systemImage: "cube")
            }
        }
        // Mô hình LiDAR CÓ MÀU.
        // GLB: Blender/most viewers ra màu ngay (khuyến nghị). OBJ: hợp MeshLab/CloudCompare.
        if coloredGLBExists {
            ShareLink(item: coloredGLBURL) {
                Label(L.t("Share colored 3D (GLB)", "Chia sẻ mô hình màu (GLB)"), systemImage: "cube.fill")
            }
        }
        if coloredZipExists {
            ShareLink(item: meshShareURL ?? coloredZipURL) {
                Label(L.t("Share colored 3D (OBJ)", "Chia sẻ mô hình màu (OBJ)"), systemImage: "square.stack.3d.up")
            }
        }
        // PLY thô: bản quét cũ nào lỡ hỏng CẢ zip lẫn GLB lúc lưu (cả hai dựng bằng `try?`) thì
        // đây là lối chia sẻ mô hình màu DUY NHẤT còn lại. Trước đây màn này tự dựng bù zip/GLB
        // khi mở nên ca đó "tự lành"; nay không dựng nữa, thiếu mục này là mô hình 3D kẹt trong
        // máy vĩnh viễn.
        if FileManager.default.fileExists(atPath: plyURL.path) {
            ShareLink(item: plyURL) {
                Label(L.t("Share raw mesh (PLY)", "Chia sẻ mesh thô (PLY)"), systemImage: "square.3.layers.3d")
            }
        }
        // OBJ (RoomPlan) + video là NGUYÊN LIỆU NỘI BỘ (gửi về đội xử lý qua đơn hàng), không cho khách chia sẻ.
        if FileManager.default.fileExists(atPath: planURL.path) {
            Button {
                planImageURL = planURL
            } label: {
                Label(L.t("Share floor plan (PNG)", "Chia sẻ ảnh mặt bằng (PNG)"), systemImage: "photo")
            }
        }
    }

    /// Menu chia sẻ cho bản quét MESH. Chuẩn mới: model.obj (+mtl) + video.
    /// Các mục GLB/zip/PLY chỉ hiện cho bản quét CŨ còn giữ những file đó.
    @ViewBuilder
    private var meshShareItems: some View {
        if FileManager.default.fileExists(atPath: objURL.path) {
            ShareLink(item: objURL) {
                Label(L.t("Share colored 3D (OBJ)", "Chia sẻ mô hình màu (OBJ)"), systemImage: "square.stack.3d.up")
            }
        }
        if coloredGLBExists {
            ShareLink(item: coloredGLBURL) {
                Label(L.t("Share colored 3D (GLB)", "Chia sẻ mô hình màu (GLB)"), systemImage: "cube.fill")
            }
        }
        if coloredZipExists {
            ShareLink(item: meshShareURL ?? coloredZipURL) {
                Label(L.t("Share colored 3D (OBJ)", "Chia sẻ mô hình màu (OBJ)"), systemImage: "square.stack.3d.up")
            }
        }
        if FileManager.default.fileExists(atPath: plyURL.path) {
            ShareLink(item: plyURL) {
                Label(L.t("Share raw mesh (PLY)", "Chia sẻ mesh thô (PLY)"), systemImage: "square.3.layers.3d")
            }
        }
        if FileManager.default.fileExists(atPath: videoURL.path) {
            ShareLink(item: videoURL) {
                Label(L.t("Share video", "Chia sẻ video"), systemImage: "video")
            }
        }
    }

    /// Tên file zip theo tên bản quét (giữ chữ/số/dấu tiếng Việt + khoảng trắng . _ -).
    private func meshShareFileName() -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-"))
        // components(separatedBy: allowed.inverted).joined() = bỏ mọi ký tự KHÔNG hợp lệ.
        // prefix(60) cắt theo Character (grapheme) nên không vỡ cặp surrogate.
        let cleaned = current.name
            .components(separatedBy: allowed.inverted)
            .joined()
            .trimmingCharacters(in: .whitespaces)
        let base = cleaned.isEmpty ? "model-colored" : String(cleaned.prefix(60))
        return base + ".zip"
    }

    /// Tạo bản sao zip mang tên bản quét trong thư mục tạm riêng theo record (tránh đụng
    /// tên giữa các bản quét). Lỗi → nil (chia sẻ dùng file gốc).
    private func prepareNamedZip() -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-\(record.id.uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(meshShareFileName())
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: coloredZipURL, to: dest)
            return dest
        } catch {
            return nil
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

}

// MARK: - Form đặt hàng (kiểu CubiCasa: gói + add-on + giá, lưu mặc định cho lần sau)

/// Một file khách tự đính kèm đơn (logo / file thêm) đã upload xong. `id` = fileId server cấp.
/// Dùng chung với mục đính kèm của "Yêu cầu sửa" (`RevisionSheet`) — cùng endpoint `/order-files`.
struct OrderFileItem: Identifiable {
    let id: String   // fileId
    let name: String
    let url: String  // publicUrl trên R2

    /// MIME theo đuôi file — server dùng nó để ký presigned URL nên phải đoán trước khi upload.
    /// Không nhận ra đuôi thì trả octet-stream và để SERVER từ chối (allowlist nằm ở đó), thay vì
    /// đoán bừa một loại được phép.
    static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension), let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}

struct OrderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var store: ScanStore
    let record: ScanRecord
    var projectName: String? = nil // tên dự án/địa chỉ nhà — hiện trên thẻ đơn cho đội xử lý
    var candidateScans: [ScanRecord]? = nil // chế độ dự án: danh sách tầng, chọn sẵn tất cả

    @State private var catalog: CatalogResponse?
    @State private var loadError: String?

    /// Đa gói: khách chọn 2D / 3D / cả hai — giá cộng dồn (chủ app chốt 2026-07-21).
    @State private var selectedPackages: Set<String> = []
    @State private var selectedAddons: Set<String> = []
    /// Mẫu đã chọn cho addon có picker: addonId → templateId (color, siteplan).
    @State private var selectedTemplates: [String: String] = [:]
    /// File khách tự đính kèm (logo / file thêm) — đã upload xong, chờ gửi kèm đơn.
    @State private var orderFiles: [OrderFileItem] = []
    /// Trần số file đính kèm mỗi đơn — PHẢI khớp trần ở server (`scans/[id]/order/route.ts`).
    private static let maxOrderFiles = 10
    @State private var showFileImporter = false
    @State private var uploadingFile = false
    @State private var fileUploadError: String?
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
    /// Task của `submit()` — giữ vào @State để HỦY được (nút Hủy / onDisappear). Trước đây là
    /// `Task {}` vô danh không ai cancel: bấm Hủy giữa lúc tải lên chỉ đóng sheet, Task chạy tiếp
    /// và vẫn tạo đơn ngầm. Xem `submit()` + nút Hủy + `.onDisappear`.
    @State private var submitTask: Task<Void, Never>?
    /// TRUE trong lúc `orderScan` đang bay lên server (cửa "Đang đặt hàng…"). Cửa này KHÔNG hủy an
    /// toàn được: request đã tới server thì đơn đã tạo, rút lại phía máy chỉ để lại HALF-STATE (server
    /// có đơn, máy không đóng dấu → bản quét vẫn hiện "Đặt làm mặt bằng", đặt lại thì server báo
    /// "already ordered"). Nên khoá nút Hủy + không cancel ở onDisappear khi cờ này bật.
    @State private var placingOrder = false
    @State private var showTourPhotos = false // mở màn thêm ảnh Virtual Tour ngay sau khi đặt

    /// Ngôn ngữ bản vẽ — list cố định (chủ app chốt 2026-07-21). Giá trị gửi lên server = chính chuỗi
    /// này (đội vẽ đọc để biết viết bản vẽ bằng ngôn ngữ/biến thể nào).
    private static let languageOptions = [
        "English", "English (UK)", "English (AU)", "English (US/CA)",
        "French", "German", "Czech", "Slovak", "Spanish",
    ]

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

    /// Câu nhắc dưới danh sách tầng. CHỈ nói diện tích khi thật sự đo được.
    ///
    /// Bản quét mesh KHÔNG BAO GIỜ có `areaSqm` — chỉ RoomPlan sinh ra số đó, và RoomPlan đã bị
    /// gỡ. Chủ app chốt 2026-07-20 là tự đo tay thay vì cho app ước lượng từ mesh, nên tình trạng
    /// này là VĨNH VIỄN chứ không phải tạm thời. Câu cũ nối cứng "Tổng diện tích: N m²" nên mọi
    /// khách, mọi đơn, đều đọc thấy "Tổng diện tích: 0 m²" ngay tại màn chốt đơn — trông như app
    /// đo hỏng, và tệ hơn là làm khách nghi ngờ luôn cái giá bên dưới.
    ///
    /// Tách thành computed property thay vì viết ternary lồng trong ViewBuilder: đó là đúng dạng
    /// biểu thức mà CI này từng chết vì "Swift type-check timeout".
    private var floorsFooterText: String {
        if otherScans.isEmpty {
            // 🔴 Câu này TỪNG dạy ngược hẳn hướng dẫn trong app: "Quét từng tầng riêng (đặt tên
            // Floor 1, Floor 2…)". Đó là tàn dư đời RoomPlan — hồi đó quét từng phòng rồi framework
            // tự ghép nên "quét riêng rồi gộp" mới đúng. Với mesh thì MỖI lần Dừng & Lưu là một hệ
            // toạ độ MỚI, hai bản quét riêng KHÔNG tự khớp, đội vẽ phải ghép tay và chỉ ghép được
            // nếu có phần chồng lấn — xem `ScanGuideView` mục "Nhiều tầng — quét liền một mạch".
            //
            // Khách đọc dòng này TRONG FORM ĐẶT HÀNG, tức sau khi đã quét xong, nên lời khuyên sai
            // ở đây chỉ kịp làm hỏng lần quét SAU. Nó cũng đã lừa được người viết HUONG-DAN.md
            // 2026-07-20: bản đầu chép nguyên cái sai này vào tài liệu cho khách.
            //
            // Giữ vế "gộp vào một đơn" — đó là phần ĐÚNG và có lợi (một đơn tính giá cả căn).
            // Câu chữ do chủ app chốt 2026-07-20: mời chứ không ra lệnh, vì việc đã lỡ rồi.
            return L.t(
                "You can scan every floor in one continuous pass — no need for a separate scan per floor. If a large home needs several scans, you can order them together here.",
                "Bạn có thể quét liền một mạch các tầng trong một lần, không cần tách riêng từng bản quét cho mỗi tầng. Nếu nhà lớn phải chia thành nhiều bản quét, bạn gộp chúng vào một đơn ngay tại đây."
            )
        }
        let base = L.t(
            "Select the other floors of the same home to order everything together.",
            "Chọn các tầng khác của cùng căn nhà để đặt chung một đơn."
        )
        // Bản quét CŨ đời RoomPlan vẫn còn số đo thật trong meta.json — với chúng thì vẫn nói.
        guard combinedAreaSqm > 0 else { return base }
        return base + " " + L.t(
            "Total area: \(Int(combinedAreaSqm)) m².",
            "Tổng diện tích: \(Int(combinedAreaSqm)) m²."
        )
    }

    /// Đơn có chứa bản quét CHỈ VIDEO (không LiDAR) → nhắc độ chính xác.
    private var selectionHasVideoScan: Bool {
        record.isVideoOnly || otherScans.contains { extraFloors.contains($0.id) && $0.isVideoOnly }
    }

    /// Đơn có bản quét MESH 3D → báo đội vẽ sẽ dựng mặt bằng từ mesh thô + video.
    private var selectionHasMeshScan: Bool {
        record.isMeshOnly || otherScans.contains { extraFloors.contains($0.id) && $0.isMeshOnly }
    }

    private var isFreePromo: Bool {
        (catalog?.freeOrdersRemaining ?? 0) > 0
    }

    private var totalUSD: Int {
        guard let catalog else { return 0 }
        // Đa gói: cộng dồn giá mọi gói đã chọn (khớp computeQuote phía server).
        var total = 0
        for pkg in catalog.packages where selectedPackages.contains(pkg.id) {
            total += pkg.price
        }
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
                        // Hủy trong lúc TẢI LÊN = HỦY THẬT: cancel Task rồi dismiss (checkpoint trước
                        // orderScan trong submit() đảm bảo đơn KHÔNG tạo). Nhưng trong lúc "Đang đặt
                        // hàng…" (`placingOrder`) thì nút này bị `.disabled` — guard đây chỉ để chắc
                        // ăn nếu lọt qua một khung hình: KHÔNG hủy lúc orderScan đang bay (half-state).
                        guard !placingOrder else { return }
                        submitTask?.cancel()
                        dismiss()
                    }
                    .disabled(placingOrder)
                }
            }
            .task {
                await loadCatalog()
            }
        }
        // Chặn VUỐT-đóng khi đang đặt: vuốt xuống là cử chỉ VÔ Ý, đường dễ nhất để "hủy hụt" (sheet
        // đóng mà đơn vẫn tạo ngầm). Muốn thoát thì bấm nút "Hủy" tường minh — nút đó cancel Task hẳn.
        .interactiveDismissDisabled(isBusy)
        // Lưới an toàn: sheet bị tháo bằng ĐƯỜNG KHÁC (màn cha dismiss vì bản quét bị dọn-sau-giao,
        // scene bị thu hồi…) cũng phải hủy Task, không thì đơn vẫn tạo ngầm sau khi sheet biến mất.
        // NHƯNG không hủy khi đang `placingOrder`: lúc đó để orderScan chạy trọn thì đơn tạo + đóng
        // dấu bản quét cùng chạy (nhất quán), còn hủy nửa chừng mới đẻ half-state.
        .onDisappear { if !placingOrder { submitTask?.cancel() } }
    }

    private func loadCatalog() async {
        // Chế độ dự án: chọn sẵn TẤT CẢ các tầng của căn nhà
        if candidateScans != nil && extraFloors.isEmpty {
            extraFloors = Set(otherScans.map(\.id))
        }
        do {
            let result = try await APIClient.shared.catalog()
            catalog = result
            // Điền mặc định gói: `packageIds` (app mới) > `packageId` (default cũ) > gói default > gói đầu.
            let d = result.defaults
            let validPkgIds = Set(result.packages.map(\.id))
            var pkgs = Set((d?.packageIds ?? []).filter { validPkgIds.contains($0) })
            if pkgs.isEmpty, let saved = d?.packageId, validPkgIds.contains(saved) {
                pkgs = [saved]
            }
            if pkgs.isEmpty, let def = result.packages.first(where: { $0.isDefault })?.id ?? result.packages.first?.id {
                pkgs = [def]
            }
            selectedPackages = pkgs
            let validAddonIds = Set(result.addons.map(\.id))
            selectedAddons = Set((d?.addonIds ?? []).filter { validAddonIds.contains($0) })
            // Mẫu mặc định cho addon đã chọn sẵn + có picker: lấy mẫu lần trước nếu còn hợp lệ, không
            // thì mẫu đầu. Addon chưa chọn thì để trống — tự chọn mẫu đầu khi khách bật (xem toggle).
            var tpls: [String: String] = [:]
            for addon in result.addons {
                guard let templates = addon.templates, !templates.isEmpty,
                      selectedAddons.contains(addon.id) else { continue }
                let saved = d?.templates?[addon.id]
                tpls[addon.id] = (saved != nil && templates.contains { $0.id == saved }) ? saved! : templates.first!.id
            }
            selectedTemplates = tpls
            if let u = d?.unitSystem, u == "imperial" || u == "metric" || u == "both" { unitSystem = u }
            // Chỉ nhận ngôn ngữ lần trước nếu còn trong list (Picker cần selection khớp một tag, không
            // thì hiện rỗng). Giá trị cũ tự do (vd "Vietnamese") → giữ mặc định "English".
            if let lang = d?.language, Self.languageOptions.contains(lang) { language = lang }
            if let fn = d?.floorNaming { floorNaming = fn }
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Toggle bật/tắt một add-on. Bật addon CÓ picker mẫu mà chưa có mẫu nào → tự chọn mẫu đầu để
    /// luôn có một lựa chọn (server ghi "(no template chosen)" nếu để trống — tránh ca đó).
    private func addonBinding(_ addon: CatalogAddon) -> Binding<Bool> {
        Binding(
            get: { selectedAddons.contains(addon.id) },
            set: { on in
                if on {
                    selectedAddons.insert(addon.id)
                    if selectedTemplates[addon.id] == nil, let firstTpl = addon.templates?.first?.id {
                        selectedTemplates[addon.id] = firstTpl
                    }
                } else {
                    selectedAddons.remove(addon.id)
                    selectedTemplates.removeValue(forKey: addon.id)
                }
            }
        )
    }

    /// Picker mẫu cho color/siteplan: hàng thumbnail cuộn NGANG + bản PHÓNG TO mẫu đang chọn để
    /// khách nhìn rõ (chủ app chốt 2026-07-21).
    private func templatePicker(addonId: String, templates: [CatalogTemplate]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(templates) { tpl in
                        Button {
                            selectedTemplates[addonId] = tpl.id
                        } label: {
                            VStack(spacing: 4) {
                                templateThumb(tpl)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8).strokeBorder(
                                            selectedTemplates[addonId] == tpl.id ? Color.accentColor : Color.secondary.opacity(0.3),
                                            lineWidth: selectedTemplates[addonId] == tpl.id ? 2.5 : 1
                                        )
                                    )
                                Text(tpl.name)
                                    .font(.caption2)
                                    .foregroundStyle(selectedTemplates[addonId] == tpl.id ? Color.accentColor : Color.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            if let selId = selectedTemplates[addonId], let sel = templates.first(where: { $0.id == selId }) {
                templateLargePreview(sel)
            }
        }
    }

    /// Bản phóng to của mẫu đang chọn: ảnh cao ~200pt (scaledToFit, không méo — hợp mọi tỉ lệ), hoặc
    /// ô placeholder khi chưa có ảnh thật.
    @ViewBuilder
    private func templateLargePreview(_ tpl: CatalogTemplate) -> some View {
        if let s = tpl.imageUrl, !s.isEmpty, let url = URL(string: s) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else if phase.error != nil {
                    Color.secondary.opacity(0.1)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.1))
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .overlay(
                    VStack(spacing: 6) {
                        Image(systemName: "paintpalette").font(.title2)
                        Text(tpl.name).font(.subheadline.weight(.medium))
                        Text(L.t("Preview image coming soon", "Ảnh mẫu sẽ cập nhật sau"))
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                )
        }
    }

    /// Ô ảnh mẫu 64pt. Có imageUrl → AsyncImage; chưa có (placeholder) → ô màu + icon.
    @ViewBuilder
    private func templateThumb(_ tpl: CatalogTemplate) -> some View {
        if let s = tpl.imageUrl, !s.isEmpty, let url = URL(string: s) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Color.secondary.opacity(0.12)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 64, height: 64)
                .overlay(Image(systemName: "paintpalette").foregroundStyle(.secondary))
        }
    }

    private func handleFilePick(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        Task { await uploadOrderFile(url) }
    }

    /// Upload 1 file khách chọn lên R2 qua presigned URL, rồi thêm vào `orderFiles` để gửi kèm đơn.
    private func uploadOrderFile(_ url: URL) async {
        uploadingFile = true
        fileUploadError = nil
        // File từ .fileImporter nằm ngoài sandbox → phải xin quyền truy cập (và nhả sau).
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            uploadingFile = false
        }
        let name = url.lastPathComponent
        let contentType = Self.mimeType(for: url)
        do {
            let slot = try await APIClient.shared.presignOrderFile(fileName: name, contentType: contentType)
            try await APIClient.shared.uploadFile(at: url, to: slot.putUrl, contentType: slot.contentType) { _ in }
            orderFiles.append(OrderFileItem(id: slot.fileId, name: slot.name, url: slot.publicUrl))
        } catch {
            fileUploadError = error.localizedDescription
        }
    }

    /// Thân hàm đã dời sang `OrderFileItem.mimeType(for:)` để mục đính kèm của "Yêu cầu sửa"
    /// (tab Đơn hàng) dùng chung — hai chỗ đoán MIME khác nhau là hai chỗ bị server từ chối khác nhau.
    private static func mimeType(for url: URL) -> String {
        OrderFileItem.mimeType(for: url)
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
                    .foregroundStyle(.tint)
                } else {
                    Text(floorsFooterText)
                }
            }

            Section {
                // ĐA GÓI: khách chọn 2D / 3D / cả hai — check nhiều được, giá cộng dồn (checkmark thay
                // cho radio để báo hiệu chọn-nhiều). Ít nhất một gói (nút Đặt hàng khoá khi rỗng).
                ForEach(catalog.packages) { pkg in
                    Button {
                        if selectedPackages.contains(pkg.id) {
                            selectedPackages.remove(pkg.id)
                        } else {
                            selectedPackages.insert(pkg.id)
                        }
                    } label: {
                        HStack {
                            Image(systemName: selectedPackages.contains(pkg.id) ? "checkmark.circle.fill" : "circle")
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
                Text(L.t("Packages (choose one or more)", "Gói dịch vụ (chọn một hoặc nhiều)"))
            }

            Section {
                ForEach(catalog.addons) { addon in
                    Toggle(isOn: addonBinding(addon)) {
                        HStack {
                            Text(addon.name)
                            Spacer()
                            Text("+$\(addon.price)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    // Addon có picker mẫu (color/siteplan) + đang được chọn → hiện list mẫu cuộn ngang.
                    if selectedAddons.contains(addon.id), let templates = addon.templates, !templates.isEmpty {
                        templatePicker(addonId: addon.id, templates: templates)
                    }
                }
            } header: {
                Text(L.t("Add-ons", "Dịch vụ thêm"))
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    // Express: chỉ CẢNH BÁO. App không đo được diện tích (mesh không có areaSqm) nên
                    // không tự chặn nhà lớn được — chủ app tự xử khi vẽ.
                    if selectedAddons.contains("express") {
                        Text(L.t(
                            "⚡️ Express: delivered within 12 hours. Not available for homes over 5,000 sq ft (464 m²).",
                            "⚡️ Express: giao trong vòng 12 giờ. Không áp dụng cho nhà trên 5.000 sq ft (464 m²)."
                        ))
                    }
                    if selectedAddons.contains("tour") {
                        Text(L.t(
                            "🏠 Virtual Tour: after ordering you'll add 1–3 photos per room — we pin them on your floor plan and you get a shareable interactive tour link.",
                            "🏠 Virtual Tour: sau khi đặt, bạn thêm 1–3 ảnh cho mỗi phòng — đội ngũ ghim ảnh lên mặt bằng và bạn nhận link tour tương tác để chia sẻ."
                        ))
                    }
                }
            }

            Section {
                Picker(L.t("Units", "Đơn vị đo"), selection: $unitSystem) {
                    Text(L.t("Metric (m)", "Mét (m)")).tag("metric")
                    Text(L.t("Imperial (ft)", "Feet (ft)")).tag("imperial")
                    Text(L.t("Both (ft & m)", "Cả hai (ft & m)")).tag("both")
                }
                Picker(L.t("Language", "Ngôn ngữ bản vẽ"), selection: $language) {
                    ForEach(Self.languageOptions, id: \.self) { lang in
                        Text(lang).tag(lang)
                    }
                }
                TextField(L.t("Floor naming style (optional)", "Kiểu đặt tên tầng (không bắt buộc)"), text: $floorNaming)
            } header: {
                Text(L.t("Preferences (saved for next time)", "Tùy chọn (lưu cho lần sau)"))
            }

            // Ghi chú TÁCH khỏi mục "lưu cho lần sau": server chỉ lưu gói/add-on/đơn vị/ngôn ngữ/kiểu
            // tên tầng làm mặc định (orderDefaults), KHÔNG lưu `notes` — để chung header cũ là hứa sai.
            Section {
                TextField(
                    L.t("Anything we should know? (optional)", "Ghi chú thêm (không bắt buộc)"),
                    text: $notes,
                    axis: .vertical
                )
                .lineLimit(3...6)
            } header: {
                Text(L.t("Note", "Ghi chú"))
            }

            Section {
                ForEach(orderFiles) { file in
                    HStack {
                        Image(systemName: "doc.fill").foregroundStyle(.secondary)
                        Text(file.name).lineLimit(1)
                        Spacer()
                        Button {
                            orderFiles.removeAll { $0.id == file.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    fileUploadError = nil
                    showFileImporter = true
                } label: {
                    if uploadingFile {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(L.t("Uploading…", "Đang tải lên…")).foregroundStyle(.secondary)
                        }
                    } else {
                        Label(L.t("Add a file (logo, PDF…)", "Thêm file (logo, PDF…)"), systemImage: "paperclip")
                    }
                }
                // Khoá theo TRẦN SERVER: order route nhận tối đa `Self.maxOrderFiles` file. Chặn ở
                // đây thì khách không bao giờ rơi vào ca "gửi 11 file, server chỉ nhận 10" —
                // trước đây server CẮT LẶNG LẼ, tức file thứ 11 không ai thấy mà cũng không ai báo.
                .disabled(uploadingFile || isBusy || orderFiles.count >= Self.maxOrderFiles)
                .fileImporter(
                    isPresented: $showFileImporter,
                    allowedContentTypes: [.image, .pdf],
                    allowsMultipleSelection: false
                ) { result in
                    handleFilePick(result)
                }
                if let fileUploadError {
                    Text(fileUploadError).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text(L.t("Attachments (optional)", "Đính kèm file (không bắt buộc)"))
            } footer: {
                Text(orderFiles.count >= Self.maxOrderFiles
                     ? L.t("Maximum \(Self.maxOrderFiles) files per order.",
                           "Tối đa \(Self.maxOrderFiles) file mỗi đơn.")
                     : L.t("Add a logo or any extra files for our team — images or PDF.",
                           "Gửi thêm logo hoặc file cho đội vẽ nếu cần — ảnh hoặc PDF."))
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
                if selectionHasMeshScan {
                    Label(
                        L.t(
                            "This order includes 3D mesh scans — the floor plan is drawn from the raw mesh + video.",
                            "Đơn này có bản quét Mesh 3D — mặt bằng sẽ được vẽ từ mesh thô + video."
                        ),
                        systemImage: "cube.transparent"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                .disabled(isBusy || selectedPackages.isEmpty || uploadingFile)
            } footer: {
                // Tách theo `isFreePromo`: câu "sẽ có link thanh toán" hiện VÔ ĐIỀU KIỆN sẽ mâu thuẫn
                // với banner "Đơn này MIỄN PHÍ" + nút "MIỄN PHÍ 🎁" ngay trên (đơn free server không
                // gửi link nào). Đường free là mặc định (24/27 đơn prod) nên đây là ca chính.
                if isFreePromo {
                    Text(L.t(
                        "Free order — no payment needed. Our team starts right after you place it.",
                        "Đơn miễn phí — không cần thanh toán, đội ngũ bắt đầu ngay sau khi đặt."
                    ))
                } else {
                    Text(L.t(
                        "You will get a secure payment link (Stripe/PayPal) after placing the order.",
                        "Sau khi đặt sẽ có link thanh toán bảo mật (Stripe/PayPal)."
                    ))
                }
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
            // Đơn miễn phí server set `paidAt` sẵn + vào thẳng hàng xử lý → KHÔNG có thanh toán nào để
            // "chờ". In "bắt đầu sau khi nhận thanh toán" ngay dưới dòng "MIỄN PHÍ 🎁" là tự mâu thuẫn.
            Text(order.free == true
                ? L.t("Our team will start right away. Track progress in the Orders tab.",
                      "Đội ngũ Cedar247 sẽ bắt đầu ngay. Theo dõi tiến độ ở mục Đơn hàng.")
                : L.t("Our team will start after payment is received. Track progress in the Orders tab.",
                      "Đội ngũ Cedar247 sẽ bắt đầu sau khi nhận thanh toán. Theo dõi tiến độ ở mục Đơn hàng."))
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
        // 🔴 CHỤP MỌI THỨ QUYẾT ĐỊNH GIÁ NGAY TẠI ĐÂY, đừng đọc `@State` lại sau các `await`.
        //
        // Giữa lúc bấm nút và lúc `orderScan` bay đi là cả quãng TẢI LÊN 40–200MB × số tầng —
        // hàng chục phút trên 4G. Suốt quãng đó form vẫn chạm được (chỉ nút Hủy và nút Đặt hàng
        // bị khoá), nên khách hoàn toàn có thể tick thêm gói 3D $40 "để xem giá" rồi bỏ ra. Đọc
        // `selectedPackages` ở dưới nghĩa là đơn gửi lên theo trạng thái LÚC ĐÓ, khác con số mà
        // nút "Đặt hàng $46" đã hứa lúc khách bấm. Chụp ở đây thì cái khách bấm = cái server nhận.
        let pkgIds = Array(selectedPackages)
        let addonIds = Array(selectedAddons)
        let templatesSnapshot = selectedTemplates
        let filesSnapshot = orderFiles.map { ["name": $0.name, "url": $0.url] }
        let notesSnapshot = notes
        let unitSnapshot = unitSystem
        let languageSnapshot = language
        let floorNamingSnapshot = floorNaming
        let couponSnapshot = couponCode.trimmingCharacters(in: .whitespacesAndNewlines)
        submitTask = Task {
            // Tải lên mọi bản quét CHƯA có trên server (kể cả bản chính — khi đặt từ trang dự án)
            @MainActor
            func ensureUploaded(_ scan: ScanRecord) async -> String? {
                // 🔴 Hỏi STORE, đừng tin bản ghi được truyền vào. `scan` đến từ `record`/
                // `candidateScans` — hai thứ do màn gọi cấp và có thể là bản chụp đã cũ. Trường
                // `cloudScanId` là guard DUY NHẤT chống tải lên lại: đọc nhầm bản cũ là gửi lại
                // 40–200MB mỗi tầng qua 4G VÀ đẻ scan id mới trên server, mà hai chốt chống-đơn-
                // trùng phía server đều khoá theo scan id nên id mới lọt cả hai → đơn thứ hai cho
                // cùng căn nhà. Đúng lỗi này đã lọt vào một bản vá của màn Dự án và bị review chặn.
                // Giải MỘT LẦN rồi dùng `live` xuyên suốt, đừng trộn `live` với `scan`: guard đọc
                // bản mới mà thân hàm gửi bản cũ là kiểu "đúng một nửa" khiến người sửa sau tưởng
                // cả hàm đã an toàn. `?? scan` là ca bản quét vừa bị dọn khỏi store — giữ nguyên
                // hành vi cũ (upload sẽ tự hỏng và báo lỗi) thay vì im lặng bỏ qua.
                let live = store.records.first { $0.id == scan.id } ?? scan
                if let existing = live.cloudScanId { return existing }
                busyLabel = L.t("Uploading \(live.name)…", "Đang tải \(live.name)…")
                let uploader = ScanUploader()
                if let cloudId = await uploader.upload(record: live, folder: store.folderURL(for: live)) {
                    store.setCloudScanId(live, cloudScanId: cloudId)
                    return cloudId
                }
                if case .failed(let message) = uploader.phase {
                    errorMessage = "\(live.name): \(message)"
                } else {
                    errorMessage = L.t("Could not upload \(live.name).", "Không tải được \(live.name).")
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

            // [20] Làm tươi suất miễn phí NGAY TRƯỚC khi đặt. Nút vừa bấm chốt `isFreePromo` theo
            // catalog tải lúc MỞ sheet, mà giữa đó là cả quãng điền form + upload 40–200MB × số tầng
            // (hàng chục phút). Suất free (MIN của tài khoản VÀ thiết bị) có thể đã bị tiêu bởi đơn
            // khác, tài khoản khác cùng máy, hoặc admin hạ hạn mức → server thu tiền trong khi nút
            // ghi "MIỄN PHÍ 🎁". Đây là kênh còn sót của đúng lớp lỗi đã vá ở 958b118 (deviceId).
            // catalog() là GET (không tiêu suất) và đã gửi deviceId nên phản ánh đúng hạn mức thiết bị.
            if isFreePromo, let fresh = try? await APIClient.shared.catalog() {
                catalog = fresh
                if (fresh.freeOrdersRemaining ?? 0) == 0 {
                    errorMessage = L.t(
                        "Your free-order slots were just used up. Please review the price and tap Place order again.",
                        "Suất miễn phí vừa hết. Vui lòng xem lại giá rồi bấm Đặt hàng lại."
                    )
                    isBusy = false
                    busyLabel = nil
                    return
                }
            }

            // [3] Checkpoint HỦY — mấu chốt tiền: sau các await tải lên (nơi khách bấm Hủy / vuốt
            // đóng), nếu Task đã bị cancel thì DỪNG TRƯỚC orderScan. Upload dở bỏ đi không mất gì
            // (server chưa có đơn); nhưng một khi orderScan chạy là đơn đã tạo, tốn suất free/tiền.
            if Task.isCancelled {
                isBusy = false
                busyLabel = nil
                return
            }

            // Từ đây là điểm KHÔNG QUAY ĐẦU: khoá hủy (nút + onDisappear) để orderScan chạy trọn.
            // Đặt cờ trên MainActor TRƯỚC `await` nên UI kịp disable nút Hủy trước khi request bay đi.
            placingOrder = true
            busyLabel = L.t("Placing order…", "Đang đặt hàng…")
            do {
                let result = try await APIClient.shared.orderScan(
                    scanId: primaryCloudId,
                    extraScanIds: extraCloudIds,
                    packageIds: pkgIds,
                    addonIds: addonIds,
                    templates: templatesSnapshot,
                    orderFiles: filesSnapshot,
                    notes: notesSnapshot,
                    unitSystem: unitSnapshot,
                    language: languageSnapshot,
                    floorNaming: floorNamingSnapshot,
                    projectName: projectName ?? "",
                    coupon: couponSnapshot
                )
                placedOrder = result
                // Đóng dấu số đơn cho ĐÚNG tập đã vào đơn: bản chính + các tầng khách còn tick.
                //
                // 🔴 Việc này nằm ở ĐÂY chứ không ở callback của màn gọi, và đó là CỐ Ý — đừng
                // trả nó về cho caller "cho gọn". Trạng thái tick (`extraFloors`) chỉ tồn tại
                // trong sheet này, nên màn gọi không có cách nào biết tập đúng; nó chỉ đoán được.
                // `ProjectView` đã đoán sai đúng kiểu đó: nó đóng dấu lên MỌI bản quét chưa đặt
                // của dự án, kể cả tầng khách vừa BỎ CHỌN ngay trong form này. Tầng đó chưa hề
                // lên server nhưng mang nhãn "Đã đặt · #LS-…", mất luôn nút đặt hàng VĨNH VIỄN
                // (không code nào trả `cloudOrderNumber` về nil) và rơi khỏi `otherScans` nên
                // không gộp được vào đơn nào về sau — khách trả tiền cho "cả căn" mà đội vẽ
                // không bao giờ nhận được tầng ấy.
                //
                // Thứ tự với `placedOrder` ở trên KHÔNG phải một bảo đảm render — SwiftUI gộp cả
                // hai thay đổi vào cùng một nhịp, nên đừng dựa vào "cái nào vẽ trước". Điều thật
                // sự giữ màn thành công là màn gọi không được để nội dung sheet phụ thuộc vào
                // `cloudOrderNumber` (xem `ProjectView.orderTarget` / `liveScans(of:)`).
                store.setOrderNumber(record, orderNumber: result.orderNumber)
                for extra in extras {
                    store.setOrderNumber(extra, orderNumber: result.orderNumber)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            placingOrder = false
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
