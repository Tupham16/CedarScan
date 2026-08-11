import SwiftUI
import AVKit
import UniformTypeIdentifiers // UTType — suy ra MIME + giới hạn loại file cho .fileImporter
// (`import UIKit` GỠ 11/08 cùng RoomPlan: lý do duy nhất của nó là `UIImage` cho ảnh mặt bằng
// `floorplan.png`, và grep toàn file nay ra 0 ký hiệu UIKit. Cần lại thì khai lại TƯỜNG MINH,
// ✗ trông chờ SwiftUI/AVKit kéo hộ — đó là thứ chỉ lộ sau 10 phút CI.)

/// Ý ĐỊNH "Đặt hàng ngay" — một giá trị điều hướng RIÊNG, cố ý KHÔNG dùng lại `ScanRecord`.
///
/// Vì sao phải là một KIỂU khác chứ không phải một cờ dùng chung: `navigationDestination(for:)`
/// khớp theo KIỂU, và cả hai màn (HomeView, ProjectView) đẩy vào CÙNG một `NavigationPath` do
/// HomeView sở hữu. Chạm một dòng bản quét đẩy `ScanRecord`; bấm "Đặt hàng ngay" ở màn preview
/// đẩy giá trị này. Nhờ vậy màn đích biết mình được mở ĐỂ LÀM GÌ mà không cần một `@State` chia
/// sẻ giữa hai màn — loại cờ đó chính là thứ `pendingOrderRecord` phải chống bằng kỷ luật "reset
/// ở LỐI VÀO" (xem `HomeView.startScanning`), và ở đây thì không có lối vào nào để reset.
///
/// 🔴 Chỉ cần `Hashable`. `NavigationPath` của app KHÔNG được ghi xuống đĩa (không nơi nào dùng
/// `CodableRepresentation`) nên đừng thêm `Codable` "cho chắc" — thêm là buộc kiểu này vào một
/// hợp đồng dữ liệu mà nó không có.
struct ScanOrderIntent: Hashable {
    let record: ScanRecord
}

/// Thứ cần để mở trình xem 3D GỘP (`ModelViewerScreen`) — chốt lúc khách BẤM, ✗ đọc sống.
///
/// 🔴 `id = UUID()` và dùng qua `.fullScreenCover(item:)`, ✗ một cờ `Bool` + mấy `@State` đọc
/// bên trong: bẫy #7 — nội dung của `.sheet/.cover(isPresented:)` được dựng NGAY nhịp cờ lật
/// true, lúc đó `@State` set cùng nhịp CHƯA commit → lần đầu ra màn TRẮNG. Đã trả giá thật ở
/// form đặt hàng của `ProjectView`; khuôn đúng là `OrderSheetTarget` của màn đó.
///
/// `greyURL == nil` = bản quét lưu trước 1.4 (không có `mesh-preview.bin`, không dựng lại được).
/// `texturedRemote == nil` = chưa đặt hàng, hoặc máy trạm chưa bake xong.
/// Cả hai nil thì `modelRow` không hiện nút, nên màn kia không bao giờ mở với hai bàn tay trắng.
struct ModelViewerTarget: Identifiable {
    let id = UUID()
    let greyURL: URL?
    let texturedRemote: URL?
    let cloudScanId: String?
}

struct ScanDetailView: View {
    let record: ScanRecord
    /// Màn này được mở bằng nút "Đặt hàng ngay" ở màn preview (✗ bằng cách chạm một dòng danh
    /// sách) → tự mở FORM đặt hàng thay vì bắt khách bấm thêm một nút đặt hàng thứ hai.
    ///
    /// Chủ app 10/08 (phản hồi bản 1.4, mục 3): "Đặt hàng ngay" phải vào thẳng BƯỚC ĐẶT HÀNG chứ
    /// không phải vào một màn có nút đặt hàng THỨ HAI. Hỏi tiếp là muốn kiểu nào thì ông chốt
    /// nguyên văn **"Form trước"** — ✗ tải file lên trước rồi mới hiện form. Lý do đường "tải
    /// trước" bị bác: `ScanUploader` KHÔNG có API hủy, nên nó biến một cú chạm thành 40–200MB
    /// không hủy được trên 4G của khách TRƯỚC KHI họ nhìn thấy giá.
    ///
    /// 🔴 CỐ Ý KHÔNG CÓ GIÁ TRỊ MẶC ĐỊNH (bẫy #13). `= false` sẽ để một call site tương lai quên
    /// truyền mà vẫn compile xanh, và tính năng chết IM LẶNG. Hiện có đúng hai call site, cả hai
    /// trong `HomeView` (hai `navigationDestination`).
    let autoOpenOrder: Bool
    /// 🔴🔴 **TRUYỀN VÀO, ✗ `@EnvironmentObject`. BẢN VÁ VỤ VĂNG APP (11/08) — ✗ ĐỔI NGƯỢC LẠI.**
    ///
    /// Màn chị em `ProjectView` đã ĐO ĐƯỢC bằng dSYM: `UIKitBarItemHost.initializeSize()` đo bar
    /// item giữa cú push → kéo chạy `body` của màn PUSH trong ViewGraph mà cầu environment CHƯA
    /// nối → mọi `@EnvironmentObject` trong thân view là SIGTRAP. Lý lẽ đầy đủ + vì sao
    /// `@ObservedObject` không thể trap: khối 🔴🔴 ở `ProjectView.store`.
    ///
    /// ⚠ Màn NÀY chưa có `.ips` nào chỉ vào, nhưng nó đứng trên CÙNG đường đi (cùng hai
    /// `navigationDestination`, cùng `NavigationStack`) và vụ 06/08 (`48dc791`, E7FBB13A) đã văng
    /// ở ĐÚNG `UIKitBarItemHost.initializeSize()` của chính nó. Soi code ra **SÁU** cửa đọc env
    /// trên đường render đầu — liệt đủ ở khối 🔴🔴 tại `.navigationTitle` bên dưới. Vá tận gốc
    /// cắt cả sáu cùng lúc.
    ///
    /// ⚠ `.environmentObject(...)` ở `CedarScanApp` VẪN CÒN: `OrderSheet` (cuối file này),
    /// `AccountGateSheet`, `SupplementSheet`, `ModelViewerScreen` vẫn đọc `@EnvironmentObject`
    /// như cũ và AN TOÀN — chúng chỉ dựng khi khách đã bấm. ✗ đổi chúng theo.
    @ObservedObject var store: ScanStore
    /// Truyền vào cùng lý do với `store` — xem ngay trên. `account` được đọc trong `serviceCard`
    /// (`isSignedIn` / `needsVerification`), tức CÓ nằm trên đường render đầu — nó là cửa số 5.
    /// ⚠ Khác `ProjectView.account` (ở màn đó mọi chỗ đọc `account` đều trong action closure nên
    /// KHÔNG phải cửa). Đừng chép lý do qua lại giữa hai màn.
    @ObservedObject var account: AccountStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var uploader = ScanUploader()

