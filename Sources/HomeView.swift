import ARKit
import SwiftUI

struct HomeView: View {
    /// Tín hiệu từ tab SCAN (RootView): mỗi lần TĂNG = một yêu cầu mở màn quét mới. Xem `.onChange`.
    let scanRequest: Int
    @EnvironmentObject private var store: ScanStore
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
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
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
            .fullScreenCover(
                isPresented: $isMeshScanning,
                // 🔴 MỌI việc hậu-quét (alert lỗi lưu, mở lại phiên quét, alert chạm trần, đẩy
                // sang trang đặt hàng) phải nằm Ở ĐÂY — onDismiss chạy khi cover đã tháo HẲN.
                // Đời trước chỉ có nhánh "Quét thêm" ở đây, ba nhánh kia nằm trong
                // `.onChange(of: isMeshScanning)`: onChange nổ NGAY lúc binding lật false, tức
                // `path.append`/alert rơi vào GIỮA hoạt ảnh đóng cover — push một màn trong khi
                // UIKit đang tháo dở màn quét (kèm ARSCNView đang giải phóng). Hậu quả thật:
                // "Đặt hàng ngay" ở màn preview VĂNG APP (chủ app báo 06/08). Cùng họ bẫy #9
                // và cùng luật với "present từ onDismiss" của sheet guide/địa chỉ ngay trên.
                // Riêng lý do "Quét thêm" không được đặt trong onChange còn thêm một tầng: set
                // lại true trong cùng nhịp binding lật false thì SwiftUI gộp false→true thành
                // KHÔNG ĐỔI — cover không bao giờ được tháo và dựng lại.
                // Thứ tự ưu tiên GIỮ NGUYÊN của bản cũ: lỗi lưu > quét thêm > chạm trần > đặt hàng.
                onDismiss: {
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
                        // Mô hình chạm trần = bản quét THIẾU dữ liệu. Lời mời quét bù phải đi
                        // TRƯỚC việc đưa sang trang đặt hàng, kể cả khi khách đã bấm "Đặt hàng
                        // ngay": đặt một bản thiếu phòng là đơn phải làm lại. Hai nút của alert
                        // tự quyết định số phận `pendingOrderRecord`.
                        meshCapFollowUp = false
                        showScanNextPart = true
                    } else {
                        goToPendingOrder()
                    }
                }
            ) {
                MeshScanFlowView(
                    quality: MeshQuality.storageDefault,
                    onOrderNow: { record in pendingOrderRecord = record },
                    onScanMore: { pendingScanMore = true }
                ) { result in
                    do {
                        let saved = try await store.saveMeshScan(
                            videoURL: result.videoURL, meshURL: result.meshURL,
                            trackURL: result.trackURL,
                            texshotsURL: result.texshotsDir,
                            name: result.name, projectId: pendingProjectId,
                            quality: result.quality, geometryOnly: result.geometryOnly
                        )
                        // Nhà rất lớn chạm trần: sau khi cover đóng sẽ mời quét phần còn lại.
                        if result.hitCap { meshCapFollowUp = true }
                        return saved
                    } catch {
                        // Không hiện alert khi cover còn mở — sẽ bị nuốt lúc dismiss.
                        pendingSaveError = error.localizedDescription
                        return nil
                    }
                }
            }
            // (Khối `.onChange(of: isMeshScanning)` cũ đã GỠ 06/08 — mọi việc hậu-quét nay nằm
            // trong `onDismiss` của cover ở trên, xem chú thích 🔴 tại đó. ✗ thêm lại onChange
            // cho isMeshScanning: nó nổ giữa lúc cover đang đóng, push/alert ở đó là văng app.)
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
            // đáy Home. Máy quét (fullScreenCover + các cờ pending) vẫn nằm nguyên trong HomeView.
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
            .navigationDestination(for: ScanRecord.self) { record in
                ScanDetailView(record: record)
            }
            .navigationDestination(for: ScanProject.self) { project in
                // Truyền `path` xuống: ProjectView nằm TRONG stack này (nó không có
                // NavigationStack riêng) nên muốn đẩy trang bản quét bằng code thì phải dùng
                // chính đường dẫn ở đây.
                ProjectView(projectId: project.id, path: $path)
            }
        }
    }

    /// Đưa khách tới trang bản quét vừa lưu (nơi có nút đặt hàng) nếu họ đã bấm "Đặt hàng ngay"
    /// ở màn preview. CHỈ gọi sau khi cover quét đã đóng hẳn.
    ///
    /// Đích là `ScanDetailView` chứ không phải mở thẳng form đặt hàng: mọi cửa kiểm trước khi đặt
    /// (đăng nhập, xác minh email, cảnh báo chất lượng thấp) đều nằm ở đó, và bước đầu tiên của
    /// việc đặt là TẢI LÊN 40–200MB — thứ không được tự chạy khi khách chưa bấm nút nào trên
    /// mạng di động của họ.
    private func goToPendingOrder() {
        guard let record = pendingOrderRecord else { return }
        pendingOrderRecord = nil
        path.append(record)
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
                        NavigationLink(value: project) {
                            HStack(spacing: 10) {
                                // `.tint` (màu nhấn của app) chứ KHÔNG phải `.blue` cứng: từ
                                // 2026-07-23 màu nhấn là cobalt, để `.blue` hệ thống ở đây là
                                // một icon xanh NHẠT nằm ngay cạnh thanh tab cobalt — trông như
                                // lỗi render. Cùng lý do cho nhãn "Đã đặt" ở `ScanRow`.
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.name)
                                        .font(.headline)
                                    Text(L.t(
                                        "\(store.scans(in: project).count) scan(s)",
                                        "\(store.scans(in: project).count) bản quét"
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            if !visibleLooseScans.isEmpty {
                Section(store.projects.isEmpty
                        ? L.t("Scans", "Bản quét")
                        : L.t("Not in a property", "Chưa vào dự án")) {
                    ForEach(visibleLooseScans) { record in
                        ScanRow(
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

    // KHÔNG lọc bản quét đã đặt ra khỏi danh sách này. Từng thử và đó là lỗi CHẶN: `ScanRow` là
    // NavigationLink DUY NHẤT tới ScanDetailView, và `store.delete` chỉ được gọi từ swipe của
    // chính nó — ẩn dòng đi là bản quét mồ côi hoàn toàn, không mở/chia sẻ/xoá được, file 40-200MB
    // kẹt vĩnh viễn. Tab Đơn hàng KHÔNG thay thế được: nó lấy đơn từ server, cần mạng + đăng nhập,
    // và không trỏ về ScanRecord nào trên máy.
    // Cách làm gọn máy ĐÚNG (chủ app chốt 2026-07-19): giữ nguyên hiển thị cho tới khi đơn ĐÃ GIAO,
    // rồi TỰ XOÁ hẳn file — đơn giao được tự nó là bằng chứng dữ liệu đã an toàn trên R2.

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
    @EnvironmentObject private var store: ScanStore
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

    /// Bản mesh/video không có roomCount ý nghĩa — hiện loại thay vì "0 phòng".
    /// (Nhãn mức nét đã bỏ 2026-07-31 cùng picker: chỉ còn MỘT mức nên nó chỉ là chữ thừa.)
    private var typePart: String {
        if record.isMeshOnly {
            return L.t("3D mesh", "Mesh 3D")
        }
        if record.isVideoOnly {
            return L.t("Video walkthrough", "Video khảo sát")
        }
        return L.t("\(record.roomCount) room(s)", "\(record.roomCount) phòng")
    }
}
