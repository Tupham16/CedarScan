import ARKit
import SwiftUI

struct HomeView: View {
    /// Tín hiệu từ tab SCAN (RootView): mỗi lần TĂNG = một yêu cầu mở màn quét mới. Xem `.onChange`.
    let scanRequest: Int
    /// 🔴 TRUYỀN VÀO TỪ `RootView`, ✗ `@EnvironmentObject` — LÝ DO KHÁC hai màn PUSH, đọc kỹ.
    /// Bản thân HomeView chưa bao giờ văng: nó là GỐC của `NavigationStack` (không bị push) và
    /// tiêu đề là chuỗi CHẾT. Đổi ở đây là để ba closure `navigationDestination` bên dưới dựng
    /// `ProjectView`/`ScanDetailView` bằng một THAM CHIẾU THƯỜNG, thay vì phải đọc
    /// `@EnvironmentObject` ngay trong nhịp đẩy màn. Giữ nguyên `@EnvironmentObject` ở đây thì
    /// bản vá phải dựa vào lập luận *"closure đã capture wrapper từ lúc environment còn nối nên
    /// không sao"* — có lẽ đúng, nhưng ĐÚNG LOẠI lập luận đã sai ba lần ở vụ này. ✗ đổi ngược.
    /// Xem khối 🔴🔴 ở `ProjectView.store`.
    @ObservedObject var store: ScanStore
    /// CHỈ để CHUYỂN TIẾP xuống hai màn PUSH — HomeView không tự đọc `account` dòng nào.
    ///
    /// 🔴 `let`, ✗ `@ObservedObject` — CỐ Ý, đừng "sửa cho giống `store`". HomeView TRƯỚC GIỜ
    /// không hề khai `AccountStore`, tức không quan sát nó. Khai `@ObservedObject` ở đây là THÊM
    /// một phụ thuộc chưa từng có: mỗi lần `AccountStore` đổi (đăng nhập, `refresh()` lúc vào
    /// foreground, đổi cờ xác minh) sẽ dựng lại body của Home — một hồi quy hiệu năng do CHÍNH
    /// bản vá crash đẻ ra. `let` giữ đúng hành vi cũ, và hai màn PUSH nhận nó vẫn quan sát bình
    /// thường vì `@ObservedObject` tự đăng ký lấy.
    let account: AccountStore
    @State private var isMeshScanning = false
    /// Bấm SCAN trên máy không có LiDAR → alert giải thích (thay cho nút xám cũ ở đáy Home).
    @State private var showScanUnsupported = false
    @State private var showScanSetup = false
    /// Khách đã bấm "Bắt đầu quét" trong `ScanAddressView` (khác hẳn "sheet đã đóng"). Thay cho
    /// `pendingScanMode: ScanMode?` cũ — enum ScanMode chết cùng RoomPlan, nhưng cơ chế thì
    /// PHẢI giữ nguyên: bấm "Hủy" hay vuốt đóng sheet cũng chạy onDismiss, và không có cờ này
    /// thì hai đường đó cũng nhảy thẳng vào màn quét.
    @State private var pendingScanStart = false
    /// Khách bấm "Quét thêm khu vực còn thiếu" ở màn preview → mở lại phiên quét cho CÙNG căn.
    @State private var pendingScanMore = false
    /// Bản quét khách vừa bấm "Đặt hàng ngay" ở màn preview — điều hướng SAU khi cover đóng.
    @State private var pendingOrderRecord: ScanRecord?
    /// Đường dẫn điều hướng. Trước đây NavigationStack không có path (mọi lần đẩy đều qua
    /// NavigationLink), nhưng màn preview cần ĐẨY BẰNG CODE tới trang bản quét.
    @State private var path = NavigationPath()
    /// Căn nhà (dự án) mà bản quét sắp tới sẽ thuộc về — do ScanAddressView chọn/tạo.
    ///
    /// CỐ Ý KHÔNG XOÁ sau mỗi bản quét: có HAI lối vào `isMeshScanning` KHÔNG đi qua màn địa chỉ
    /// — alert "Quét phần còn lại ngay", và `onDismiss` của cover khi khách bấm "Quét thêm" ở màn
    /// preview. Cả hai cố ý dùng lại giá trị cũ, và đó chính là thứ làm bản quét thứ hai rơi vào
    /// ĐÚNG căn nhà của bản đầu.
    ///
    /// ⚠ GIÁ TRỊ NÀY CÓ THỂ CŨ. Chỉ nút "Bắt đầu quét" trong ScanAddressView mới ghi đè nó;
    /// bấm "Hủy" hoặc vuốt đóng sheet thì nó GIỮ NGUYÊN giá trị của lần quét trước.
    /// Hiện vô hại vì hai đường đó cũng không set `pendingScanStart` nên onDismiss return sớm,
    /// không bản quét nào chạy. NHƯNG: pha sau mà thêm bất kỳ lối vào `isMeshScanning` nào KHÔNG
    /// đi qua ScanAddressView thì bản quét mới sẽ lặng lẽ rơi vào căn nhà của lần quét TRƯỚC ĐÓ
    /// — sai địa chỉ trên thẻ gửi đội vẽ mà không có dấu hiệu gì. Thêm lối vào như vậy thì phải
    /// đặt lại `pendingProjectId` tường minh ở đó.
    @State private var pendingProjectId: UUID?
    @State private var meshCapFollowUp = false
    @State private var showScanNextPart = false
    @State private var recordToRename: ScanRecord?
    /// Dự án khách vừa bấm giỏ rác — cũng là cờ bật hộp xác nhận (mục 6). Giữ CẢ ĐỐI TƯỢNG chứ
    /// không phải một Bool + một id riêng: hai `@State` set cùng một nhịp là đúng cái race đã làm
    /// form đặt hàng của `ProjectView` hiện ra TRẮNG (bẫy #7/#20c).
    @State private var projectToDelete: ScanProject?
    @State private var renameText = ""
    @State private var saveError: String?
    @State private var pendingSaveError: String?
    /// Chữ trong ô tìm kiếm (`.searchable`). CHỈ lọc phần hiển thị — không đụng gì tới `store`.
    @State private var searchText = ""
    @State private var showGuide = false
    /// Người dùng ĐÃ BẤM nút "Bắt đầu quét" trong guide. Tách khỏi việc "sheet đang mở" vì nút
    /// "Đóng" cũng dismiss cùng một sheet — gộp một cờ thì đóng guide sẽ tự nhảy vào màn quét.
    ///
    /// RESET Ở LỐI VÀO, không chỉ ở onDismiss: nếu có đúng một lần onDismiss không chạy (view
    /// bị dựng lại/đổi identity giữa lúc sheet đang đóng — rất dễ xảy ra khi P3–P6 sắp tới đổi
    /// cấu trúc màn hình) thì cờ kẹt `true`, và lần sau người dùng chỉ mở guide để ĐỌC rồi đóng
    /// lại là app tự nhảy vào màn quét. Đặt lại ở cả hai lối vào biến chuyện đó thành bất khả
    /// thi về cấu trúc, thay vì phải tin rằng onDismiss luôn luôn chạy.
    @State private var startAfterGuide = false