    // (`@State private var mode` GỠ 11/08 — nó là lựa chọn của `Picker` "Mô hình 3D | Mặt bằng 2D"
    // trong `legacyTab`, màn đã bóc cùng RoomPlan.)
    /// 🔴 DỮ LIỆU THƯỜNG cho nút Share trên thanh điều hướng — CHỤP trong `.task` (nơi
    /// environment còn nguyên vẹn), closure `.toolbar` CHỈ được đọc struct này.
    ///
    /// VÌ SAO (crash log chủ app gửi 06/08, bản 1.1, iOS 26, incident E7FBB13A, 100% tái
    /// hiện trên đường "Đặt hàng ngay" ở màn preview → push màn này): UIKit dựng-và-đo bar
    /// item SỚM — `UIKitBarItemHost.initializeSize` ngay trong `willMove(toSuperview:)` —
    /// TRƯỚC khi cầu environment của SwiftUI nối tới host RIÊNG của thanh điều hướng.
    /// Closure trong `.toolbar { }` chạy trong host đó, và `DynamicBody` CÀI LẠI property
    /// wrapper theo host hiện tại (✗ dùng giá trị đã capture), nên đọc `@EnvironmentObject`
    /// (store — `shareControl` cũ đụng qua `current`/`folder`) là `EnvironmentObject.error()`
    /// → SIGTRAP. Stack: _assertionFailure ← EnvironmentObject.error ← ViewBodyAccessor ←
    /// UIKitBarItemHost.initializeSize ← willMove(toSuperview:).
    /// · ✗ chèn `.environmentObject(store)` vào trong ToolbarItem — chính biểu thức đó cũng
    ///   phải đọc wrapper trong host chưa nối, chết y hệt.
    /// · ✗ đưa computed property nào đụng store/account vào closure toolbar.
    /// · @State đọc trong host chưa nối chỉ trả giá trị hiện có (không trap) → snapshot nằm
    ///   ở @State; trước khi `.task` chạy nó rỗng → nút Share hiện trễ một nhịp, chấp nhận.
    /// 🔴 Còn ĐÚNG MỘT trường sau khi bóc RoomPlan 11/08. Bảy trường cũ (`videoOnlyURL`,
    /// `isLegacy`, `legacyUSDZ/GLB/OBJZip/PLY/PlanPNG`) phục vụ hai loại bản quét mà đường TẠO
    /// đã chết từ 2026-07-19/20 — nay đường XEM cũng bóc nốt.
    /// ✗ gộp struct này vào `[URL]` trần: cái tên nói rõ đây là DỮ LIỆU ĐÃ CHỤP cho thanh điều
    /// hướng, và đó là thứ giữ cho người sau khỏi đưa `store` trở lại closure toolbar.
    private struct ShareSnapshot {
        var meshBundle: [URL] = []
    }
    @State private var shareSnapshot = ShareSnapshot()
    /// Trình phát video, dựng MỘT LẦN trong `.task`.
    ///
    /// Trước đây là `VideoPlayer(player: AVPlayer(url: videoURL))` viết thẳng trong body → mỗi
    /// lần SwiftUI dựng lại body là một AVPlayer MỚI, tức video nhảy về giây 0. Nó âm ỉ vì hiếm
    /// khi có gì làm body chạy lại; nhưng từ 2026-07-20 "Đặt hàng ngay" đẩy khách THẲNG vào đây
    /// và việc đầu tiên họ làm là bấm đặt — `uploader.phase` bắn `.uploading(fraction:)` mỗi nhịp
    /// tiến độ, tức body dựng lại nhiều lần mỗi giây suốt lúc tải 40–200MB.
    @State private var player: AVPlayer?
    @State private var showOrderSheet = false
    /// Màn "Gửi bổ sung bản quét" — mở khi dự án của bản quét này ĐÃ có đơn.
    @State private var showSupplementSheet = false
    /// Đã tự mở form đặt hàng lần nào chưa (chỉ có nghĩa khi `autoOpenOrder`).
    ///
    /// 🔴 BẮT BUỘC. `.task` KHÔNG phải "chạy một lần" — SwiftUI huỷ nó ở `onDisappear` và chạy
    /// LẠI mỗi lần view hiện lại: đóng trình xem lưới xám/texture (cả hai là `fullScreenCover`,
    /// tức view chủ bị GỠ khỏi cây), quay về từ tab khác. Thiếu cờ này thì form đặt hàng tự bật
    /// ra lại sau mỗi lần khách đóng nó — khách không có cách nào ở lại màn bản quét.
    /// Cùng lớp lỗi với `texturedAsked` bên dưới, cùng lý do.
    @State private var didAutoOpenOrder = false
    /// Cổng đăng nhập/xác minh mở tại chỗ — xem `AccountGateSheet`.
    @State private var showAccountGate = false
    @State private var showLowQualityConfirm = false
    @State private var coloredZipExists = false
    @State private var coloredGLBExists = false
    /// Có `mesh-preview.bin` trong thư mục bản quét không (lưới xám xem trong app).
    /// Bản quét lưu TRƯỚC bản 1.4 không có file này và KHÔNG dựng lại được trên máy (hình học
    /// chỉ còn trong model-colored.zip mà app không giải nén được) → dòng "Xem mô hình 3D"
    /// đơn giản là không hiện. Cố ý: một nút bấm vào ra màn trống còn tệ hơn không có nút.
    @State private var meshPreviewExists = false
    /// 🔴 **NGUỒN TRÌNH BÀY DUY NHẤT của trình xem 3D** (xám + texture gộp làm một từ bản 2.0).
    /// Trước đó màn này chồng HAI `.fullScreenCover`, mà một view controller chỉ trình bày được
    /// MỘT thứ — tải xong texture đúng lúc cover xám đang mở là nút texture chết tới khi thoát ra
    /// vào lại. ✗ thêm cover thứ hai cho trình xem nào nữa; đưa vào `ModelViewerScreen`.
    ///
    /// `.fullScreenCover(item:)` chứ ✗ `.sheet`: trình xem 3D ăn TOÀN BỘ cử chỉ kéo để xoay
    /// mô hình, mà sheet lại dùng chính cú kéo xuống để tự đóng — khách xoay xuống một cái là
    /// màn đóng mất. Và `item:` chứ ✗ `isPresented:` (bẫy #7).
    @State private var viewerTarget: ModelViewerTarget?
    /// Bản sao zip mang TÊN BẢN QUÉT để chia sẻ ra ngoài (Floor 1.zip thay vì
    /// model-colored.zip). nil → dùng file gốc.
    @State private var meshShareURL: URL?
    /// Mô hình có texture do máy trạm bake: URL trên R2 (nil = chưa bake / chưa hỏi server).
    @State private var texturedRemote: URL?
    /// Đã hỏi server về texture lần nào chưa — `.task` chạy LẠI mỗi lần view hiện lại nên
    /// thiếu cờ này là mỗi lần đổi tab lại gọi listOrders một lượt.
    @State private var texturedAsked = false
    @StateObject private var textured = TexturedModelCache()

    /// Bản ghi mới nhất từ store (record truyền vào có thể cũ sau khi upload/đặt hàng).
    ///
    /// `?? record` là bản chụp GIÁ TRỊ lúc push (NavigationPath giữ nó, không phụ thuộc store),
    /// nên khi bản quét bị dọn mất thì màn này vẫn render dữ liệu cũ như không có chuyện gì —
    /// xem `stillExists` bên dưới.
    private var current: ScanRecord {
        store.records.first(where: { $0.id == record.id }) ?? record
    }

