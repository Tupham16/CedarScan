import SwiftUI
import ARKit
import AVFoundation // AVCaptureDevice.authorizationStatus — kiểm quyền camera trước khi vào phiên quét

/// Kết quả một lần quét Mesh 3D — gói lại cho gọn chữ ký onFinish.
struct MeshScanResult {
    let videoURL: URL?
    let meshURL: URL?
    /// camera-track.json (vị trí + hướng camera theo PTS video) — nguyên liệu minimap;
    /// nil khi video không quay được (track không video là vô nghĩa).
    let trackURL: URL?
    /// Thư mục texture-shots/ (JPEG + shots.json) — nguyên liệu bake texture trên máy
    /// trạm, sẽ được đóng KÈM vào model-colored.zip; nil khi không chụp được ảnh nào.
    let texshotsDir: URL?
    let name: String?
    /// Cấu hình THẬT SỰ đã quét buổi này (ScanStore ghi rawValue vào meta.json). Picker độ nét
    /// đã bỏ 2026-07-31 nên nay luôn là `MeshQuality.storageDefault` — vẫn mang theo kết quả
    /// thay vì đọc lại ở chỗ lưu, để chỗ lưu không bao giờ khai một cấu hình khác cái đã quét.
    let quality: MeshQuality
    /// Mô hình từng chạm trần 2M trong lúc quét → dữ liệu CÓ PHẦN BỊ THIẾU;
    /// call-site nên mời khách quét bản BỔ SUNG cho phần còn lại sau khi lưu.
    let hitCap: Bool
    /// Đã đi ĐƯỜNG LƯU NHANH: mesh KHÔNG có màu-đỉnh (xám hằng số), màu sẽ đến từ texture
    /// do máy trạm bake. `ScanStore` cần biết để KHÔNG nhồi GLB xám vô dụng vào zip.
    let geometryOnly: Bool
}