    /// Máy có LiDAR không. Hỏi thẳng ARKit: thứ app thật sự cần là mesh scene reconstruction.
    /// (RoomPlan đã bị gỡ hẳn 2026-07-20 nên `RoomCaptureSession.isSupported` cũng không còn.)
    /// Cùng phép thử với `MeshScanController.isSupported`.
    private var isSupported: Bool {
        // 🔴 BỘ ĐO TẠM (gỡ cùng `SafeAreaHarness.swift`). Harness PHẢI đi ĐÚNG đường của chủ app:
        // đĩa SCAN → cú nảy tab ở `RootView.onChange(of: tab)` → màn địa chỉ. Simulator không có
        // LiDAR nên nhánh thật rẽ sang alert "Cần LiDAR" và đường đo đứt đúng chỗ cần đo.
        // Nới CHỈ khi cờ harness bật ⇒ app của khách không đổi: không có launch argument thì
        // `isEnabled` = false và biểu thức này y hệt bản cũ.
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) || SafeAreaHarness.isEnabled
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.records.isEmpty && store.projects.isEmpty {
                    emptyState
                } else {
                    mainList
                }
            }
            .navigationTitle("CedarScan")
            // 🔴 Ô TÌM KIẾM PHẢI GẮN Ở ĐÂY — CÙNG CẤP VỚI `.navigationTitle`, TUYỆT ĐỐI KHÔNG
            // GẮN VÀO TRONG `mainList`.
            //
            // Bản đầu (2026-07-23) gắn nó cho `mainList`, tức NẰM TRONG nhánh `else` của cái
            // `Group { if … } else { … }` ngay trên. `.searchable` không phải một view — SwiftUI
            // dịch nó thành một `UISearchController` cắm vào `navigationItem` của view controller
            // GỐC trong `UINavigationController` mà `NavigationStack` dựng ra. Đặt nó trong một
            // nhánh điều kiện là buộc vòng đời của search controller vào một subtree mà SwiftUI
            // có quyền tháo và dựng lại bất cứ lúc nào — trong khi thứ nó cắm vào lại là thanh
            // điều hướng DÙNG CHUNG cho cả stack. Tháo/cắm lại đúng lúc `UINavigationController`
            // đang chạy dở một cú push là kiểu làm UIKit mất đồng bộ.
            //
            // Chủ app báo "thỉnh thoảng bấm vào dự án là app tự văng", và đây là ứng viên số 1:
            // `.searchable` là thứ DUY NHẤT mới thêm vào đúng đường đi đó ở bản `85bab71`, và
            // năm lần soi độc lập đều chỉ về chỗ này.
            //
            // GIÁ PHẢI TRẢ, CHẤP NHẬN CÓ CHỦ ĐÍCH: máy chưa có bản quét nào thì ô tìm kiếm vẫn
            // hiện (trước đây nhánh `emptyState` không có nó). Vô hại và đúng chuẩn iOS — Mail,
            // Files, Ảnh đều bày ô tìm kiếm trên màn rỗng. Đừng "sửa cho đẹp" bằng cách nhét lại
            // modifier này vào trong nhánh điều kiện.
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: L.t("Search homes and scans", "Tìm dự án, bản quét")
            )
            // 🔴 BỘ ĐO TẠM (gỡ cùng `SafeAreaHarness.swift`). No-op khi không có launch argument.
            // Dựng sẵn một dự án để XCUITest có đường vào `ProjectView` — nơi có nhãn đo — vì
            // trên simulator không tạo dự án bằng đường thật được (không có LiDAR).
            // 🔴 `await` BẮT BUỘC: closure của `.task` là `@Sendable`, KHÔNG thừa hưởng isolation,
            // mà `seedIfNeeded` là `@MainActor` (nó đụng `ScanStore`, vốn `@MainActor`). Thiếu chữ
            // này là lỗi biên dịch — mà máy Windows không compile được để bắt. Cùng khuôn với
            // `RootView.task { await purgeDeliveredScans() }`.
            .task { await SafeAreaHarness.seedIfNeeded(store) }
            // (`SafeAreaRepair` — ba phát "sửa-từ-ngoài" bắn từ onAppear của màn này — ĐÃ XOÁ HẲN
            // ở 2.13. Nó được ĐO là TRƠ: lúc đang lỗi, `fix 9` cho biết nó đã chạy 9 lượt và cú
            // bắn tay bỏ mọi cổng cũng không sửa được gì. Xoá cùng lượt với bản vá lớp phủ vì cổng
            // an toàn của nó — "đang có presentation full-screen thì đừng sửa" — nay không bao giờ
            // đúng nữa (cover hết là presentation), tức nó sẽ co cửa sổ 0,5pt GIỮA BUỔI QUÉT.
            // Lịch sử đầy đủ ở `ScanCover.swift`. ✗ dựng lại.)
            // TOOLBAR ĐÃ GỠ HẲN (2026-07-23, chủ app chốt):
            //  • nút **?** "Cách quét" → chuyển vào tab **Learn** ở thanh dưới.
            //  • nút **folder** "Dự án mới" → thừa: từ khi màn địa chỉ là bắt buộc, MỌI bản quét
            //    đều tự tạo/gắn dự án ngay lúc bắt đầu quét. Tạo một dự án RỖNG bằng tay chỉ đẻ ra
            //    thư mục không có bản quét nào.
            // Nhờ vậy đầu màn chỉ còn tiêu đề + ô tìm kiếm.
            // Bắt đầu quét từ onDismiss, KHÔNG gọi thẳng trong callback của guide: ScanGuideView
            // gọi dismiss() rồi onStart() trong CÙNG một transaction, nên present thẳng ở đó là
            // present-trong-lúc-sheet-đang-đóng — đúng thứ mà chú thích ngay dưới cảnh báo.
            // Hậu quả nếu không sửa: lần cài MỚI đầu tiên, bấm "Hiểu rồi — bắt đầu quét" thì
            // guide đóng mà sheet địa chỉ không hiện, người dùng phải bấm nút Quét lần hai. Và vì
            // seenKey đã được set TRƯỚC dismiss nên lần hai đi thẳng — lỗi tự lành và không bao
            // giờ tái hiện trên máy đã dùng, tức không thể bắt được bằng test thủ công thông thường.
            .sheet(isPresented: $showGuide, onDismiss: {
                guard startAfterGuide else { return }
                startAfterGuide = false
                startScanning()
            }) {
                // KHÔNG còn nhánh "chỉ xem": nút **?** đã gỡ khỏi toolbar (hướng dẫn giờ nằm ở tab
                // Learn), nên sheet này CHỈ còn một lối vào duy nhất là `beginNewScan()` — luôn là
                // luồng "đọc xong rồi quét".
                //
                // 🔴 Cờ `guideThenScan` cũ đã XOÁ chứ không để lại cho "chắc ăn": nó được set CÙNG
                // NHỊP với `showGuide`, mà `.sheet(isPresented:)` dựng nội dung ngay lúc cờ lật
                // true — đúng cái race đã trả giá ở `ProjectView` (bẫy #20c trong handoff). Nếu
                // `guideThenScan` chưa kịp commit thì lần đầu tiên khách mở app sẽ thấy hướng dẫn
                // KHÔNG có nút "Bắt đầu quét", đóng lại thì cũng không quét — ngõ cụt im lặng.
                ScanGuideView { startAfterGuide = true }
            }
            // Mở cover từ onDismiss của sheet (chờ sheet đóng XONG mới present) —
            // present-trong-lúc-sheet-đang-đóng là kiểu dễ rớt presentation nhất.
            .sheet(isPresented: $showScanSetup, onDismiss: {
                guard pendingScanStart else { return }
                pendingScanStart = false
                isMeshScanning = true
            }) {
                // Không .presentationDetents: đây là Form nhiều mục (hai nút tắt + ô địa chỉ +
                // gợi ý), ép .medium là phần gợi ý bị bóp còn một hai dòng.
                ScanAddressView { projectId in
                    pendingProjectId = projectId
                    pendingScanStart = true
                }
            }
            // 🔴🔴 COVER QUÉT LÀ **LỚP PHỦ SwiftUI** TỪ 2.13 (`ScanCover`, gắn ở `CedarScanApp`)
            // — ✗ quay lại BẤT KỲ kiểu trình bày nào: `.fullScreenCover` (2.6→2.10),
            // `.overFullScreen` bằng UIKit (2.11), CỬA SỔ RIÊNG (2.12) — cả ba đều đã ra IPA và
            // đều để lại đúng lỗi "lề SwiftUI đông cứng ở 0 sau khi mở màn quét". Danh sách 7
            // hướng đã chết bằng đo + số đo: `ScanCover.swift`.
            //
            // ⚠ ĐÂY LÀ `.onChange(of: isMeshScanning)` — thứ mà chú thích cũ (06/08) CẤM. Lệnh
            // cấm đó vẫn ĐÚNG cho ca nó cấm, và khối này KHÔNG rơi vào ca đó:
            //  · Cái 06/08 cấm là chạy VIỆC HẬU-QUÉT (push/alert) NGAY LÚC binding lật false —
            //    tức giữa hoạt ảnh đóng cover. Ở đây nhánh `false` CHỈ gọi
            //    `ScanCover.hide(completion:)`; mọi việc hậu-quét nằm trong `completion`, chạy SAU
            //    KHI hoạt ảnh đóng xong — đúng vai `onDismiss` cũ.
            //  · Bẫy "Quét thêm set true trong cùng nhịp lật false bị SwiftUI gộp thành KHÔNG
            //    ĐỔI" cũng không còn: `afterScanCoverClosed()` chạy từ một lịch hẹn (nhịp runloop
            //    khác hẳn), nên cú set true là một thay đổi mới, onChange bắn lại bình thường và
            //    cover được bật lại.
            .onChange(of: isMeshScanning) { _, presenting in
                if presenting {
                    ScanCover.show(
                        MeshScanFlowView(
                            quality: MeshQuality.storageDefault,
                            onOrderNow: { record in pendingOrderRecord = record },
                            onScanMore: { pendingScanMore = true },
                            dismiss: { isMeshScanning = false }
                        ) { result, saveProgress in
                            do {
                                let saved = try await store.saveMeshScan(
                                    videoURL: result.videoURL, meshURL: result.meshURL,
                                    trackURL: result.trackURL,
                                    texshotsURL: result.texshotsDir,
                                    previewURL: result.previewURL,
                                    name: result.name, projectId: pendingProjectId,
                                    quality: result.quality, geometryOnly: result.geometryOnly,
                                    // Thanh % màn "Đang dựng mô hình 3D…" — chuyển thẳng, ✗ nuốt.
                                    progress: saveProgress
                                )
                                // Nhà rất lớn chạm trần: cover đóng xong sẽ mời quét phần còn lại.
                                if result.hitCap { meshCapFollowUp = true }
                                return saved
                            } catch {
                                // Không hiện alert khi cover còn mở — sẽ bị nuốt lúc dismiss.
                                pendingSaveError = error.localizedDescription
                                return nil
                            }
                        }
                        // ⚠ GIỮ, dù từ 2.13 nó không còn BẮT BUỘC: lớp phủ nằm trong cây view của
                        // `CedarScanApp` nên `store` đã tự chảy tới (đời 2.11/2.12 present bằng
                        // UIKit thì rời cây, thiếu dòng này là `EnvironmentObject.error()` ngay
                        // khi cover mở). Giữ lại vì nó bơm ĐÚNG cái `store` mà màn này đang cầm —
                        // một dòng bảo hiểm rẻ cho lượt ai đó dời chỗ gắn lớp phủ.
                        .environmentObject(store)
                    )
                } else {
                    ScanCover.hide {
                        afterScanCoverClosed()
                    }
                }
            }
            .alert(
                L.t("Part of the home is missing", "Còn một phần nhà chưa vào bản quét"),
                isPresented: $showScanNextPart
            ) {
                Button(L.t("Scan the rest now", "Quét phần còn lại ngay")) {
                    pendingOrderRecord = nil // đổi ý: quét tiếp đã, đặt hàng sau
                    isMeshScanning = true
                }
                Button(L.t("Scan later", "Quét sau"), role: .cancel) {
                    goToPendingOrder()
                }
            } message: {
                Text(L.t(
                    "The 3D model hit its size limit before you finished — the saved part is safe. Scan the remaining area as another scan (name them \"Part 1\", \"Part 2\"…) and they can be merged later.",
                    "Mô hình 3D chạm giới hạn trước khi quét xong — phần đã lưu vẫn an toàn. Hãy quét khu còn lại thành một bản quét khác (đặt tên \"Part 1\", \"Part 2\"…) để ghép lại sau."
                ))
            }
            // Tab SCAN (RootView) yêu cầu mở màn quét mới — thay cho nút "Quét không gian mới" cũ ở
            // đáy Home. Máy quét (cover qua `ScanCover` + các cờ pending) vẫn nằm nguyên trong
            // HomeView.
            .onChange(of: scanRequest) { _, _ in
                beginNewScan()
            }
            .alert(L.t("LiDAR required", "Cần cảm biến LiDAR"), isPresented: $showScanUnsupported) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(L.t(
                    "CedarScan needs an iPhone Pro (12 Pro or newer) with a LiDAR sensor.",
                    "CedarScan cần iPhone bản Pro (12 Pro trở lên) có cảm biến LiDAR."
                ))
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
            // Giỏ rác trên dòng dự án (mục 6). Câu chữ + hành động PHẢI y hệt menu "…" của
            // `ProjectView` — chủ app chốt hai lối vào làm đúng một việc; xem `DeleteProjectPrompt`.
            //
            // 🔴 `.alert(_:isPresented:presenting:actions:message:)` — KHÔNG có overload
            // `alert(item:)` hay `confirmationDialog(item:)` trong SwiftUI, đó là API tưởng-tượng
            // đã suýt tốn một vòng CI. Dữ liệu đi qua `presenting:` nên hai nhánh nội dung luôn
            // cầm đúng dự án đã chốt lúc bấm, kể cả khi danh sách đổi ngay sau đó.
            .alert(
                DeleteProjectPrompt.title,
                isPresented: deleteProjectBinding,
                presenting: projectToDelete
            ) { project in
                Button(
                    DeleteProjectPrompt.confirmLabel(scanCount: store.scans(in: project).count),
                    role: .destructive
                ) {
                    store.deleteProjectAndScans(project)
                    projectToDelete = nil
                }
                Button(L.t("Cancel", "Hủy"), role: .cancel) { projectToDelete = nil }
            } message: { project in
                Text(DeleteProjectPrompt.message(scanCount: store.scans(in: project).count))
            }
            // Chạm một dòng bản quét: chỉ XEM lại, không mời đặt hàng.
            // 🔴 `store`/`account` TRUYỀN TAY xuống, ✗ để màn đích tự tra environment. Ba closure
            // này chạy trong nhịp ĐẨY MÀN — đúng nhịp mà `UIKitBarItemHost` đo bar item và cầu
            // environment chưa nối. Cả hai thứ truyền vào đây đều là `@ObservedObject` của
            // HomeView, tức tham chiếu thường, không có gì để trap. Xem `ProjectView.store`.
            .navigationDestination(for: ScanRecord.self) { record in
                ScanDetailView(record: record, autoOpenOrder: false, store: store, account: account)
            }
            // Bấm "Đặt hàng ngay" ở màn preview: vào thẳng BƯỚC ĐẶT HÀNG (mục 3b, chủ app chốt
            // 10/08 "Form trước"). Hai destination cùng dựng `ScanDetailView`, khác nhau đúng
            // một cờ — xem `ScanOrderIntent` để biết vì sao phải là hai KIỂU chứ không phải một
            // cờ dùng chung, và `ScanDetailView.autoOpenOrder` để biết cờ đó làm gì.
            // 🔴 `ProjectView` KHÔNG khai destination nào: nó nằm trong CHÍNH stack này (nhận
            // `$path`) nên cả hai đường đẩy của nó đều rơi vào hai closure ở đây.
            .navigationDestination(for: ScanOrderIntent.self) { intent in
                ScanDetailView(record: intent.record, autoOpenOrder: true, store: store, account: account)
            }
            .navigationDestination(for: ScanProject.self) { project in
                // Truyền `path` xuống: ProjectView nằm TRONG stack này (nó không có
                // NavigationStack riêng) nên muốn đẩy trang bản quét bằng code thì phải dùng
                // chính đường dẫn ở đây.
                // `projectName` truyền từ ĐÂY để tiêu đề của màn được đẩy chỉ đọc dữ liệu
                // THƯỜNG (`let`/`@State`), không tra `store`.
                // ⚠ GIA CỐ + vá lỗi tiêu đề RỖNG, ✗ phải bản vá của vụ văng — đo 11/08 cho thấy
                // đường văng KHÔNG chạm tiêu đề. Bản vá thật là `store`/`account` truyền tay ngay
                // dưới. Khối đầy đủ ở khai báo `ProjectView.projectName` và `ProjectView.store`.
                ProjectView(
                    store: store,
                    account: account,
                    projectId: project.id,
                    projectName: project.name,
                    path: $path
                )
            }
        }
    }

    /// 🔴 MỌI việc hậu-quét (alert lỗi lưu, mở lại phiên quét, alert chạm trần, đẩy sang trang
    /// đặt hàng) nằm Ở ĐÂY — chạy từ `completion` của `ScanCover.hide`, tức SAU KHI cover đã đóng
    /// HẲN. Đây chính là thân `onDismiss` cũ của `.fullScreenCover` (06/08), chuyển nguyên vẹn qua
    /// khuôn 2.11 rồi 2.13; luật cũ giữ nguyên: chạy mấy việc này NGAY LÚC binding lật false (giữa
    /// hoạt ảnh đóng) là văng app — chủ app đã trả giá 06/08.
    /// Thứ tự ưu tiên GIỮ NGUYÊN: lỗi lưu > quét thêm > chạm trần > đặt hàng.
    /// Nhánh "quét thêm" set `isMeshScanning = true` từ đây là AN TOÀN với khuôn onChange mới —
    /// completion chạy ở nhịp runloop khác hẳn cú lật false, xem chú thích tại `.onChange`.
    private func afterScanCoverClosed() {
        if let message = pendingSaveError {
            pendingSaveError = nil
            meshCapFollowUp = false
            pendingOrderRecord = nil // không mời đặt hàng một bản quét vừa lưu hụt
            pendingScanMore = false
            saveError = message
        } else if pendingScanMore {
            pendingScanMore = false
            // Dọn các ý định khác để chúng không nổ chồng lên phiên quét mới.
            meshCapFollowUp = false
            pendingOrderRecord = nil
            isMeshScanning = true
        } else if meshCapFollowUp {
            // Mô hình chạm trần = bản quét THIẾU dữ liệu. Lời mời quét bù phải đi TRƯỚC việc đưa
            // sang trang đặt hàng, kể cả khi khách đã bấm "Đặt hàng ngay": đặt một bản thiếu
            // phòng là đơn phải làm lại. Hai nút của alert tự quyết định số phận
            // `pendingOrderRecord`.
            meshCapFollowUp = false
            showScanNextPart = true
        } else {
            goToPendingOrder()
        }
    }

    /// Đưa khách tới BƯỚC ĐẶT HÀNG của bản quét vừa lưu, nếu họ đã bấm "Đặt hàng ngay" ở màn
    /// preview. CHỈ gọi sau khi cover quét đã đóng hẳn.
    ///
    /// Đích vẫn là `ScanDetailView`, nhưng đẩy `ScanOrderIntent` chứ ✗ `ScanRecord` trần: màn đó
    /// tự mở form đặt hàng trong `.task` của nó (mục 3b — chủ app chốt 10/08 **"Form trước"**,
    /// tức thấy giá trước, chưa gửi byte nào).
    /// 🔴 ✗ mở form TỪ ĐÂY. Mọi cửa kiểm trước khi đặt (đăng nhập, xác minh email) nằm trong
    /// `ScanDetailView`, và trình bày một sheet trong CHÍNH nhịp đẩy màn là cấu trúc đã làm văng
    /// app một lần (`48dc791`) — việc mở phải xảy ra ở `.task` của màn đích, sau khi nó appear.
    private func goToPendingOrder() {
        guard let record = pendingOrderRecord else { return }
        pendingOrderRecord = nil
        path.append(ScanOrderIntent(record: record))
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

    private var deleteProjectBinding: Binding<Bool> {
        Binding(
            get: { projectToDelete != nil },
            set: { if !$0 { projectToDelete = nil } }
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
                 // Hết nhắc "tạo Dự án": nút folder đã gỡ, và bản quét nào cũng tự vào một dự án
                 // ngay ở màn địa chỉ. Chỉ đường tới một nút không còn tồn tại là ngõ cụt.
                 //
                 // ⚠ CÂU NÀY TẢ NÚT THEO NHÃN "Scan" TRÊN NÚT (chủ app trả lại nhãn 2026-07-28,
                 // xem `CedarTabBar.scanItem`). Ai đổi nhãn/thiết kế nút thì sửa cả câu này —
                 // đời trước nút không có chữ, câu cũ phải tả "nút tròn" theo hình dạng.
                 ? L.t(
                    "Tap the Scan button in the middle of the bottom bar to scan your first space. Every scan is filed under the home address you enter.",
                    "Bấm nút Scan ở giữa thanh dưới để quét không gian đầu tiên. Mỗi bản quét sẽ tự vào dự án theo địa chỉ bạn nhập."
                 )
                 : L.t(
                    "CedarScan measures with the LiDAR sensor, which this iPhone does not have. You need an iPhone Pro (12 Pro or newer).",
                    "CedarScan đo bằng cảm biến LiDAR mà iPhone này không có. Bạn cần iPhone bản Pro (12 Pro trở lên)."
                 ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Dự án khớp chữ đang tìm. Ô rỗng → trả về tất cả (`TextMatch.contains` tự lo).
    ///
    /// 🔴 KHỚP CẢ THEO TÊN BẢN QUÉT BÊN TRONG. Ô này ghi "Tìm dự án, bản quét", mà bản quét thì
    /// gần như luôn nằm TRONG một dự án (từ khi màn địa chỉ bắt buộc, `looseScans` chỉ còn là dữ
    /// liệu đời cũ). Chỉ khớp tên dự án nghĩa là nửa lời hứa của ô tìm kiếm không bao giờ đúng —
    /// tệ hơn "không ra kết quả": app in hẳn câu "Không có dự án hay bản quét nào khớp", tức
    /// KHẲNG ĐỊNH SAI rằng bản quét đó không tồn tại.
    ///
    /// Dự án khớp thì hiện NGUYÊN dự án (không lọc bớt tầng bên trong): mở ra vẫn thấy đủ các
    /// tầng. Lọc cả bên trong sẽ đẻ ra dự án nửa vời — thiếu tầng mà không có dấu hiệu gì.
    private var visibleProjects: [ScanProject] {
        store.projects.filter { project in
            TextMatch.contains(project.name, searchText)
                || store.scans(in: project).contains { TextMatch.contains($0.name, searchText) }
        }
    }

    /// Bản quét chưa vào dự án nào, khớp chữ đang tìm.
    private var visibleLooseScans: [ScanRecord] {
        store.looseScans.filter { TextMatch.contains($0.name, searchText) }
    }

    private var mainList: some View {
        List {
            // 🔴 BỘ ĐO TẠM, GỠ CÙNG `SafeAreaHarness.swift`. Không truyền launch argument
            // `-safeAreaHarness` thì `isEnabled` = false và nhánh này không tồn tại — app của
            // khách không đổi gì. Lý do nó phải nằm ĐÚNG ở đây (trong cây gốc thật) ghi ở
            // `SafeAreaHarness`.
            if SafeAreaHarness.isEnabled {
                SafeAreaHarnessPanel()
            }
            // Tìm không ra thì PHẢI nói ra. Không có dòng này, danh sách rỗng trơn trông y hệt
            // "máy chưa có bản quét nào" — người dùng tưởng dữ liệu bay mất.
            if !searchText.isEmpty && visibleProjects.isEmpty && visibleLooseScans.isEmpty {
                Text(L.t(
                    "No homes or scans match \"\(searchText)\".",
                    "Không có dự án hay bản quét nào khớp \"\(searchText)\"."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            if !visibleProjects.isEmpty {
                Section(L.t("Properties", "Dự án (căn nhà)")) {
                    ForEach(visibleProjects) { project in
                        projectRow(project)
                    }
                }
            }
            if !visibleLooseScans.isEmpty {
                Section(store.projects.isEmpty
                        ? L.t("Scans", "Bản quét")
                        : L.t("Not in a property", "Chưa vào dự án")) {
                    ForEach(visibleLooseScans) { record in
                        ScanRow(
                            store: store,
                            record: record,
                            onRename: {
                                renameText = record.name
                                recordToRename = record
                            }
                        )
                    }
                }
            }
        }
        // `.searchable` KHÔNG nằm ở đây — nó đã được chuyển lên `body`, cùng cấp với
        // `.navigationTitle`. Xem chú thích 🔴 ở đó trước khi định đưa nó về lại.
    }

    /// Một dòng dự án. **KHÔNG còn là `NavigationLink` — chính đó là bản vá của mục 6.**
    ///
    /// 🔴 Mũi tên ">" cuối dòng KHÔNG PHẢI của app: `grep -rn chevron Sources/` ra 0 kết quả. Nó
    /// là disclosure indicator UIKit TỰ vẽ cho mọi `NavigationLink` nằm thẳng trong một `List`, và
    /// không có modifier nào tắt được. Nên cách bỏ nó là **thôi làm `NavigationLink`**, ✗ đi tìm
    /// cách ẩn nó.
    /// ⚠ Đẩy màn bằng `path.append(project)` là **CÙNG MỘT CƠ CHẾ**, không phải một cách khác:
    /// `NavigationLink(value:)` trong một `NavigationStack(path:)` cũng chỉ nối giá trị vào chính
    /// `path` này. ✗ đọc mục 3a (nút bị đĩa Scan đè) thành "đẩy bằng code là hỏng bố cục" — ở đó
    /// thủ phạm là THỜI ĐIỂM đẩy (`onDismiss` của cover quét, lúc cover `.ignoresSafeArea()` đang
    /// tháo), không phải API.
    ///
    /// Tách thành HÀM có `let` cục bộ + `return` tường minh — khuôn bắt buộc của repo cho dòng
    /// list nhiều tầng, CI từng chết vì "Swift type-check timeout" (xem `OrdersView.filterChip`,
    /// `ScanAddressView.projectRow`).
    private func projectRow(_ project: ScanProject) -> some View {
        let count = store.scans(in: project).count
        return HStack(spacing: 10) {
            Button {
                path.append(project)
            } label: {
                HStack(spacing: 10) {
                    // `.tint` (màu nhấn của app) chứ KHÔNG phải `.blue` cứng: từ 2026-07-23 màu
                    // nhấn là cobalt, để `.blue` hệ thống ở đây là một icon xanh NHẠT nằm ngay
                    // cạnh thanh tab cobalt — trông như lỗi render. Cùng lý do cho nhãn "Đã đặt"
                    // ở `ScanRow`.
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                            .font(.headline)
                        Text(L.t("\(count) scan(s)", "\(count) bản quét"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // Nuốt hết chỗ trống giữa chữ và giỏ rác, và `contentShape` bên dưới biến nó
                    // thành vùng chạm — không thì chạm vào khoảng trắng giữa dòng là rơi tọt.
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            // 🔴 PHẢI KHAI KIỂU NÚT TƯỜNG MINH CHO CẢ HAI NÚT, VÀ PHẢI LÀ CÙNG MỘT KIỂU.
            // Kiểu MẶC ĐỊNH của một `Button` nằm trong `List` biến TOÀN BỘ DÒNG thành vùng chạm
            // của nó — hai nút mặc định trong một dòng nghĩa là chạm chỗ nào cũng nổ CẢ HAI (vừa
            // mở dự án vừa hiện hộp xoá). `.plain` tắt hành vi đó: mỗi nút chỉ ăn vùng của chính
            // nó. Chọn `.plain` chứ ✗ `.borderless` cho cả hai vì `.plain` KHÔNG nhuộm nhãn theo
            // accent — dòng này cần đúng ba màu riêng (`.tint` cho thư mục, primary/secondary cho
            // chữ, đỏ cho giỏ rác), một kiểu có nhuộm là thêm một tầng phải cãi nhau.
            // ⚠ Giá phải trả, chấp nhận: không còn dải xám nhấn-cả-dòng như `NavigationLink`.
            // Khách vẫn thấy phản hồi ngay vì màn được đẩy tức thì.
            .buttonStyle(.plain)

            Button {
                projectToDelete = project
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
                    // Ô chạm 44pt (mức tối thiểu của Apple) — icon thùng rác chỉ ~17pt, để trần
                    // thì phải chạm rất chính xác, mà ngay bên trái nó là nút MỞ dự án: chạm
                    // trượt ở đây không phải "bấm hụt" mà là "đi nhầm màn".
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain) // cùng lý do với nút trên — xem khối 🔴 ở đó
            .accessibilityLabel(L.t("Delete property", "Xóa dự án"))
        }
        .padding(.vertical, 2)
    }

    // KHÔNG lọc bản quét đã đặt ra khỏi danh sách này. Từng thử và đó là lỗi CHẶN: `ScanRow` là
    // NavigationLink DUY NHẤT tới ScanDetailView, và `store.delete` chỉ được gọi từ swipe của
    // chính nó — ẩn dòng đi là bản quét mồ côi hoàn toàn, không mở/chia sẻ/xoá được, file 40-200MB
    // kẹt vĩnh viễn. Tab Đơn hàng KHÔNG thay thế được: nó lấy đơn từ server, cần mạng + đăng nhập,
    // và không trỏ về ScanRecord nào trên máy.
    // 🔴 CÁCH LÀM GỌN MÁY ĐÃ ĐỔI HẲN Ở BẢN 1.8. Đời trước (chốt 2026-07-19): giữ nguyên hiển thị
    // cho tới khi đơn ĐÃ GIAO rồi TỰ XOÁ hẳn file sau 14 ngày. Chủ app TẮT việc đó 10/08 —
    // *"Có nút giỏ rác nên để khách chủ động xóa. Nên tắt."* (cờ `RootView.autoPurgeAfterDelivery`).
    // Nay việc dọn là do KHÁCH BẤM: giỏ rác trên dòng dự án ở đây, hoặc menu "…" trong
    // `ProjectView` — cả hai gọi `ScanStore.deleteProjectAndScans`. Vuốt xoá từng bản quét vẫn còn
    // (`ScanRow.swipeActions`) và vẫn là lối duy nhất xoá MỘT bản quét lẻ.
    // ⇒ Từ 1.8 KHÔNG còn thứ gì tự xoá dữ liệu khách theo đồng hồ. Ai định thêm lại thì đọc
    // §purgeDelivered + §MULTI-ACCOUNT trong handoff trước.

    /// RESET Ở LỐI VÀO, không chỉ ở lối ra — cùng giáo lý với `startAfterGuide` ở trên.
    ///
    /// Cả hai cờ này đều được "tiêu thụ" ở lối ra (onDismiss của sheet, onChange của cover). Nếu
    /// có ĐÚNG MỘT lần lối ra không chạy — alert bị hệ thống tháo, view đổi identity — thì cờ kẹt
    /// lại và lần quét SAU dùng nhầm giá trị cũ:
    ///   • `pendingScanStart` kẹt true → bấm "Hủy" ở màn địa chỉ vẫn mở phiên quét, và nó chạy
    ///     với `pendingProjectId` của lần trước → SAI ĐỊA CHỈ trên đơn gửi đội vẽ, không dấu hiệu.
    ///   • `pendingOrderRecord` kẹt → bấm "Để sau" ở bản quét MỚI lại đẩy sang trang bản quét CŨ.
    /// Đặt lại ở đây biến cả hai thành bất khả thi về cấu trúc thay vì phải tin lối ra luôn chạy.
    private func startScanning() {
        pendingScanStart = false
        pendingOrderRecord = nil
        pendingScanMore = false
        showScanSetup = true
    }

    /// Mở màn quét mới — gọi từ `.onChange(of: scanRequest)` khi khách bấm tab SCAN. Giữ NGUYÊN
    /// logic của nút "Quét không gian mới" cũ: lần đầu mở guide (guide tự gọi quét ở onDismiss),
    /// các lần sau vào thẳng màn địa chỉ. Máy không LiDAR thì alert giải thích thay vì im lặng.
    private func beginNewScan() {
        guard isSupported else {
            showScanUnsupported = true
            return
        }
        if !UserDefaults.standard.bool(forKey: ScanGuideView.seenKey) {
            startAfterGuide = false // xem mục "reset ở LỐI VÀO" ở sheet guide bên trên
            showGuide = true
        } else {
            startScanning()
        }
    }
}

/// Một dòng bản quét (dùng chung ở danh sách chính và trang dự án):
/// bấm mở chi tiết, vuốt xoá/đổi tên, nhấn giữ để chuyển vào dự án.
struct ScanRow: View {
    /// 🔴 TRUYỀN VÀO, ✗ `@EnvironmentObject` — xem khối 🔴🔴 ở `ProjectView.store`.
    /// Dòng này được `ProjectView` (MÀN PUSH) dựng bên trong `List`/`ForEach`, tức nó nằm trên
    /// đúng cây view mà bar-item host có thể kéo chạy khi environment chưa nối. Rẻ hơn nhiều so
    /// với việc phải chứng minh "ForEach trong List là lười nên không sao" — mà chứng minh kiểu
    /// đó chính là thứ đã sai ba lần ở vụ này.
    @ObservedObject var store: ScanStore
    let record: ScanRecord
    let onRename: () -> Void

    var body: some View {
        NavigationLink(value: record) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(record.name)
                        .font(.headline)
                    // Nhãn CHỮ chứ không chỉ icon: mở dự án ra phải đọc được NGAY tầng nào đã đặt
                    // rồi, để biết căn nhà còn thiếu tầng nào mà quét thêm. Một icon nhỏ màu xanh
                    // không nói được điều đó.
                    if record.cloudOrderNumber != nil {
                        Label(L.t("Ordered", "Đã đặt"), systemImage: "shippingbox.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    } else if record.cloudScanId != nil {
                        Image(systemName: "checkmark.icloud.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                Text(subtitle)
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
                onRename()
            } label: {
                Label(L.t("Rename", "Đổi tên"), systemImage: "pencil")
            }
        }
        .contextMenu {
            if !store.projects.isEmpty {
                Menu {
                    ForEach(store.projects) { project in
                        Button(project.name) {
                            store.moveScan(record, to: project)
                        }
                    }
                } label: {
                    Label(L.t("Move to property", "Chuyển vào dự án"), systemImage: "folder")
                }
            }
            if record.projectId != nil {
                Button {
                    store.moveScan(record, to: nil)
                } label: {
                    Label(L.t("Remove from property", "Đưa ra khỏi dự án"), systemImage: "folder.badge.minus")
                }
            }
            Button {
                onRename()
            } label: {
                Label(L.t("Rename", "Đổi tên"), systemImage: "pencil")
            }
        }
    }

    private var subtitle: String {
        var parts = [
            typePart,
            record.createdAt.formatted(date: .abbreviated, time: .shortened),
        ]
        if let area = record.areaSqm, area > 0 {
            parts.insert(String(format: "%.0f m²", area), at: 1)
        }
        return parts.joined(separator: " · ")
    }

    /// Bản quét mesh không có `roomCount` ý nghĩa (luôn 0) — hiện LOẠI thay vì "0 phòng".
    /// (Nhãn mức nét đã bỏ 2026-07-31 cùng picker: chỉ còn MỘT mức nên nó chỉ là chữ thừa.)
    ///
    /// 🔴 Hằng số, ✗ còn rẽ nhánh theo `captureType` — trường đó xoá 11/08 cùng RoomPlan. Hai
    /// nhánh cũ ("Video khảo sát" và "N phòng" của RoomPlan) không còn bản quét nào rơi vào:
    /// đường TẠO của chúng chết từ 2026-07-19/20. Bản quét CŨ trên máy nay cũng hiện "Mesh 3D" —
    /// hơi sai với chúng, nhưng chủ app là người duy nhất còn giữ và đã chốt bóc sạch RoomPlan.
    private var typePart: String {
        L.t("3D mesh", "Mesh 3D")
    }
}
