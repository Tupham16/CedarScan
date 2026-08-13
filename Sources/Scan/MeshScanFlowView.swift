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
    /// Lưới XÁM nhẹ (mesh-preview.bin) cho trình xem 3D trong app — file TẠM, `ScanStore`
    /// chuyển vào thư mục bản quét. nil = bản quét này không có (chỉ có video, hoặc dựng hụt)
    /// → hai màn xem đều tự ẩn nút 3D. 🔴 KHÔNG được đóng vào model-colored.zip (máy trạm
    /// bake + tool cắt mặt bằng đọc zip đó) và KHÔNG thêm vào `ScanUploader.fileKinds`.
    let previewURL: URL?
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
    /// 🔴 Closure ĐÓNG COVER, bơm vào từ call site — thay cho `@Environment(\.dismiss)` từ bản
    /// Từ 2.13 màn này là một **LỚP PHỦ** (`ScanCover`, gắn ở `CedarScanApp`), không được TRÌNH
    /// BÀY bằng cover/VC/cửa sổ nào cả — nên `@Environment(\.dismiss)` không có presentation nào
    /// để mà đóng (đời 2.11/2.12 present bằng UIKit thì cũng vậy). Call site truyền
    /// `{ isMeshScanning = false }`; binding lật là `onChange` bên đó gọi `ScanCover.hide`.
    /// Tên giữ nguyên `dismiss` để 8 chỗ gọi trong file không đổi.
    /// CỐ Ý KHÔNG có giá trị mặc định (bẫy #13): quên truyền là cover KHÔNG BAO GIỜ ĐÓNG ĐƯỢC.
    let dismiss: () -> Void
    @EnvironmentObject private var store: ScanStore
    @StateObject private var controller: MeshScanController

    /// Lưu bản quét. Trả về bản ghi đã lưu, hoặc **nil khi lưu HỎNG** — lúc đó cover đóng ngay
    /// và call-site hiện alert lỗi qua pendingSaveError (không hiện alert khi cover còn mở, sẽ
    /// bị nuốt lúc dismiss).
    ///
    /// Tham số thứ HAI là đầu thu % (`SaveStageReport`) — call-site phải chuyển thẳng nó vào
    /// `ScanStore.saveMeshScan(progress:)`. Nửa sau của thời gian chờ (đọc PLY, ghi OBJ, nén
    /// zip) nằm trong `saveMeshScan`, mà view này không gọi hàm đó, nên đây là đường DUY NHẤT
    /// để thanh % không đứng hình ở nửa cuối. ✗ đổi thành tham số có giá trị mặc định (bẫy
    /// #13): call-site quên truyền thì thanh chết im lặng đúng ở đoạn chờ lâu nhất.
    /// 🔴 `@escaping` TRÊN THAM SỐ THỨ HAI LÀ BẮT BUỘC, ✗ gỡ. Tham số kiểu closure mặc định là
    /// NON-ESCAPING, kể cả khi nó nằm trong một function type. Call-site nhận `saveProgress` rồi
    /// chuyển thẳng vào `ScanStore.saveMeshScan(progress:)` — mà tham số đó LÀ `@escaping` (nó bị
    /// `Task.detached` của bước nén zip giữ lại). Thiếu chữ này thì CI chết đúng ở HAI call-site:
    /// "passing non-escaping parameter 'saveProgress' to function expecting an @escaping closure"
    /// (đã dính thật ở lượt build đầu của bản 1.6 — nhánh phiên E tự soi sạch vì trong nhánh đó
    /// chưa có call-site nào chuyển tiếp nó).
    let onFinish: (MeshScanResult, @escaping SaveStageReport) async -> ScanRecord?
    /// Khách bấm "Đặt hàng ngay" ở màn preview. Call-site CHỈ được ghi nhớ ý định ở đây rồi điều
    /// hướng SAU khi cover đóng — cùng lý do với mọi present-trong-onDismiss khác của app này.
    ///
    /// CỐ Ý KHÔNG CÓ GIÁ TRỊ MẶC ĐỊNH. Có `= { _ in }` thì call-site thứ ba ở pha sau quên truyền
    /// vẫn compile sạch, và nút "Đặt hàng ngay" hiện đầy đủ rồi đóng cover mà KHÔNG LÀM GÌ — hỏng
    /// lặng lẽ đúng ở bước chốt đơn. Bắt buộc truyền thì lỗi nổ ngay lúc build.
    let onOrderNow: (ScanRecord) -> Void
    /// Khách bấm "Quét thêm khu vực còn thiếu" ở màn preview. Call-site ghi nhớ ý định rồi mở
    /// lại phiên quét từ `afterScanCoverClosed()` — chạy trong completion của `ScanCover.hide`,
    /// tức SAU khi cover đã đóng hẳn (vai `onDismiss` cũ). Từ 2.11 cú set-true đó nằm ở một nhịp
    /// runloop khác hẳn cú lật false nên `onChange` ở call site bắn lại bình thường — cái bẫy cũ
    /// "set true cùng nhịp lật false bị SwiftUI gộp thành KHÔNG ĐỔI" chỉ áp cho đời
    /// `.fullScreenCover`, ✗ đem nó ra bác khuôn hiện tại.
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
    /// Thanh % của màn "Đang dựng mô hình 3D…" — xem `ScanSaveProgress`. Chỉ được ghi từ
    /// `saveAndClose()` (và từ các hàm xuất qua đầu thu `reporter()`); không màn nào khác đụng.
    /// ⚠ Dựng trong `init` như `controller`, ✗ bằng giá trị mặc định `= ScanSaveProgress()`:
    /// lớp đó `@MainActor` mà struct này có init RIÊNG, nên dạng giá trị mặc định lệ thuộc vào
    /// luật "default value expression thừa hưởng isolation" (SE-0411, Swift 5.10). Dựng thẳng
    /// trong thân init thì đúng ở mọi phiên bản — và máy này không compile được để thử.
    @StateObject private var saveProgress: ScanSaveProgress
    @AppStorage("showScanMesh") private var showScanMesh = true
    /// Đếm ngược khởi động (chủ app chốt 13/08). 3→2→1 rồi 0 = đang chớp chữ "Bắt đầu!";
    /// nil = xong (hoặc chưa bao giờ chạy: máy không hỗ trợ / bị từ chối quyền camera).
    /// BỐN chỗ ghi: `startCountdown()`, `stopTapped()`, nút "Hủy" ở `topBar`, và `.onDisappear` —
    /// ba chỗ sau ghi `nil` và CŨNG LÀ CỜ DỪNG của Task đếm ngược (đọc 🔴 tại `.onDisappear`).
    @State private var countdown: Int?
    /// Đang GIỮ ở "1" chờ mảnh lưới đầu tiên → số thở (mờ đi sáng lại). Tách khỏi `countdown` vì
    /// nó không phải một bước đếm, và vì hoạt ảnh lặp vô hạn phải tắt được bằng một phép gán.
    @State private var countdownHolding = false

    /// ⚠ `onOrderNow` VÀ `onScanMore` PHẢI được truyền kèm NHÃN ở call-site. Viết trailing closure mà bỏ nhãn thì
    /// forward-scan (SE-0286) khớp closure đó vào `onOrderNow` chứ không phải `onFinish` → lỗi
    /// kiểu khó đọc, mất một vòng CI. Xem hai call-site đang có: HomeView và ProjectView.
    init(
        quality: MeshQuality,
        onOrderNow: @escaping (ScanRecord) -> Void,
        onScanMore: @escaping () -> Void,
        // `dismiss` từ 2.11 — xem chú thích ở thuộc tính. Đặt TRƯỚC `onFinish` để onFinish vẫn là
        // trailing closure ở hai call site (đổi chỗ là dính đúng bẫy forward-scan SE-0286 ở trên).
        dismiss: @escaping () -> Void,
        // Hai chữ `@escaping` ở đây khác vai: cái ĐẦU nói bản thân `onFinish` sống lâu hơn init;
        // cái trong ngoặc nói THAM SỐ THỨ HAI của nó cũng escaping — xem chú thích ở thuộc tính.
        onFinish: @escaping (MeshScanResult, @escaping SaveStageReport) async -> ScanRecord?
    ) {
        _controller = StateObject(wrappedValue: MeshScanController(quality: quality))
        _saveProgress = StateObject(wrappedValue: ScanSaveProgress())
        self.onOrderNow = onOrderNow
        self.onScanMore = onScanMore
        self.dismiss = dismiss
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
            // recordedCounts: lưới trắng = đã vào file. Đỏ giữ vai "chưa được ghi" (builder
            // tắt vì gián đoạn, hoặc mô hình đầy). Vùng chưa có mesh thì lớp phủ tự tô đỏ mờ
            // (xem `MeshOverlayRenderer`).
            // 🔴 photoCoverage KHÔNG NỐI NỮA (chủ app chốt 06/08) — trước đó trắng còn đòi
            // "đã có ẢNH texture lưu" (item 2, 03/08). Điều kiện ảnh bị RÚT khỏi hiển thị vì
            // sổ voxel độ phủ ghi theo toạ độ THẾ GIỚI CŨ: ARKit khép vòng kéo anchor đi mà
            // không kéo sổ theo → quay lại vùng cũ là phán quyết tụt oan (chớp trắng→đỏ, đỉnh
            // điểm "60% vùng đỏ" ở 11c08e2 — đã hoàn). 5 bản vá tầng hiển thị đều chết vì gốc
            // này; chi tiết ở SESSION-HANDOFF §STATE `b7b6d47`. Recorder VẪN CHỤP ẢNH đầy đủ
            // (nhịp riêng, không liên quan màu lưới) — bản giao không đổi. Closure nil =
            // renderer đi đường cũ byte-for-byte (bất biến ghi ở `MeshOverlayRenderer`).
            // ✗ nối lại khi chưa sửa GỐC sổ-theo-anchor và chưa hỏi chủ app.
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
                recordedCounts: { [weak controller] in controller?.recordedAnchorCounts ?? [:] }
                // photoCoverage CỐ Ý không truyền (default nil) — đọc chú thích 🔴 ở trên.
            )
            .ignoresSafeArea()

            if !isSaving && !showNaming && savedRecord == nil {
                QualityAlertOverlay(monitor: controller.qualityMonitor)
                // Cùng bộ gác với QualityAlertOverlay: bấm "Dừng & Lưu" trong lúc còn đang đếm là
                // ca có thật (khách đổi ý ngay), và một con số to nằm giữa màn đặt tên thì vô nghĩa.
                countdownOverlay
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
            // Khoá việc dọn-sau-khi-giao suốt phiên quét. Chuỗi tai nạn nếu không khoá (đời
            // `.fullScreenCover`, trước 2.11): dọn chạy lúc app quay lại foreground → xoá dự án
            // → ProjectView tự dismiss → cover bị tháo theo → mất trắng 10–30 phút. Từ 2.11 cover
            // present bằng UIKit từ VC trên cùng nên pop ProjectView KHÔNG tháo cover nữa — nhưng
            // khoá VẪN BẮT BUỘC: dọn giữa buổi là `saveMeshScan` ghi vào dự án đã xoá, và pop
            // ProjectView là gỡ mất cái `.onChange` đang cầm đường ĐÓNG cover của phiên này.
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
            case .authorized:
                controller.startSession()
                // SAU startSession, ✗ trước: đếm ngược là cái lấp quãng ARKit khởi động, nên đồng
                // hồ của nó phải chạy cùng lúc với `arSession.run`.
                startCountdown()
            default:
                // `.notDetermined` — lần quét ĐẦU TIÊN của máy, đúng một lần trong đời: iOS bật hộp
                // xin quyền ngay khi `arSession.run`, hộp đó che màn hình và ARKit không trả khung
                // nào cho tới khi khách bấm Cho phép. Đếm ngược sau lưng nó là đếm cho tường nghe —
                // hết đếm thì khách vẫn đang đọc hộp quyền. ✗ gộp nhánh này vào `.authorized`.
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
            // 🔴 CŨNG LÀ CỜ DỪNG CỦA `startCountdown` — ✗ gỡ. Task đếm ngược sống tới ~8s, dài hơn
            // mọi lối thoát. ⚠ HAI lối CÓ NÚT BẤM không trông vào dòng này: `stopTapped` và nút
            // "Hủy" ở `topBar` tự tắt cờ SỚM HƠN, vì `.onDisappear` chỉ bắn ở CUỐI quãng trượt 0,3s
            // của `ScanCover.hide` — ✗ đọc dòng này thành "hai chỗ kia thừa" rồi gỡ chúng.
            // Dòng này là lưới cuối cho lối thoát KHÔNG qua hai nút đó: alert "Cần quyền Camera"
            // bật GIỮA một phiên đã `.authorized` (ARKit báo `cameraUnauthorized` qua `.onChange`
            // bên trên), cả hai nút của alert chỉ gọi `dismiss()`.
            countdown = nil
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
                // ✗ GỠ. `.onDisappear` KHÔNG kịp: `ScanCover.hide` gỡ view bằng hoạt ảnh 0,3s nên
                // onDisappear chỉ bắn ở CUỐI quãng trượt — trong 0,3s đó Task đếm ngược vẫn chạy và
                // có thể rung một nhịp lên tay khách khi màn quét đang bay đi. `stopTapped` đã lo
                // đường Dừng & Lưu; đây là đường còn lại.
                countdown = nil
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

    /// Màn chờ sau khi bấm Lưu. Khuôn lấy từ `ScanDetailView.progressRow` (thanh + % của
    /// đoạn upload) — chủ app đã quen nhìn nó và tự lấy nó ra làm chuẩn khi đặt yêu cầu.
    ///
    /// Bố cục: tiêu đề CỐ ĐỊNH (giữ nguyên câu của bản 1.4) → thanh % → dòng "đang làm gì +
    /// bao nhiêu %" → một câu đặt kỳ vọng. Bốn dòng, hơn bản cũ đúng MỘT dòng.
    /// 🔴 Vòng xoay nhỏ chỉ hiện ở chặng KHÔNG báo được % bên trong (`showsSpinner`) — nó là
    /// lời nói thật "máy vẫn chạy, chỗ này không đếm được", ✗ đổi nó thành thanh tự bò.
    private var savingOverlay: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 10) {
                Text(L.t("Building 3D model…", "Đang dựng mô hình 3D…"))
                    .font(.headline)
                ProgressView(value: saveProgress.fraction)
                HStack(spacing: 6) {
                    if saveProgress.stage.showsSpinner {
                        ProgressView().controlSize(.small)
                    }
                    Text(saveProgress.stage.label)
                    Spacer(minLength: 8)
                    // `.font(.footnote.monospacedDigit())` chứ ✗ `.monospacedDigit()` trần:
                    // khuôn của `ScanDetailView.progressRow` (đã qua CI), và bản View của
                    // modifier đó mới có từ iOS 16 — dạng Font thì iOS 15 đã có.
                    Text("\(Int(saveProgress.fraction * 100))%")
                        .font(.footnote.monospacedDigit())
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                // Câu cũ ("Mức nét cao có thể mất một lúc.") nói về một PICKER đã bỏ từ
                // 31/07 và không đặt được kỳ vọng nào. Câu mới nói đúng thứ khách cần biết:
                // nhà lớn thì lâu. Giữ MỘT dòng — chủ app không thích màn hình phình ra.
                Text(L.t(
                    "A whole house can take a few minutes.",
                    "Nhà lớn có thể mất vài phút."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            // Thanh ngang nở hết bề rộng được đề nghị, nên phải kẹp lại — không thì hộp
            // material kéo dài sát hai mép màn hình và không còn ra hình cái thẻ.
            .frame(maxWidth: 260)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - Đếm ngược 3-2-1 lúc khởi động

    /// Trần chờ "mảnh lưới đầu tiên" SAU khi đã đếm hết 3-2-1. Phòng tối om hoặc toàn kính có thể
    /// KHÔNG BAO GIỜ sinh đỉnh nào — hết trần thì con số MỜ ĐI IM LẶNG (✗ "Bắt đầu!", ✗ rung; xem
    /// khối 🔴 trong `startCountdown`) và bàn giao cho tấm phủ đỏ.
    ///
    /// 🔴 THỨ PHẢI LỚN HƠN LÀ `1,8s + countdownMaxWait` so với LÚC TẤM PHỦ ĐỎ LÊN — ✗ so thẳng hằng
    /// số này với `MeshOverlayRenderer.warmupGraceSec` (hai cái chạy hai đồng hồ khác nhau, số thật
    /// tính ngay dưới đây) ⇒ sàn của nó ≈ `warmupGraceSec` − 0,9; nay 5,5, dư 0,4s.
    /// Bản đầu để 3,5 với ý "hai cái cùng hết hạn" và tính sai: đếm 3-2-1 hết 1,8s nên số tắt ở
    /// 1,8+3,5 = **5,3s** kể từ `arSession.run`, trong khi tấm phủ đỏ bật ở 6,0s kể từ KHUNG CAMERA
    /// ĐẦU (muộn hơn `run` 0,2–0,5s) và chỉ được xét mỗi nhịp `meshUpdateInterval` 0,5s ⇒ thực tế
    /// **6,2–6,9s**. Hở gần một giây màn hình không còn tín hiệu nào, đúng ngay ca không quét được
    /// gì. Nay 5,5 ⇒ số tắt ở ~7,3s, tức MỜ ĐI SAU khi tấm phủ đã lên: giao ca chồng lấn thay vì hở.
    /// Trần này CHỈ áp cho đường không có đỉnh nào — buổi quét bình thường thoát vòng chờ ngay lúc
    /// có đỉnh, nên nới nó không bắt ai chờ thêm một phần nghìn giây.
    private static let countdownMaxWait: TimeInterval = 5.5

    /// Số đếm ngược nổi giữa hình camera trong lúc ARKit khởi động.
    ///
    /// ✗ nền tối, ✗ vòng xoay, ✗ dòng chữ giải thích: khách vẫn phải NHÌN được phòng để nhắm máy,
    /// và màn quét này chủ app giữ tối giản. Bóng đổ đủ để số nổi trên cả tường trắng.
    @ViewBuilder
    private var countdownOverlay: some View {
        if let countdown {
            Text(countdown > 0 ? "\(countdown)" : L.t("Go!", "Bắt đầu!"))
                .font(.system(size: 92, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.35)
                .lineLimit(1)
                .padding(.horizontal, 24)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 12, y: 2)
                // Đổi `id` là SwiftUI coi mỗi con số là một view KHÁC → chạy transition cho từng
                // nhịp đếm. Không có nó thì chữ chỉ nhảy số, không có hoạt ảnh nào.
                .id(countdown)
                .transition(.scale(scale: 0.75).combined(with: .opacity))
                // SỐ THỞ trong lúc GIỮ ở "1" chờ ARKit. ✗ trang trí: đếm 3-2-1 đều đặn 0,9s một
                // nhịp rồi ĐỨNG IM 0,5–2s là đọc thành "treo máy" — đúng cái cảm giác bộ đếm sinh
                // ra để chữa. Thở = còn sống mà chưa xong, không phải thêm chữ hay vòng xoay.
                .opacity(countdownHolding ? 0.4 : 1)
                .animation(
                    countdownHolding
                        ? .easeInOut(duration: 0.65).repeatForever(autoreverses: true)
                        : .easeOut(duration: 0.18),
                    value: countdownHolding
                )
                // Nằm giữa màn, ngay trên nút "Dừng & Lưu" và nút "Hủy" — ✗ để nó ăn cú chạm.
                .allowsHitTesting(false)
                // VoiceOver đã đọc nút Hủy / Dừng & Lưu; một con số đếm không thêm gì mà cắt ngang.
                .accessibilityHidden(true)
        }
    }

    /// Đếm 3-2-1 phủ lên hình camera trong lúc ARKit khởi động (chủ app chốt 13/08:
    /// *"nên cho bộ đếm ngược 3 2 1 trước màn hình là đẹp"*).
    ///
    /// 🔴 **KHÔNG PHẢI một cái hẹn giờ 3 giây rồi thôi.** ARKit cần 2–4s (camera+LiDAR bật → VIO
    /// định vị ~1,6s → mảnh mesh đầu tiên) và con số đó KHÔNG cố định: phòng tối, máy nóng, khách
    /// đứng im đều kéo dài. Đếm hết rồi biến mất khi máy CHƯA sẵn sàng là hứa suông — khách nhìn
    /// màn hình trống tiếp, tệ hơn không đếm. Nên: đếm xong thì GIỮ Ở "1" tới khi bản quét có đỉnh
    /// đầu tiên (trần `countdownMaxWait`), rồi mới chớp "Bắt đầu!".
    ///
    /// Mốc "sẵn sàng" là `meshVertexCount > 0` = ĐÃ CÓ DỮ LIỆU VÀO BẢN QUÉT, chứ ✗ "tracking đã
    /// normal" (về normal xong vẫn còn chờ mảnh mesh đầu) và ✗ đếm anchor của ARKit (anchor sinh ra
    /// rỗng trước, có tam giác sau). Mốc này trễ ~0,2–0,3s so với MẢNH MESH ĐẦU của ARKit (tick
    /// builder 2–5Hz + nhịp dò 0,12s) — tức xấp xỉ CÙNG LÚC với lưới trắng trên màn, vì lưới cũng
    /// tự trễ tới 0,5s (`meshUpdateInterval`) rồi còn dựng ở luồng nền. ⚠ Cái nào tới trước là TUỲ
    /// PHA hai display link, ✗ có bảo đảm thứ tự — đừng viết chú thích hứa thứ tự đó.
    ///
    /// `Task { @MainActor in }` chứ ✗ `Task {}` trần: thân hàm đụng `withAnimation`, haptics và
    /// `@State` — tất cả đều phải trên main, mà `Task {}` trong một hàm không isolation thì chạy ở
    /// executor NỀN. (Khác `saveAndClose`: ở đó câu `await` đầu tiên tự nhảy về main.)
    private func startCountdown() {
        Task { @MainActor in
            let tick = UIImpactFeedbackGenerator(style: .light)
            tick.prepare()
            countdown = 3
            tick.impactOccurred()
            for n in [2, 1] {
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard countdown != nil else { return } // khách đã bấm Dừng & Lưu giữa chừng
                withAnimation(.easeOut(duration: 0.18)) { countdown = n }
                tick.impactOccurred()
            }
            // 🔴 GIẤC NGỦ DƯỚI ĐÂY LÀ BẮT BUỘC, ✗ GỠ, ✗ GỘP VÀO VÒNG `while`. Từ `countdown = 1`
            // (ngay trên) tới `countdown = 0` (dưới) KHÔNG còn câu `await` nào nếu vòng `while` sai
            // điều kiện ngay lần đo ĐẦU — ca thật: máy ấm, quét lại phòng vừa quét ("Quét thêm")
            // thì đã có đỉnh trước giây 1,8. Hai phép gán rơi vào CÙNG một lượt main-actor, SwiftUI
            // chỉ vẽ giá trị cuối ⇒ khách thấy "3, 2, Bắt đầu!" — mất hẳn số 1 — và rung nhẹ dính
            // vào rung `.success` thành một tiếng ù.
            // `deadline` chốt TRƯỚC giấc ngủ để trần chờ vẫn tính từ lúc số 1 hiện ra.
            let deadline = Date().addingTimeInterval(Self.countdownMaxWait)
            try? await Task.sleep(nanoseconds: 450_000_000)
            // 🔴 `countdownHolding` BẬT SAU GIẤC NGỦ, ✗ TRƯỚC. Đặt trước thì phép gán rơi vào ĐÚNG
            // lượt main-actor vừa đổi `countdown` 2→1 (từ `withAnimation` ở trên xuống đây không còn
            // `await` nào nên SwiftUI không vẽ xen vào giữa được) — mà lượt đó `.id(countdown)` DỰNG
            // MỚI con số. `.animation(…, value:)` không chạy ở lượt view VỪA XUẤT HIỆN: nó cần một
            // cú ĐỔI trên danh tính đã có. ⇒ nhịp thở không lên dây, số "1" nằm chết ở `opacity 0.4`:
            // mờ VÀ bất động, tệ hơn cả không thở, đúng cái "treo máy" nó sinh ra để chữa.
            // Bật sau giấc ngủ thì gán lên con số ĐÃ VẼ RỒI. Ý cũ giữ nguyên: có đỉnh rồi thì gán
            // `false`, vòng `while` dưới sai điều kiện ngay từ đầu, không thở nửa nhịp vô duyên.
            countdownHolding = controller.meshVertexCount == 0
            while controller.meshVertexCount == 0, Date() < deadline {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            countdownHolding = false
            guard countdown != nil else { return }
            // 🔴 VÒNG TRÊN THOÁT THEO HAI ĐƯỜNG KHÁC HẲN NHAU — ✗ gộp lại. Có đỉnh = mừng thật.
            // HẾT TRẦN mà vẫn 0 đỉnh (phòng tối om / toàn kính / phiên bị gián đoạn ngay lúc khởi
            // động) thì chữ "Bắt đầu!" + rung `.success` là CHÚC MỪNG MỘT BẢN QUÉT RỖNG, rồi ~1 giây
            // sau tấm phủ đỏ nói ngược lại. Đó đúng là "tín hiệu sai chủ động" mà `MeshOverlayView`
            // cấm ba lần trong một file, và `.success` là tiếng "được rồi" DUY NHẤT của app này.
            // Đường hết trần: số chỉ MỜ ĐI, im lặng, nhường lời cho tấm phủ đỏ (`warmupGraceSec`).
            if controller.meshVertexCount > 0 {
                withAnimation(.easeOut(duration: 0.18)) { countdown = 0 }
                // Rung một nhịp ở đúng lúc lưới lên: người quét lúc này đang nhìn CĂN PHÒNG chứ
                // không nhìn màn hình (cùng lý do với rung "mô hình đã đầy" ở MeshScanController).
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard countdown != nil else { return }
            }
            withAnimation(.easeIn(duration: 0.25)) { countdown = nil }
        }
    }

    private func stopTapped() {
        // Bấm Dừng & Lưu là hết vai của đếm ngược, kể cả khi nó còn đang đếm dở: từ đây màn hình
        // thuộc về hộp xác nhận / màn đặt tên. Cũng là cờ dừng của vòng lặp trong `startCountdown`.
        countdown = nil
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
        let folder = store.folderURL(for: record)
        let videoURL = folder.appendingPathComponent("scan-video.mp4")
        let playable = FileManager.default.fileExists(atPath: videoURL.path) ? videoURL : nil
        // Lưới xám để khách xem ngay tại đây (chủ app duyệt 10/08). `fileExists` chứ ✗ tin
        // `exported.previewURL`: file đó là URL TẠM và đã bị `saveMeshScan` MOVE đi — cùng
        // cái bẫy với video ở trên. Không có file (bản chỉ-có-video, dựng hụt, hoặc bản quét
        // của bản app cũ) → ScanPreviewView tự ẩn nút "Mô hình 3D".
        let meshPreview = folder.appendingPathComponent(MeshPreviewFile.fileName)
        let viewableMesh = FileManager.default.fileExists(atPath: meshPreview.path)
            ? meshPreview : nil
        return ScanPreviewView(
            addressName: store.project(with: record.projectId)?.name,
            scanName: record.name,
            videoURL: playable,
            meshPreviewURL: viewableMesh,
            // 🔴 Đây là chỗ chủ app mô tả TRỰC TIẾP: *"khi bấm vào đó rồi quét xong thì cái nút
            // đặt hàng ngay nên sửa lại là Gửi bổ sung bản quét"*. Điều kiện hỏi
            // `ScanStore.orderNumber(ofProject:)` — cùng nguồn với nhãn nút ở `ProjectView` và
            // với việc `ScanDetailView.autoOpenOrderIfNeeded()` mở màn nào sau khi push.
            isSupplement: store.orderNumber(ofProject: record.projectId) != nil,
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
        saveProgress.reset()
        // MỘT đầu thu dùng chung cho cả hai nửa (xuất trong controller + nén trong ScanStore):
        // thang % là một dải liền, hai nửa chỉ khác nhau ở chặng nào đang chạy.
        let report = saveProgress.reporter()
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
            let exported = await controller.stopAndExport(progress: report)
            let result = MeshScanResult(
                videoURL: exported.videoURL,
                meshURL: exported.meshURL,
                trackURL: exported.trackURL,
                texshotsDir: exported.texshotsDir,
                previewURL: exported.previewURL,
                name: name.isEmpty ? nil : name,
                quality: controller.quality,
                hitCap: exported.hitCap,
                geometryOnly: exported.geometryOnly
            )
            let saved = await onFinish(result, report)
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
            // 100% CHỈ ở đây, trong cùng một nhịp main với việc chuyển sang màn preview: mọi
            // việc đã xong thật. SwiftUI gộp ba phép gán này thành MỘT lượt dựng lại, nên
            // khung 100% gần như không bao giờ được vẽ — đúng yêu cầu "✗ chạm 100% trước khi
            // màn preview hiện ra". ✗ chuyển dòng này lên trước `guard let saved`.
            saveProgress.report(.packaging, 1)
            // Thứ tự: đóng dấu bản ghi TRƯỚC rồi mới hạ cờ, để không có nhịp nào rơi vào
            // trạng thái (chưa có savedRecord && không còn đang lưu) làm lưới bật lại một nhịp.
            savedRecord = saved
            isSaving = false
        }
    }
}