/// Luồng quét MESH 3D (không RoomPlan): quét liền mạch mọi hình dạng, one-shot nhiều
/// tầng — đi cầu thang thoải mái — và "Dừng & Lưu" BẤT KỲ lúc nào (không cần RoomPlan
/// "present" phòng như luồng cũ). Sản phẩm: mesh màu + video, KHÔNG có floorplan.
struct MeshScanFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ScanStore
    @StateObject private var controller: MeshScanController

    /// Lưu bản quét. Trả về bản ghi đã lưu, hoặc **nil khi lưu HỎNG** — lúc đó cover đóng ngay
    /// và call-site hiện alert lỗi qua pendingSaveError (không hiện alert khi cover còn mở, sẽ
    /// bị nuốt lúc dismiss).
    let onFinish: (MeshScanResult) async -> ScanRecord?
    /// Khách bấm "Đặt hàng ngay" ở màn preview. Call-site CHỈ được ghi nhớ ý định ở đây rồi điều
    /// hướng SAU khi cover đóng — cùng lý do với mọi present-trong-onDismiss khác của app này.
    ///
    /// CỐ Ý KHÔNG CÓ GIÁ TRỊ MẶC ĐỊNH. Có `= { _ in }` thì call-site thứ ba ở pha sau quên truyền
    /// vẫn compile sạch, và nút "Đặt hàng ngay" hiện đầy đủ rồi đóng cover mà KHÔNG LÀM GÌ — hỏng
    /// lặng lẽ đúng ở bước chốt đơn. Bắt buộc truyền thì lỗi nổ ngay lúc build.
    let onOrderNow: (ScanRecord) -> Void
    /// Khách bấm "Quét thêm khu vực còn thiếu" ở màn preview. Call-site ghi nhớ ý định rồi mở
    /// lại phiên quét TỪ `onDismiss` của cover — xem giải thích ở đó, đặt cờ trong `onChange`
    /// là cover không bao giờ được dựng lại.
    let onScanMore: () -> Void

    @State private var showNaming = false
    @State private var showEmptyMeshConfirm = false
    @State private var showUnsupported = false
    /// Quyền camera bị từ chối → alert riêng có nút mở Cài đặt (xem `.onAppear` + `.onChange`).
    @State private var showCameraDenied = false
    @State private var isSaving = false
    @State private var scanName = ""
    /// Khác nil = đã lưu xong, đang hiện màn preview. Phiên quét lúc này đã kết thúc hoàn toàn
    /// (`stopAndExport` đã pause ARSession) nên mọi đường thoát đều an toàn.
    @State private var savedRecord: ScanRecord?
    @AppStorage("showScanMesh") private var showScanMesh = true

    /// ⚠ `onOrderNow` VÀ `onScanMore` PHẢI được truyền kèm NHÃN ở call-site. Viết trailing closure mà bỏ nhãn thì
    /// forward-scan (SE-0286) khớp closure đó vào `onOrderNow` chứ không phải `onFinish` → lỗi
    /// kiểu khó đọc, mất một vòng CI. Xem hai call-site đang có: HomeView và ProjectView.
    init(
        quality: MeshQuality,
        onOrderNow: @escaping (ScanRecord) -> Void,
        onScanMore: @escaping () -> Void,
        onFinish: @escaping (MeshScanResult) async -> ScanRecord?
    ) {
        _controller = StateObject(wrappedValue: MeshScanController(quality: quality))
        self.onOrderNow = onOrderNow
        self.onScanMore = onScanMore
        self.onFinish = onFinish
    }

    /// Một bản quét mesh có thể phủ cả căn → "Whole home" lên đầu.
    /// "Part 1/2": nhà rất lớn chạm trần → chia thành nhiều bản quét bổ sung.
    private static let nameSuggestions = [
        "Whole home", "Part 1", "Part 2", "Floor 1", "Floor 2", "Basement",
    ]

    var body: some View {
        ZStack {
            // MỘT view duy nhất vẽ CẢ hình camera LẪN lưới quét — xem chú thích đầu
            // `ARCameraView.swift`: tách hai lớp là nguyên nhân "lưới rung khi lia máy".
            //
            // Trần hiển thị 600k (RoomPlan chỉ 150k): khách quay lại khu đã quét phải còn THẤY
            // lưới để biết chỗ nào đã phủ — nhà thường sẽ không bị "quên" nữa. Nếu test thấy
            // nóng/giật thì hạ số này.
            // recordedCounts + photoCoverage: lưới trắng = đã vào file VÀ đã có ẢNH texture
            // lưu (item 2 PLAN-PHU-DU-DO-DUNG, chủ app chốt 03/08 — trắng phải nói đúng
            // "bản GIAO chỗ này sẽ có ảnh"). Có mesh mà CHƯA có ảnh (lia nhanh) → lưới +
            // mặt nạ ẩn đi, phủ đỏ hiện lại như chưa quét. Đỏ giữ nguyên vai "chưa được
            // ghi" (builder tắt vì gián đoạn, hoặc mô hình đầy). Vùng chưa có mesh thì lớp
            // phủ tự tô đỏ mờ (xem `MeshOverlayRenderer`).
            // Tắt lưới khi đã sang màn preview: nhịp cập nhật dừng hẳn nên CADisplayLink 30Hz
            // không quay không tải suốt lúc khách ngồi xem lại video.
            ARCameraViewRepresentable(
                arSession: controller.arSession,
                sessionDelegate: controller,
                meshMaxVerts: 600_000,
                // 🔴 `!isSaving` KHÔNG PHẢI THỪA. `savedRecord` chỉ được gán SAU khi
                // `stopAndExport()` + `onFinish()` chạy xong, tức sau vài chục giây tới vài
                // phút dựng mesh + bake màu + nén zip. Thiếu vế này thì lớp phủ giữ nguyên
                // ~70MB hình học (`wireGeos` + node) xuyên qua ĐÚNG đỉnh RAM của cả app — chỗ
                // bị iOS giết thì mất trắng buổi quét 10–30 phút. Chỉ gác `isSaving` (không
                // gác `showNaming`): từ lúc đang lưu là không còn đường quay lại quét tiếp,
                // nên giải phóng rồi không phải dựng lại; còn ở màn đặt tên thì khách vẫn bấm
                // "Quay lại" để quét thêm được.
                showMesh: showScanMesh && savedRecord == nil && !isSaving,
                recordedCounts: { [weak controller] in controller?.recordedAnchorCounts ?? [:] },
                photoCoverage: { [weak controller] in controller?.textureCoverage }
            )
            .ignoresSafeArea()

            if !isSaving && !showNaming && savedRecord == nil {
                QualityAlertOverlay(monitor: controller.qualityMonitor)
            }

            // Gác bằng `savedRecord == nil` chứ KHÔNG chỉ dựa vào nền đục của màn preview đè
            // lên: nền đục chặn CHẠM nhưng KHÔNG chặn VoiceOver focus. Để lớp này sống dưới màn
            // preview thì người dùng VoiceOver vuốt trúng "Hủy" (thoát cover mà không đi qua
            // onOrderNow — mất im lặng ý định đặt hàng) hoặc trúng "Dừng & Lưu" (bật
            // `namingOverlay`, mà overlay đó khai TRƯỚC preview trong ZStack nên nằm DƯỚI: vô
            // hình, vẫn focus được, không lối ra — app trông như treo).
            //
            // Cũng phải gác `!showNaming && !isSaving`: cùng một cái bẫy #10 ở lớp đặt tên/đang lưu.
            // namingOverlay/savingOverlay là nền đục đè LÊN topBar+bottomControls, nhưng VoiceOver
            // vẫn focus xuyên qua tới nút "Hủy" vô hình → `controller.cancel()` khi chưa `isStopped`
            // là VỨT recorder + mesh, KHÔNG hộp xác nhận, mất trắng buổi quét 10–30 phút. Lúc đặt
            // tên đã có nút "Quay lại" riêng trong overlay nên ẩn thanh dưới không mất lối ra.
            if savedRecord == nil && !showNaming && !isSaving {
                VStack {
                    topBar
                    Spacer()
                    bottomControls
                }
            }

            if showNaming {
                namingOverlay
            }
            if isSaving {
                savingOverlay
            }
            if let savedRecord {
                previewOverlay(savedRecord)
            }
        }
        .onAppear {
            // Khoá việc dọn-sau-khi-giao suốt phiên quét. Không khoá thì: dọn chạy lúc app quay
            // lại foreground (cuộc gọi, kéo Notification Center) → xoá hết bản quét của dự án →
            // dự án bị xoá → ProjectView (view SỞ HỮU cover này) tự dismiss → cover bị tháo theo
            // → phiên quét chết giữa chừng, onFinish KHÔNG BAO GIỜ chạy, mất trắng 10–30 phút.
            store.beginBusy()
            guard controller.isSupported else {
                showUnsupported = true
                return
            }
            // Quyền camera: nếu ĐÃ bị từ chối từ trước, ARSession chỉ cho ra nền đen rồi báo
            // `cameraUnauthorized` — chặn sớm bằng alert có nút Cài đặt thay vì để khách rơi vào
            // phiên quét chết (0 vertex → "Lỗi khi lưu" → lặp). `.notDetermined` thì cứ startSession:
            // iOS tự hỏi quyền, khách từ chối thì `controller.cameraDenied` bật qua didFailWithError
            // và `.onChange` bên dưới mở đúng alert này.
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .denied, .restricted:
                showCameraDenied = true
            default:
                controller.startSession()
            }
        }
        .onChange(of: controller.cameraDenied) { _, denied in
            if denied { showCameraDenied = true }
        }
        // Lưới an toàn: cover bị gỡ bằng đường nào đi nữa cũng không được để idle timer
        // kẹt tắt + CADisplayLink giữ builder/recorder sống mãi. cancel() idempotent
        // (isStopped) nên đường Lưu/Hủy bình thường không bị ảnh hưởng.
        .onDisappear {
            controller.cancel()
            store.endBusy()
        }
        .alert(
            L.t("LiDAR not available", "Máy không hỗ trợ LiDAR"),
            isPresented: $showUnsupported
        ) {
            Button("OK") { dismiss() }
        } message: {
            Text(L.t(
                "3D mesh scanning needs a LiDAR sensor (iPhone Pro).",
                "Quét mesh 3D cần cảm biến LiDAR (iPhone Pro)."
            ))
        }
        .alert(
            L.t("Camera access needed", "Cần quyền Camera"),
            isPresented: $showCameraDenied
        ) {
            Button(L.t("Open Settings", "Mở Cài đặt")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                dismiss()
            }
            Button(L.t("Cancel", "Hủy"), role: .cancel) { dismiss() }
        } message: {
            Text(L.t(
                "CedarScan needs camera access to scan in 3D. Turn it on in Settings.",
                "CedarScan cần quyền Camera để quét 3D. Hãy bật trong phần Cài đặt."
            ))
        }
        .confirmationDialog(
            L.t("No 3D model captured yet", "Chưa quét được mô hình 3D"),
            isPresented: $showEmptyMeshConfirm,
            titleVisibility: .visible
        ) {
            Button(L.t("Keep scanning", "Quét tiếp"), role: .cancel) {}
            // "Vẫn lưu phần đã có": mesh dưới ngưỡng (nếu >0 đỉnh) vẫn được xuất kèm video.
            Button(L.t("Save anyway", "Vẫn lưu phần đã có")) {
                controller.qualityMonitor.setActive(false)
                showNaming = true
            }
        } message: {
            Text(L.t(
                "Walk around and point the camera at walls and floors for a few more seconds.",
                "Hãy đi thêm vài giây, hướng camera vào tường và sàn để có dữ liệu 3D."
            ))
        }
    }

    // MARK: - Thanh trên (Hủy + bật/tắt lưới)

    private var topBar: some View {
        HStack {
            Button {
                controller.cancel()
                dismiss()
            } label: {
                Text(L.t("Cancel", "Hủy"))
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
            Button {
                showScanMesh.toggle()
            } label: {
                // Accent chứ không phải xanh lá: từ 2026-07-28 lưới màu TRẮNG, giữ icon xanh
                // lá là chỉ vào một màu không còn tồn tại trên màn quét.
                Image(systemName: showScanMesh ? "square.grid.3x3.fill" : "square.grid.3x3")
                    .font(.title3)
                    .foregroundStyle(showScanMesh ? Color.accentColor : Color.primary)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(L.t("Toggle scan mesh", "Bật/tắt lưới quét"))
        }
        .padding()
    }

    // MARK: - Điều khiển dưới (banner + Dừng & Lưu)

    private var bottomControls: some View {
        VStack(spacing: 10) {
            warningBanner
            // MỘT nghĩa cho màu đỏ, đúng cho cả hai dạng: phủ đỏ (chưa có mesh) lẫn lưới đỏ
            // (có mesh nhưng builder chưa ghi) đều là "chưa vào bản quét". Kèm ngoại lệ kính:
            // LiDAR xuyên kính nên cửa sổ/cửa kính KHÔNG BAO GIỜ hết đỏ — không dặn trước là
            // khách đứng quét mãi một tấm kính chờ hết đỏ, rồi mất tin luôn vào màu đỏ.
            Text(L.t(
                "Walk slowly and point the camera at every surface — stairs and multiple floors are fine. Red = not in your scan yet (glass and windows always stay red — skip them). White mesh = saved.",
                "Đi chậm, hướng camera vào mọi bề mặt — cầu thang/nhiều tầng thoải mái. Màu ĐỎ = chưa vào bản quét (kính/cửa sổ luôn đỏ — bỏ qua). Lưới TRẮNG = đã lưu."
            ))
            .font(.footnote)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

            Button {
                stopTapped()
            } label: {
                Text(L.t("Stop & Save", "Dừng & Lưu"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    @ViewBuilder
    private var warningBanner: some View {
        // Ưu tiên: mất định vị > đang gián đoạn (nhất thời) > mô hình đầy.
        // capReached đứng CUỐI để không che 2 trạng thái khẩn hơn (nó có thể tự hạ
        // khi ARKit gộp anchor giải phóng chỗ, nhưng thường đứng lâu).
        if controller.trackingLost {
            bannerLabel(
                L.t("Tracking lost — Stop & Save what you have.", "Mất định vị — hãy Dừng & Lưu phần đã quét."),
                color: .red
            )
        } else if controller.isInterrupted {
            bannerLabel(
                L.t("Scan interrupted — waiting to recover…", "Phiên quét bị gián đoạn — đang chờ khôi phục…"),
                color: .yellow
            )
        } else if controller.capReached {
            bannerLabel(
                L.t(
                    "Model is full — Stop & Save this part, then scan the rest as a NEW scan.",
                    "Mô hình đã đầy — hãy Dừng & Lưu phần này, rồi quét phần còn lại thành bản quét MỚI."
                ),
                color: .orange
            )
        }
    }

    private func bannerLabel(_ text: String, color: Color) -> some View {
        Label {
            Text(text).font(.footnote.weight(.semibold))
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(color == .yellow || color == .orange ? Color.black : Color.white)
    }

    // MARK: - Đặt tên + lưu

    private var namingOverlay: some View {
        ScanNameOverlay(
            name: $scanName,
            subtitle: L.t(
                "Which part of the home is this? One mesh scan can cover several floors.",
                "Đây là khu nào? Một bản quét mesh có thể phủ nhiều tầng."
            ),
            suggestions: Self.nameSuggestions,
            onSave: {
                showNaming = false
                saveAndClose()
            },
            onBack: {
                showNaming = false
                controller.qualityMonitor.setActive(true) // quét tiếp → bật lại coach
            }
        )
    }

    private var savingOverlay: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 10) {
                ProgressView()
                Text(L.t("Building 3D model…", "Đang dựng mô hình 3D…"))
                    .font(.headline)
                Text(L.t("This can take a moment at high detail.", "Mức nét cao có thể mất một lúc."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func stopTapped() {
        // Đọc vertexCount TRƯỚC khi export (finishColoredMesh giải phóng builder).
        if controller.meshVertexCount < 5_000 {
            showEmptyMeshConfirm = true
        } else {
            // Tắt coach trong lúc đặt tên — không rung/nói "bật đèn" khi đang gõ chữ.
            controller.qualityMonitor.setActive(false)
            showNaming = true
        }
    }

    /// Màn preview sau khi lưu: căn nhà + video vừa quay + "Quét thêm"/"Đặt hàng sau"/"Đặt hàng ngay".
    ///
    /// Lấy đường dẫn video từ THƯ MỤC BẢN QUÉT chứ không dùng lại `exported.videoURL` của
    /// controller: file tạm đó đã bị `saveMeshScan` MOVE đi rồi, URL cũ trỏ vào chỗ trống.
    /// Và phải `fileExists` thật — `saveMeshScan` move bằng `try?` không kiểm lại, nên "đã lưu
    /// xong" KHÔNG bảo đảm có video.
    private func previewOverlay(_ record: ScanRecord) -> some View {
        let videoURL = store.folderURL(for: record).appendingPathComponent("scan-video.mp4")
        let playable = FileManager.default.fileExists(atPath: videoURL.path) ? videoURL : nil
        return ScanPreviewView(
            addressName: store.project(with: record.projectId)?.name,
            scanName: record.name,
            videoURL: playable,
            onScanMore: {
                onScanMore()
                dismiss()
            },
            onOrderLater: { dismiss() },
            onOrderNow: {
                onOrderNow(record)
                dismiss()
            }
        )
    }

    private func saveAndClose() {
        guard !isSaving else { return } // chống double-tap nút Lưu
        isSaving = true
        let name = scanName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            // Giữ app sống nếu bị background đúng lúc export/lưu (cuộc gọi đến ở giây
            // cuối) — không thì buổi quét 30 phút có thể mất trắng vì chưa ghi record.
            let bgTask = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
            defer {
                // Trả lại auto-lock CHỈ khi đã lưu xong hẳn (stopAndExport giữ màn hình
                // thức qua cả export lẫn giai đoạn nén zip trong onFinish). Từ đây trở đi
                // khách chỉ ngồi xem video ở màn preview — khoá máy lúc đó là chuyện thường.
                UIApplication.shared.isIdleTimerDisabled = false
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                }
            }
            let exported = await controller.stopAndExport()
            let result = MeshScanResult(
                videoURL: exported.videoURL,
                meshURL: exported.meshURL,
                trackURL: exported.trackURL,
                texshotsDir: exported.texshotsDir,
                name: name.isEmpty ? nil : name,
                quality: controller.quality,
                hitCap: exported.hitCap,
                geometryOnly: exported.geometryOnly
            )
            let saved = await onFinish(result)
            // Lưu HỎNG → đóng ngay để call-site hiện alert lỗi. KHÔNG hiện màn preview: không có
            // bản ghi nào để trỏ tới, và mời "Đặt hàng ngay" một bản quét vừa lưu hụt là tệ nhất.
            //
            // 🔴 ✗ HẠ `isSaving` TRƯỚC `guard` NÀY. Ở đường hỏng thì `savedRecord` vẫn nil, nên
            // hạ cờ là `showMesh` (xem chỗ dựng ARCameraViewRepresentable) quay lại TRUE suốt
            // hoạt ảnh đóng cover → lớp phủ bật lại và dựng LẠI toàn bộ lưới: copy vertex+index
            // của mọi anchor trên MAIN THREAD (~50–80MB ở nhà lớn) rồi vứt đi 0,3s sau. Đúng
            // khối RAM mà vế `!isSaving` sinh ra để tránh, và nó nổ ngay sau đỉnh RAM export,
            // lúc app vừa lưu hỏng — thay vì hiện alert lỗi sạch sẽ thì có thể bị iOS giết.
            // Đang đóng cover thì không cần hạ cờ nữa.
            guard let saved else {
                dismiss()
                return
            }
            // Thứ tự: đóng dấu bản ghi TRƯỚC rồi mới hạ cờ, để không có nhịp nào rơi vào
            // trạng thái (chưa có savedRecord && không còn đang lưu) làm lưới bật lại một nhịp.
            savedRecord = saved
            isSaving = false
        }
    }
}