    /// Bản quét còn trong store không.
    ///
    /// ⚠ LÝ DO TỒN TẠI ĐÃ YẾU ĐI Ở BẢN 1.8, GUARD THÌ GIỮ NGUYÊN. Đời trước: việc dọn-sau-khi-giao
    /// (`RootView.purgeDeliveredScans`) nổ ngay dưới chân màn này khi app quay lại foreground —
    /// nay nó đã tắt (`autoPurgeAfterDelivery`). Đường xoá còn lại (khách bấm xoá dự án / vuốt xoá
    /// một dòng) đều bắt buộc khách phải đang ở MÀN KHÁC, nên hôm nay guard này gần như không có
    /// dịp nổ. Giữ vì nó là fail-safe rẻ và vì cờ dọn bật lại là một dòng: không tự đóng thì khách
    /// ngồi nhìn một bản quét mà mọi file đã biến mất — bấm gì cũng hỏng.
    private var stillExists: Bool {
        store.records.contains { $0.id == record.id }
    }

    // (`usdzURL` → `model.usdz` và `planURL` → `floorplan.png` XOÁ 11/08 cùng RoomPlan: luồng
    // mesh không sinh hai file đó bao giờ. ✗ nhầm `model.usdz` với usdz CÓ TEXTURE do máy trạm
    // bake — cái đó đi đường `TexturedModelCache`, đang dùng, không liên quan.)
    private var folder: URL { store.folderURL(for: record) }
    private var videoURL: URL { folder.appendingPathComponent("scan-video.mp4") }
    private var objURL: URL { folder.appendingPathComponent("model.obj") }
    private var plyURL: URL { folder.appendingPathComponent("colored-mesh.ply") }
    private var coloredZipURL: URL { folder.appendingPathComponent("model-colored.zip") }
    private var coloredGLBURL: URL { folder.appendingPathComponent("model-colored.glb") }
    /// Lưới xám nhẹ cho trình xem 3D trong app — xem `MeshPreviewFile`.
    /// ⚠ File này CHỈ để xem tại chỗ: nó KHÔNG vào nút Share (`meshShareBundle` liệt kê tường
    /// minh zip/obj/glb/ply + video) và KHÔNG vào `ScanUploader.fileKinds`. Đội vẽ nhận mesh
    /// đầy đủ trong zip, đưa thêm bản đã giảm đỉnh cho họ chỉ tổ gây nhầm.
    private var meshPreviewURL: URL { folder.appendingPathComponent(MeshPreviewFile.fileName) }

    var body: some View {
        VStack(spacing: 0) {
            // 🔴 MỘT LOẠI BẢN QUÉT DUY NHẤT kể từ 11/08. Trước đây ở đây rẽ ba nhánh theo
            // `record.captureType`: `videoTab` (quay video khảo sát) · `meshTab` · `legacyTab`
            // (RoomPlan: USDZ + ảnh mặt bằng). Hai nhánh ngoài đã bóc cùng RoomPlan — đường TẠO
            // của chúng chết từ 2026-07-19/20, không bản quét mới nào rơi vào được.
            // ⚠ Bản quét CŨ trên máy chủ app nay cũng đi đường này: có video thì xem được video,
            // không có `model-colored.zip`/`mesh-preview.bin` thì `meshInfoFooter` nói thẳng
            // "chưa thu được mô hình 3D". Không màn nào trắng trơn.
            meshTab
        }
        // `record.name` (dữ liệu ĐẨY VÀO, một `let`), ✗ `current.name` (đọc `store`).
        //
        // ⚠ ĐÂY LÀ GIA CỐ, ✗ PHẢI LÀ BẢN VÁ ĐÃ CHỨNG MINH. Đọc kỹ trước khi tin:
        // Bản 1.4 văng 2 lần (10/08, incident 0226F250 + 4A3E9FF6): SIGTRAP, `EnvironmentObject
        // .error()` gọi từ 4 khung CedarScan dưới `ViewBodyAccessor.updateBody`, toàn bộ nằm
        // trong `UIKitBarItemHost.initializeSize()` lúc iOS cấu hình NÚT BACK giữa cú push —
        // cùng HỌ với vụ 06/08 (`48dc791`): thân view chạy trong host chưa nối environment thì
        // đọc `@EnvironmentObject` là chết.
        // ✅ 11/08 CHIỀU — ĐÃ ĐO BẰNG dSYM. **KHÔNG PHẢI TIÊU ĐỀ.** Trên `ProjectView` (màn có
        // log) dòng chết là `store.project(with:)` trong computed property `project`, tới qua
        // `body` → `content` → closure `Group` → `scans`. Suy luận đối kháng bên trên ĐÚNG:
        // `.navigationTitle(_:)` nhận STRING nên tính trong thân view, không phải chỗ trap.
        // 🔴 "MẮT XÍCH CHƯA AI NHÌN THẤY" ĐÃ THẤY: thứ chạy trong host chưa nối environment là
        // **CẢ `body` của màn PUSH**, ✗ riêng thanh điều hướng.
        // ⇒ Đổi dòng này VÔ CAN với crash. Giữ vì lý do tự thân (bớt một lần chạm environment),
        // ✗ ghi ở đâu rằng nó chữa crash.
        // 🔴🔴 **MÀN NÀY CÓ SÁU CỬA CÙNG LOẠI TRONG `body` — ĐÃ VÁ 11/08** bằng cách đổi
        // `store`/`account` sang `@ObservedObject` truyền vào (khối 🔴🔴 ở khai báo `store`).
        // Giữ danh sách vì nó là thứ chứng minh vì sao KHÔNG được vá lẻ, và là checklist cho ai
        // định đưa `@EnvironmentObject` trở lại:
        //  1. `meshTab` → `videoArea` → `videoURL` → `folder` → `store.folderURL`  ← chắc chắn
        //     nhất: `player` chỉ được gán trong `.task` nên lượt render ĐẦU luôn rẽ vào đây;
        //  2. `meshTab` → `meshInfoFooter` → `meshFooterText` → `objURL`/`plyURL` → `folder`;
        //  3. `videoTab` → `videoArea` → `videoURL` → `folder`;
        //  4. `legacyTab` → `usdzURL` → `store.usdzURL` (và `legacyPlanTab` → `planURL`);
        //  5. `.safeAreaInset` → `serviceCard` → `current` (store) + `account` + `supplementOrderNumber`;
        //  6. `.onChange(of: stillExists)` → `store.records` (bản sao y hệt `ProjectView`).
        // ⚠ Sáu cửa này là SOI CODE, ✗ đo: chưa `.ips` nào chỉ vào màn này. Nhưng vụ 06/08 chứng
        // minh cơ chế CHẠM TỚI ĐÂY, và nó được push bởi CÙNG `navigationDestination` với
        // `ProjectView` — màn đã có log. ✗ chờ thêm log mới chịu vá.
        // 🔴 `ScanRow` (HomeView.swift) cũng đã đổi sang `store` truyền tay cùng lượt: nó do
        // `ProjectView` dựng trong `List`/`ForEach`, tức cũng nằm trên cây view của màn PUSH.
        // ⚠ Ở MÀN NÀY nó KHÔNG đổi hành vi một li nào: `current` (xem trên) đã có `?? record`,
        // nên bản quét bị dọn mất thì tiêu đề vẫn hiện đúng tên cũ, chưa bao giờ rỗng. Lỗi tiêu
        // đề RỖNG là chuyện của `ProjectView` (chỗ cũ ở đó là `project?.name ?? ""`) — ✗ chép
        // lý do đó sang đây.
        // 🔴 CÁCH BIẾT CHẮC (đã dựng sẵn ở bản 1.5): CI nay tải lên cả dSYM. Lần văng sau, đối
        // chiếu 4 imageOffset trong .ips với dSYM là ra ĐÚNG dòng — đừng đoán thêm vòng nào nữa.
        // Chi tiết + stack đầy đủ: SESSION-HANDOFF §CRASH ĐANG MỞ.
        //
        // ⚠ AN TOÀN khi đổi tên: bản quét CHỈ đổi tên được từ danh sách (`ScanRow.onRename` →
        // HomeView / ProjectView), không có lối đổi tên nào TRONG màn này, nên `record.name`
        // không thể cũ trong lúc màn đang mở. Ai thêm nút đổi tên vào đây thì phải chụp tên
        // sang một `@State` như `ProjectView.renamedTitle`, ✗ quay lại `current.name`.
        .navigationTitle(record.name)
        .navigationBarTitleDisplayMode(.inline)
        // 🔴 MÀN PUSH TỰ KHAI TRẠNG THÁI THANH TAB (mục 3a). Thanh gốc bị ẩn ở TỪNG tab trong
        // `RootView`, còn màn được PUSH thì trước dòng này không khai gì — trạng thái nó dùng là
        // thứ THỪA HƯỞNG được lúc hosting controller của nó được dựng. Khai tường minh để việc
        // chừa chỗ đáy không phụ thuộc vào THỜI ĐIỂM dựng màn.
        //
        // ⚠ ĐÂY LÀ ỨNG VIÊN, ✗ PHẢI BẢN VÁ ĐÃ CHỨNG MINH. Đọc trước khi tin:
        // Chủ app báo (bản 1.4, có ảnh chụp): vào màn này bằng nút "Đặt hàng ngay" — tức đẩy từ
        // `onDismiss` của cover quét (`HomeView.goToPendingOrder`) — thì thẻ nút đặt hàng nằm
        // THẤP HƠN ~30pt và bị đĩa Scan đè mép dưới; vào bằng cách CHẠM một dòng bản quét (từ
        // Home hay từ Dự án) thì đúng. Số học khớp với đúng MỘT chẩn đoán: vùng an toàn ĐÁY của
        // màn này bằng **0 thay vì 34pt** trên đường hỏng. Tính từ đáy MÀN HÌNH, với inset 34:
        // đáy thẻ = 34 + `reservedHeight` 94 = 128, đáy NÚT = +8 đệm dọc của thẻ = 136, mép trên
        // vòng Scan = 34 + 92 = 126 ⇒ hở 10pt (quầng sáng với tới 135, dừng ~1pt dưới nút) —
        // khớp "có khoảng hở" ông tả. Với inset 0: đáy thẻ 94, đáy nút 102, mà vòng Scan choán
        // 54…126 ⇒ 24pt cuối của nút nằm TRONG đĩa — khớp ảnh ông gửi.
        // Thoát app rồi vào lại KHÔNG chữa được ⇒ giá trị bị CHỐT MỘT LẦN lúc dựng màn, ✗ "đo
        // hụt rồi kẹt" — nên mọi cách hoãn thêm nhịp trước khi đẩy đều vô ích (đường đó ĐÃ hoãn
        // qua `onDismiss` rồi mà vẫn sai).
        //
        // 🔴 DÒNG NÀY KHÔNG GIẢI THÍCH ĐƯỢC VÌ SAO INSET THÀNH 0, nên nó có thể KHÔNG ĐỦ. Ghi
        // nó vì ba lý do: rẻ, KHÔNG THỂ HẠI (thanh gốc vốn đã ẩn ở mọi tab nên không có thanh
        // nào để hiện ra, và thanh THẤY ĐƯỢC là `CedarTabBar` gắn bằng `safeAreaInset` trên
        // TabView — modifier này không đụng tới), và handoff §CRASH ĐANG MỞ liệt đúng nó là ứng
        // viên CHƯA VÁ (bản này vá — sửa dòng đó trong handoff cùng lượt).
        // 🔴 NẾU MÁY THẬT VẪN THẤY NÚT THẤP: bước tiếp đã có sẵn thứ để phân biệt — `autoOpenOrder`
        // đúng bằng ĐƯỜNG HỎNG, nên cộng thêm vùng an toàn đáy của CỬA SỔ vào `.padding(.bottom,)`
        // ở `.safeAreaInset` bên dưới CHỈ khi cờ đó bật là hết triệu chứng. ⚠ Đó là CHE chứ ✗
        // chữa: làm thì phải ghi vào handoff và ✗ đóng mục 3a.
        // 🔴 **LỊCH SỬ 11/08:** dòng dưới bị GỠ ở 2.7 làm nghi can lỗi đè chữ → MINH OAN BẰNG ĐO
        // (2.7 không có nó vẫn lỗi) → KHAI LẠI từ 2.8, cùng lượt với `ProjectView` (hai màn PUSH
        // phải khai GIỐNG NHAU — lệch là đẻ cặp màn song sinh trôi khỏi nhau). Vá thật của lỗi đè
        // chữ là **lớp phủ `ScanCover` (2.13)**. Và nay đã HIỂU vì sao mục 3a từng "vá được" bằng
        // dòng này mà 11/08 vẫn tái phát ở đường khác: gốc là lề cả cây về 0 sau khi màn quét mở —
        // dòng này chưa bao giờ là thuốc, chỉ trùng lịch trình lành bệnh.
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // 🔴 CHỈ dữ liệu thường (ShareSnapshot) — đọc chú thích tại struct đó trước
                // khi thêm BẤT CỨ GÌ vào closure này. Đụng @EnvironmentObject ở đây là văng
                // app (đã xảy ra, crash log 06/08). ⚠ Chỗ này ĐÃ SẠCH và KHÔNG phải nguồn của
                // vụ văng 10/08 — nguồn đó chưa xác định, xem khối 🔴 ở `.navigationTitle`.
                shareButton(shareSnapshot)
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Tự chừa chỗ cho thanh tab — cùng lý do với `ProjectView`, xem
            // `CedarTabBar.reservedHeight`. Ở đây thứ bị che là NÚT ĐẶT HÀNG trong `serviceCard`,
            // tức đường tiền, nên nó còn đắt hơn ca của ProjectView.
            serviceCard
                .padding(.bottom, CedarTabBar.reservedHeight)
        }
        // (`SafeAreaRepair.nudge()` ở đây ĐÃ XOÁ cùng cả file `SafeAreaRepair.swift` ở 2.13 — đo
        // được là TRƠ, xem `ScanCover.swift`. Hai màn PUSH vẫn phải khai GIỐNG NHAU: `ProjectView`
        // cũng không còn dòng này.)
        // Bản quét biến mất trong lúc màn này đang mở → thoát ra, đừng để khách ngồi trước một
        // bản quét mà mọi file đã biến mất. (Nguồn gây ra đã đổi ở 1.8 — xem `stillExists`.)
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
            // TỰ MỞ FORM ĐẶT HÀNG (mục 3b) — GIỮ Ở DÒNG ĐẦU.
            // ⚠ Lý do CŨ ("vì hai nhánh `return` bên dưới thoát sớm theo LOẠI bản quét") đã hết
            // hiệu lực 11/08: bóc RoomPlan xong thì `.task` chạy tuột một mạch, không còn
            // `return` nào. Nhưng vị trí này vẫn ĐÚNG và ✗ nên dời xuống — `loadTexturedURL()` ở
            // cuối có gọi mạng (`listOrders`), để lời mời đặt hàng sau nó là bắt khách chờ mạng
            // xong mới thấy form.
            autoOpenOrderIfNeeded()
            // KHÔNG tự phát — màn này là nơi xem lại theo ý khách, khác màn preview sau khi quét.
            // (Điều kiện `current.isMeshOnly || current.isVideoOnly` bỏ 11/08 cùng RoomPlan: mọi
            // bản quét nay đều có khu video, nên chỉ còn gác "file có tồn tại không".)
            if player == nil, FileManager.default.fileExists(atPath: videoURL.path) {
                player = AVPlayer(url: videoURL)
            }
            coloredGLBExists = FileManager.default.fileExists(atPath: coloredGLBURL.path)
            coloredZipExists = FileManager.default.fileExists(atPath: coloredZipURL.path)
            meshPreviewExists = FileManager.default.fileExists(atPath: meshPreviewURL.path)
            if coloredZipExists, meshShareURL == nil {
                meshShareURL = prepareNamedZip()
            }
            // Chụp SAU khi các cờ file + meshShareURL đã chốt — snapshot đọc chúng.
            shareSnapshot = makeShareSnapshot()
            await loadTexturedURL()
        }
        // 🔴 **CỬA TRÌNH BÀY DUY NHẤT CỦA TRÌNH XEM 3D (bản 2.0). ✗ THÊM CÁI THỨ HAI.**
        // Đời trước màn này chồng HAI `.fullScreenCover` — một cho lưới xám, một cho texture —
        // và §STATE đã ghi đó là lỗi CHƯA VÁ: một view controller chỉ trình bày ĐƯỢC MỘT thứ, mà
        // hai đường đó với tới nhau ĐƯỢC (dòng xám cố ý nằm trên dòng texture để khách xem lưới
        // trong lúc chờ tải 29–75MB). Tải xong đúng lúc cover xám đang mở ⇒ lượt trình bày thứ
        // hai bị bỏ, trong khi `readyURL` vẫn khác nil và vẫn cùng `id` (`URL.id` =
        // absoluteString) ⇒ **nút texture chết tới khi thoát ra vào lại màn.** Sổ tay đã ghi sẵn
        // cách vá đúng là "gộp về MỘT nguồn trình bày" — nay là `viewerTarget`, và việc chủ app
        // xin gộp hai nút làm một (công tắc Texture) đưa luôn tới đúng bản vá đó.
        //
        // `item:` chứ ✗ `isPresented:` (bẫy #7), `fullScreenCover` chứ ✗ `sheet` (trình xem 3D
        // ăn TOÀN BỘ cú kéo để xoay mô hình, mà sheet dùng chính cú kéo xuống để tự đóng).
        //
        // ⚠ HAI HỆ QUẢ CỦA cover (✗ sheet), cả hai đã cân nhắc, ✗ "sửa":
        // (1) cover GỠ view chủ khỏi cây nên `onDisappear` ở trên chạy ⇒ VIDEO TẠM DỪNG khi mở
        //     trình xem. Đó là điều mình muốn: bộ giải mã H.264 và cảnh 3D không nên cùng sống.
        // (2) lúc đóng, `.task` chạy LẠI. Mọi guard trong đó idempotent nên không mất gì, NHƯNG
        //     ✗ tưởng nó miễn phí: `loadTexturedURL` chỉ đóng `texturedAsked` khi SERVER trả về
        //     match. Đường cache (`TexturedModelCache.anyCached`) — máy MẤT MẠNG mà file texture
        //     đã tải về từ trước — dựng được `texturedRemote` với cờ VẪN MỞ, nên mỗi lượt đóng
        //     màn tốn thêm MỘT GET `listOrders`. Cùng cỡ với cái giá `loadTexturedURL` đã tự
        //     nhận là chấp nhận được, ✗ đóng cờ sớm để "tiết kiệm" (chú thích ở hàm đó nói vì
        //     sao đóng sớm là giết tính năng).
        //     ⚠ ✗ ghi vào đây rằng "đơn đã giao thì listOrders thôi liệt kê texture" — SAI:
        //     route `/api/app/v1/orders` dựng `texturedScans` từ `orderScans.filter(texturedUrl)`
        //     KHÔNG gác theo `delivered`, và chính nó có chú thích cấm thêm cổng đó.
        // 🔴🔴 **DÒNG NÀY LÀ `.fullScreenCover` CUỐI CÙNG CÒN SÓT, VÀ NÓ ĐANG MANG BỆNH.**
        // Mở trình xem 3D = trình bày một màn toàn màn hình từ cửa sổ gốc = đúng cái đã làm vùng
        // an toàn của cây SwiftUI đông cứng ở 0 suốt 6 bản IPA (số đo + danh sách hướng đã chết:
        // `ScanCover.swift`). Đường QUÉT đã chuyển sang lớp phủ ở 2.13; đường này CỐ Ý chưa đổi —
        // một cơ chế mỗi vòng thử, chờ chủ app nghiệm thu đường quét trước.
        // 🔴 KHI ĐỔI: ✗ chỉ thay `.fullScreenCover` bằng `ScanCover.show`. Cover đang GỠ màn này
        // khỏi cây nên `.onDisappear` ở trên chạy và VIDEO TỰ TẠM DỪNG — cố ý (hệ quả (1) ghi ở
        // khối trên: bộ giải mã H.264 và cảnh 3D không nên cùng sống). Lớp phủ KHÔNG gỡ cây ⇒
        // phải thêm đường tạm dừng video TƯỜNG MINH trước, không thì video chạy nền dưới mô hình
        // 3D. Và `ModelViewerScreen` phải đổi `@Environment(\.dismiss)` sang closure bơm vào,
        // cùng khuôn `MeshScanFlowView.dismiss`.
        .fullScreenCover(item: $viewerTarget) { target in
            ModelViewerScreen(
                greyURL: target.greyURL,
                texturedRemote: target.texturedRemote,
                cloudScanId: target.cloudScanId,
                // `textured` là `@StateObject` của MÀN NÀY, truyền xuống làm `@ObservedObject`:
                // lượt tải 29–75MB phải sống lâu hơn cover (khách đóng màn giữa chừng rồi mở
                // lại phải bám được vào lượt đang chạy — xem `TexturedModelCache.inFlight`).
                textured: textured
            )
        }
        .sheet(isPresented: $showOrderSheet) {
            // Không còn callback "đã đặt" ở đây: `OrderSheet.submit()` tự đóng dấu số đơn cho
            // đúng tập bản quét trong đơn. Đừng thêm lại — giải thích ở `OrderSheet.submit()`.
            OrderSheet(
                record: current,
                projectName: store.project(with: current.projectId)?.name
            )
        }
        // Gửi bổ sung bản quét vào đơn ĐÃ đặt của dự án. `.sheet(isPresented:)` an toàn ở đây
        // (khác `ProjectView`): nội dung chỉ phụ thuộc `current` + `supplementOrderNumber`, cả
        // hai đã có giá trị từ trước khi cờ lật — không có khe nil như ca `orderTarget`.
        .sheet(isPresented: $showSupplementSheet) {
            if let orderNumber = supplementOrderNumber {
                SupplementSheet(records: [current], orderNumber: orderNumber)
            }
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

    /// Số đơn của DỰ ÁN chứa bản quét này — khác nil ⇒ bản quét này chỉ còn đường GỬI BỔ SUNG.
    ///
    /// Hỏi `ScanStore.orderNumber(ofProject:)`, nguồn DUY NHẤT của quy tắc "1 dự án 1 đơn" (chủ
    /// app chốt 11/08). ✗ tự lọc `cloudOrderNumber` ở đây: ba màn tự tính là ba màn sẽ trôi khỏi
    /// nhau, và hậu quả là khách đặt được đơn thứ hai cho cùng căn nhà.
    ///
    /// Bản quét LẺ (chưa vào dự án nào) → nil → đường đặt hàng bình thường, đúng như trước.
    private var supplementOrderNumber: String? {
        store.orderNumber(ofProject: current.projectId)
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
            } else if let supplementNumber = supplementOrderNumber {
                // 🔴 Bản quét LẺ thuộc một dự án ĐÃ CÓ ĐƠN → "Gửi bổ sung", ✗ "Đặt làm mặt bằng"
                // (chủ app chốt "1 dự án chỉ có 1 đơn"). Bỏ sót màn này là khách vẫn mở được form
                // giá từ đây và đặt ĐƠN THỨ HAI cho cùng căn nhà.
                //
                // ✗ đi qua `startUploadOrOrder()`: `SupplementSheet` TỰ lo việc tải lên (cùng
                // khuôn `ensureUploaded`, idempotent theo `cloudScanId`). Cho nó tải là đường
                // gửi bổ sung có ĐÚNG MỘT chỗ tải lên thay vì hai, và màn này khỏi phải nhân
                // đôi máy trạng thái `uploader.phase`.
                Button {
                    showSupplementSheet = true
                } label: {
                    Label(
                        L.t("Send extra scan to \(supplementNumber)",
                            "Gửi bổ sung vào đơn \(supplementNumber)"),
                        systemImage: "paperplane.fill"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
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

    /// Mở thẳng FORM đặt hàng khi khách vào màn này bằng nút "Đặt hàng ngay" ở màn preview.
    ///
    /// 🔴 GỌI TỪ `.task`, ✗ từ bất cứ chỗ nào set cờ CÙNG NHỊP với cú push. Trình bày một sheet
    /// ngay trong nhịp đẩy màn là đúng cấu trúc đã làm văng app một lần (`48dc791`: UIKit dựng
    /// và ĐO bar item trước khi cầu environment nối tới host của thanh). `.task` chạy sau khi
    /// màn đã appear, tức ngoài cửa sổ đó.
    ///
    /// 🔴 KHÔNG TẢI FILE LÊN Ở ĐÂY, và đó là cả điểm của mục này. Đường của NÚT bấm
    /// (`proceedUploadOrOrder`) tải 40–200MB TRƯỚC rồi mới hiện form; ở đây thì ngược lại —
    /// `OrderSheet.submit()` tự lo việc tải lên qua `ensureUploaded` khi khách thật sự bấm
    /// "Đặt hàng", đúng thứ màn Dự án đã làm từ lâu. Khách thấy GIÁ trước khi tốn dữ liệu.
    /// ⚠ HỆ QUẢ, ✗ phải lỗi: ở đường này thanh % tải lên của `serviceCard` không chạy nữa —
    /// lúc bấm "Đặt hàng" trong form chỉ có vòng xoay + "Đang tải <tên>…" (`OrderSheet` dùng
    /// một `ScanUploader` cục bộ mà nó không quan sát `phase`). Muốn có % ở đó là việc RIÊNG.
    ///
    /// 🔴 GÁC HẸP HƠN NÚT BẤM, VÀ ĐÓ LÀ CỐ Ý — bẫy #18: guard "có CHẶN khách không" ≠ guard "có
    /// TỰ ĐI TIẾP HỘ khách không". Nút chỉ gác `isSignedIn` (gác thêm `needsVerification` ở nút
    /// là khoá nhầm khách đã xác minh khi mạng yếu — lý do dài ở `ProjectView`). Chỗ này thì tự
    /// mở giùm, nên phải đủ điều kiện đặt thật: chưa đăng nhập / chưa xác minh thì KHÔNG mở gì
    /// cả, khách thấy đúng thẻ đăng nhập của `serviceCard` rồi tự bấm — hướng sai duy nhất có
    /// thể xảy ra là "bắt bấm thêm một lần", ✗ chặn ai. Tự mở form cho tài khoản chưa xác minh
    /// chỉ dẫn tới 403 SAU KHI đã tải xong file (bẫy #19).
    ///
    /// ⚠ CỐ Ý KHÔNG chạy nhánh cảnh báo chất lượng thấp của `startUploadOrOrder()`. Chủ app xin
    /// "vào luôn bước đặt hàng"; bật một `confirmationDialog` ngay khi màn vừa hiện là đổi một
    /// nút thừa lấy một hộp thoại thừa. Cảnh báo KHÔNG mất: dòng "Chất lượng quét: x/100 · nên
    /// quét lại" vẫn nằm ngay đầu `serviceCard`, và khách đóng form rồi bấm nút thì hộp thoại
    /// chạy như cũ. Ông kêu thì đây là chỗ đổi, một dòng.
    private func autoOpenOrderIfNeeded() {
        guard autoOpenOrder, !didAutoOpenOrder else { return }
        // Đặt cờ TRƯỚC mọi guard còn lại: đây là lời mời MỘT LẦN cho cú "Đặt hàng ngay" vừa bấm.
        // Đặt sau các guard thì một khách chưa đăng nhập sẽ bị form tự bật vào mặt ở lần `.task`
        // chạy lại BẤT KỲ sau khi họ đăng nhập xong — kể cả khi lúc đó họ đang xem mô hình 3D.
        didAutoOpenOrder = true
        guard stillExists, current.cloudOrderNumber == nil else { return }
        guard account.isSignedIn, !account.needsVerification else { return }
        // 🔴 Dự án đã có đơn ⇒ mở màn GỬI BỔ SUNG, ✗ form đặt hàng. Đây chính là đường chủ app
        // mô tả: *"khi bấm vào đó rồi quét xong thì cái nút đặt hàng ngay nên sửa lại là Gửi bổ
        // sung bản quét"*. Nhãn nút ở màn preview và hành động ở đây đọc CÙNG một điều kiện
        // (`ScanStore.orderNumber(ofProject:)`) nên không thể nói một đằng làm một nẻo.
        if supplementOrderNumber != nil {
            showSupplementSheet = true
            return
        }
        showOrderSheet = true
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

    // 🔴 `legacyTab` + `legacyPlanTab` ĐÃ XOÁ 11/08 cùng RoomPlan (chủ app chốt). Chúng là màn
    // xem bản quét đời RoomPlan: Picker "Mô hình 3D | Mặt bằng 2D", `USDZPreview(model.usdz)` và
    // ảnh `floorplan.png` render sẵn. App không tạo được loại bản quét đó từ 2026-07-20.
    // ⚠ Xoá `legacyTab` cũng đóng luôn mục §OPEN "legacyTab mở model.usdz bằng QuickLook ⇒ gần
    // như chắc chắn mở ra ở CHẾ ĐỘ AR với camera bật" — lỗi chủ app từng báo. Nay không còn
    // đường nào trong app gọi `USDZPreview` nữa và file đó đã xoá.

    /// Bản quét MESH 3D: video walkthrough + hướng dẫn chia sẻ mô hình màu.
    /// (Không có floorplan/USDZ của app — mesh là sản phẩm chính, gửi ra ngoài bằng nút Share.
    /// Mô hình CÓ TEXTURE thì do máy trạm bake, xem qua công tắc trong `modelRow`.)
    private var meshTab: some View {
        VStack(spacing: 10) {
            videoArea(missing: L.t("No walkthrough video in this scan", "Bản quét này không có video"))
            modelRow
            meshInfoFooter
        }
    }

    /// **MỘT nút xem mô hình duy nhất** (bản 2.0 — chủ app chốt: *"gom cái texture và xám thành
    /// 1 … chỉ có nút xem mô hình"*). Đời trước đây là HAI dòng: "Xem mô hình 3D (xám)" và "Xem
    /// mô hình 3D có texture", mỗi dòng một `.fullScreenCover` — chọn giữa xám/texture nay là
    /// công tắc Texture ở góc TRONG trình xem, và cả khối tải/hủy/thử-lại cũng chuyển vào đó.
    ///
    /// Nút hiện khi có ÍT NHẤT MỘT thứ để xem. Hai vế độc lập nhau:
    ///  · `meshPreviewExists` — `mesh-preview.bin`, chỉ bản quét lưu từ 1.4 trở đi mới có, mở tức
    ///    thì, không cần mạng, không cần đã đặt hàng;
    ///  · `texturedRemote` — máy trạm bake xong sau khi đặt đơn, phải tải 29–75MB.
    /// Không có vế nào thì KHÔNG hiện nút: hứa một tính năng rồi cho khách bấm vào màn trống còn
    /// tệ hơn là chưa nói (cùng lý lẽ với `meshPreviewExists` ở bản 1.4).
    ///
    /// 🔴 Chốt DANH TÍNH lúc bấm vào `ModelViewerTarget`, ✗ để trình xem tự đọc `@State` của màn
    /// này — cùng khuôn `ProjectView.OrderSheetTarget` (bẫy #7: nội dung `.sheet/.cover` đọc một
    /// giá trị set CÙNG NHỊP với cờ mở thì lần đầu ra màn TRẮNG).
    /// ⚠ Cái giá đã biết: bake xong TRONG LÚC trình xem đang mở thì công tắc không tự mọc ra —
    /// đóng rồi mở lại là có. Chấp nhận được, và đổi lại là không có khe trắng.
    @ViewBuilder
    private var modelRow: some View {
        if meshPreviewExists || texturedRemote != nil {
            Button {
                viewerTarget = ModelViewerTarget(
                    greyURL: meshPreviewExists ? meshPreviewURL : nil,
                    texturedRemote: texturedRemote,
                    cloudScanId: current.cloudScanId
                )
            } label: {
                Label(L.t("View 3D model", "Xem mô hình 3D"), systemImage: "cube")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)
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

    /// Hỏi server xem bản quét này đã có mô hình texture chưa (máy trạm bake sau khi đặt đơn).
    ///
    /// Nguồn dữ liệu là `listOrders()` — endpoint DUY NHẤT app đọc về đơn/bản quét, và texture
    /// chỉ tồn tại cho bản quét ĐÃ ĐẶT ĐƠN nên không cần endpoint mới.
    /// Ba cửa thoát TRƯỚC khi đụng mạng, theo thứ tự rẻ dần:
    ///  1. đã hỏi XONG rồi (`.task` chạy lại mỗi lần view hiện lại);
    ///  2. bản quét chưa lên server (`cloudScanId == nil`) → chắc chắn chưa có texture;
    ///  3. file đã nằm trong cache → hiện nút ngay, khỏi chờ mạng (offline vẫn xem được).
    ///
    /// 🔴 Cờ `texturedAsked` chỉ đóng khi đã TÌM RA texture. Đóng nó sớm hơn — trước các
    /// `guard`, hoặc ngay khi có đáp về — là giết đúng ca THƯỜNG GẶP của tính năng này: khách
    /// đặt hàng xong vào xem, lúc đó máy trạm chưa bake (đáp về KHÔNG có texture), vài phút
    /// sau bake xong, khách sang tab Đơn hàng rồi quay lại → `.task` chạy lại nhưng cờ đã
    /// đóng → dòng xem texture KHÔNG BAO GIỜ hiện, phải thoát ra vào lại mới thấy.
    /// Giá phải trả: một GET nhỏ mỗi lần view hiện lại CHO TỚI KHI có texture. Chấp nhận được
    /// (cùng cỡ với `listOrders` mà tab Đơn hàng vẫn gọi).
    /// ⚠ Còn tồn: bake LẠI (admin bấm "Bake lại") đổi `?v=` trên link, nhưng màn đang mở đã
    /// có URL cũ và không hỏi lại nữa → vẫn xem bản cũ tới khi thoát ra vào lại màn này.
    private func loadTexturedURL() async {
        guard !texturedAsked, let cloudId = current.cloudScanId else { return }
        if let cached = TexturedModelCache.anyCached(scanId: cloudId) {
            // Đã tải bản nào rồi thì nút phải hiện NGAY, kể cả đang mất mạng. Trỏ vào file
            // cục bộ; nếu server trả về link (có thể là bản BAKE LẠI mới hơn) thì ghi đè bên
            // dưới và lượt bấm sẽ tải bản mới.
            texturedRemote = cached
        }
        guard account.isSignedIn else { return }
        guard let response = try? await APIClient.shared.listOrders() else { return }
        let match = response.orders
            .compactMap { $0.texturedScans }
            .flatMap { $0 }
            .first { $0.scanId == cloudId }
        if let match, let url = URL(string: match.url) {
            texturedRemote = url
            texturedAsked = true // CHỈ đóng cờ khi đã tìm ra (xem chú thích trên)
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
            // ✗ hứa "màu" ở đây nữa: từ đợt LƯU NHANH, mesh xuất ra là XÁM với mọi bản quét
            // bình thường (màu đến sau, từ texture do máy trạm bake) — khách tự bấm Share theo
            // đúng câu này rồi nhận mô hình không màu là lỗi CÂU CHỮ, không phải lỗi file.
            return L.t(
                "Tap Share (top right) to send the 3D model (OBJ) together with the video. This scan type has no floor plan.",
                "Bấm Share (góc trên) để gửi mô hình 3D (OBJ) kèm video. Loại bản quét này không có bản vẽ mặt bằng."
            )
        }
        if FileManager.default.fileExists(atPath: plyURL.path) {
            return L.t(
                "Tap Share (top right) to send the raw 3D mesh (PLY) together with the video. This scan type has no floor plan.",
                "Bấm Share (góc trên) để gửi mesh thô (PLY) kèm video. Loại bản quét này không có bản vẽ mặt bằng."
            )
        }
        return L.t(
            "This scan has video only — no 3D model was captured.",
            "Bản quét này chỉ có video — chưa thu được mô hình 3D."
        )
    }

    /// Nhãn mức nét đã bỏ 2026-07-31 cùng picker (chỉ còn MỘT mức) — `record.meshQuality` vẫn
    /// được ghi vào meta.json nhưng không còn màn nào hiện nó.
    private var meshTitle: String {
        L.t("3D mesh scan", "Bản quét Mesh 3D")
    }

    // 🔴 `videoTab` ĐÃ XOÁ 11/08. Nó là màn của bản quét CHỈ VIDEO (khảo sát không LiDAR) —
    // luồng tạo đã gỡ 2026-07-19 khi chủ app chốt "yêu cầu máy phải có lidar". Khu video của nó
    // (`videoArea`) vẫn còn và nay dùng chung trong `meshTab`.

    /// Nút Share ở toolbar — CHỮ "Share", không phải icon (chủ app chốt 2026-07-28).
    ///
    /// Bấm là mở THẲNG bảng chia sẻ iOS với trọn bộ file (mô hình + video cùng lúc) — không có
    /// menu con bắt chọn định dạng. File mô hình chọn tự động theo thứ tự tốt→phao, xem
    /// `bestMeshModelURL`.
    /// (Nhánh Menu của bản quét RoomPlan CŨ — USDZ/GLB/OBJ/PLY/ảnh mặt bằng — xoá 11/08.)
    ///
    /// Không có gì để chia sẻ (file mất sạch) → KHÔNG hiện nút, thay vì mở một bảng chia sẻ
    /// rỗng không làm gì.
    ///
    /// 🔴 CHỈ ĐỌC `ShareSnapshot` (tham số) — hàm này chạy trong HOST CỦA THANH ĐIỀU HƯỚNG,
    /// nơi environment có thể CHƯA nối (đọc chú thích tại `ShareSnapshot`). Đụng
    /// `current`/`store`/`account` hay bất cứ computed property nào của view ở đây là văng
    /// app trở lại. (Action closure của Button thì được — nó chỉ chạy lúc CHẠM, khi thanh đã
    /// gắn xong từ lâu.)
    @ViewBuilder
    private func shareButton(_ s: ShareSnapshot) -> some View {
        if !s.meshBundle.isEmpty {
            ShareLink(items: s.meshBundle) {
                Text(L.t("Share", "Share"))
            }
        }
    }

    /// Chụp dữ liệu cho nút Share. 🔴 CHỈ gọi từ nơi environment còn nguyên (`.task` của thân
    /// view) — nó đọc `current` (store) + hệ file; gọi từ closure toolbar là đúng cái chết cũ.
    /// Gọi SAU khi `coloredGLBExists`/`coloredZipExists`/`meshShareURL` đã chốt.
    private func makeShareSnapshot() -> ShareSnapshot {
        // Một loại bản quét ⇒ một nhánh. (Ba nhánh cũ theo `captureType` xoá 11/08 cùng RoomPlan.)
        // `meshShareBundle` tự lọc theo file CÓ TRÊN ĐĨA, nên bản quét cũ thiếu mô hình chỉ ra
        // video, và mất sạch file thì gói rỗng ⇒ `shareButton` không hiện nút. Đúng hành vi cũ.
        ShareSnapshot(meshBundle: meshShareBundle)
    }

    /// Trọn gói chia sẻ của bản quét mesh: mô hình tốt nhất + video (thứ nào còn trên đĩa).
    /// Cả hai vào MỘT bảng chia sẻ — AirDrop/Files nhận nhiều file bình thường; app chat nào
    /// từ chối 2 file thì đó là giới hạn phía nhận, chấp nhận được (gói vốn 40–200MB+).
    private var meshShareBundle: [URL] {
        var items: [URL] = []
        if let model = bestMeshModelURL {
            items.append(model)
        }
        if FileManager.default.fileExists(atPath: videoURL.path) {
            items.append(videoURL)
        }
        return items
    }

    /// File mô hình 3D duy nhất được chia sẻ, chọn theo thứ tự tốt→phao:
    /// zip (OBJ+MTL+GLB đủ bộ, mang tên bản quét) → OBJ rời → GLB rời → PLY (bản phao khi nén
    /// zip lỗi lúc lưu). Bản quét cũ còn giữ nhiều định dạng thì cũng chỉ lấy MỘT — chủ app
    /// chốt 2026-07-28: bỏ menu chọn GLB/PLY riêng lẻ.
    private var bestMeshModelURL: URL? {
        if coloredZipExists {
            return meshShareURL ?? coloredZipURL
        }
        if FileManager.default.fileExists(atPath: objURL.path) {
            return objURL
        }
        if coloredGLBExists {
            return coloredGLBURL
        }
        if FileManager.default.fileExists(atPath: plyURL.path) {
            return plyURL
        }
        return nil
    }

    // 🔴 `legacyShareItems` ĐÃ XOÁ 11/08 cùng RoomPlan — menu con chọn USDZ/GLB/OBJ/PLY/ảnh mặt
    // bằng cho bản quét đời cũ. Bản quét cũ nay chia sẻ qua CÙNG đường với bản mới
    // (`meshShareBundle`: mô hình tốt nhất theo thứ tự zip→OBJ→GLB→PLY, kèm video) — tức GLB và
    // PLY của chúng vẫn gửi ra được, chỉ mất quyền CHỌN định dạng. Hai thứ mất hẳn là
    // `model.usdz` và `floorplan.png`, đúng phần RoomPlan.
    //
    // `meshShareItems` (menu con chọn OBJ/GLB/PLY/video cho bản mesh) ĐÃ GỠ 2026-07-28 —
    // thay bằng `shareControl` + `meshShareBundle`: một nút Share, một cú, đủ bộ file.

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

    // 🔴 `selectionHasVideoScan` + `selectionHasMeshScan` ĐÃ XOÁ 11/08 cùng RoomPlan. Cả hai rẽ
    // theo `ScanRecord.captureType`, trường đã bỏ: nay mọi bản quét đều là mesh nên cái thứ nhất
    // LUÔN false (dòng cảnh báo của nó xoá luôn) và cái thứ hai LUÔN true (dòng của nó nay vô
    // điều kiện). Xem chỗ dùng ở `Section` phía dưới.

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
                // Cảnh báo "đơn có bản quay video, số đo kém chính xác hơn" ĐÃ XOÁ 11/08 cùng
                // RoomPlan: không còn bản quét video-only nào tạo ra được từ 2026-07-19.
                // Dòng dưới nay VÔ ĐIỀU KIỆN (trước gác `selectionHasMeshScan`) — mọi bản quét
                // đều là mesh, nên điều kiện đó luôn đúng.
                Label(
                    L.t(
                        "This order includes 3D mesh scans — the floor plan is drawn from the raw mesh + video.",
                        "Đơn này có bản quét Mesh 3D — mặt bằng sẽ được vẽ từ mesh thô + video."
                    ),
                    systemImage: "cube.transparent"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
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

// 🔴 `ZoomableView` ĐÃ XOÁ 11/08 — nó CHỈ dùng để phóng to ảnh mặt bằng `floorplan.png` của bản
// quét RoomPlan (`legacyPlanTab`), nên bóc RoomPlan là nó thành code chết. Trình xem mô hình 3D
// KHÔNG dùng nó (`ModelViewer` tự xử lý cử chỉ trong SceneKit).
