import ARKit
import SwiftUI
// 🔴 TẠM, GỠ CÙNG `safeAreaProbe` của bản 2.6: `UIApplication`/`UIWindowScene` để đọc
// `safeAreaInsets` của CỬA SỔ. Khai tường minh chứ ✗ trông chờ ARKit kéo UIKit vào hộ — lỗi kiểu
// đó chỉ lộ sau 10 phút CI (tiền lệ ghi ở `ScanDetailView`).
import UIKit

/// Trang một dự án (căn nhà): danh sách bản quét các tầng, quét thêm, đặt hàng cả căn.
struct ProjectView: View {
    /// 🔴🔴 **TRUYỀN VÀO, ✗ `@EnvironmentObject`. ĐÂY LÀ BẢN VÁ CỦA VỤ VĂNG APP (11/08) —
    /// ✗ ĐỔI NGƯỢC LẠI, KỂ CẢ "CHO GỌN".**
    ///
    /// Đo bằng dSYM trên HAI `.ips` (bản 2.0 và 2.3, UUID khớp): app chết ở `store.project(with:)`
    /// trong computed property `project` bên dưới — khung `ProjectView.project.getter + 852` —
    /// tới qua `body` → `content` → closure `Group` → `scans` → `project` → `store`.
    /// Vì sao chết: `UIKitBarItemHost.initializeSize()` đo bar item GIỮA CÚ PUSH → kéo chạy `body`
    /// của màn này trong một ViewGraph mà cầu environment CHƯA nối; `DynamicBody.updateValue()`
    /// cài LẠI property wrapper theo host hiện tại (✗ dùng giá trị đã capture) nên
    /// `@EnvironmentObject` không tra ra object → `EnvironmentObject.error()` → SIGTRAP.
    ///
    /// 🔴 **`@ObservedObject` KHÔNG THỂ TRAP:** giá trị của nó là một tham chiếu LƯU THẲNG trong
    /// struct view — không tra environment, không có nhánh lỗi nào để mà rơi vào. Cùng lý lẽ đã
    /// đúng với `@State` (xem `ScanDetailView.ShareSnapshot`): đọc trong host chưa nối chỉ trả
    /// giá trị hiện có. Việc QUAN SÁT thay đổi không mất gì — `@ObservedObject` vẫn đăng ký
    /// `objectWillChange` y như `@EnvironmentObject`.
    ///
    /// ⚠ Màn này có **BỐN** cửa đọc `store` trên đường render đầu (`scans` · `bottomButtons` ×2 ·
    /// `.onChange(of: project == nil)`) — liệt đủ ở khối 🔴🔴 tại `project`. Vá kiểu bịt từng cửa
    /// là sai hướng; đây là vá TẬN GỐC, cắt cả bốn cùng lúc.
    /// Chuỗi cấp store: `CedarScanApp` (@StateObject) → `RootView` → `HomeView` → màn này.
    ///
    /// ⚠ `.environmentObject(...)` ở `CedarScanApp` VẪN CÒN và vẫn chảy xuống cây view. Các sheet
    /// của màn này (`OrderSheet`, `SupplementSheet`, `AccountGateSheet`) vẫn đọc
    /// `@EnvironmentObject` như cũ và AN TOÀN — chúng chỉ được dựng khi khách đã bấm, lúc màn đã
    /// gắn xong từ lâu. ✗ đổi chúng theo.
    /// 🔴 NGOẠI LỆ từ 2.11: `MeshScanFlowView` KHÔNG còn trong danh sách đó — cover quét nay
    /// present bằng UIKit (`ScanCoverPresenter`), RỜI cây SwiftUI, environment không tự chảy tới;
    /// store của nó đến từ `.environmentObject(store)` bơm tay ở chỗ present. ✗ coi cú bơm đó là
    /// thừa mà gỡ.
    /// Chi tiết đo + cách đo lại: SESSION-HANDOFF §CRASH ĐANG MỞ.
    @ObservedObject var store: ScanStore
    /// Cần cho CỔNG CHẶN ĐẶT HÀNG ở cuối file. Màn này từng không đọc `AccountStore` một dòng
    /// nào — xem giải thích ở nút "Đặt làm mặt bằng".
    /// ⚠ `account` KHÔNG phải một trong bốn cửa (mọi chỗ đọc nó đều nằm trong action closure /
    /// `onDismiss`, tức chỉ chạy lúc khách bấm). Truyền vào cùng `store` vì lý do khác: để màn
    /// này KHÔNG CÒN `@EnvironmentObject` nào — còn một cái là còn đường cho lỗi quay lại.
    @ObservedObject var account: AccountStore
    @Environment(\.dismiss) private var dismiss
    let projectId: UUID
    /// Tên dự án CHỤP LÚC ĐẨY MÀN — dữ liệu THƯỜNG, cố ý KHÔNG tra từ `store`.
    ///
    /// ⚠ GIA CỐ + VÁ LỖI TIÊU ĐỀ RỖNG, ✗ PHẢI LÀ BẢN VÁ ĐÃ CHỨNG MINH CỦA VỤ VĂNG APP.
    /// Bối cảnh: bản 1.4 văng 2 lần (10/08, incident 0226F250 + 4A3E9FF6) khi bấm vào dự án ở
    /// Home — SIGTRAP, `EnvironmentObject.error()` gọi từ 4 khung CedarScan dưới
    /// `ViewBodyAccessor.updateBody`, tất cả nằm trong `UIKitBarItemHost.initializeSize()` lúc
    /// iOS cấu hình NÚT BACK giữa cú push. Cùng HỌ với vụ 06/08 (`48dc791`): thân view chạy
    /// trong host chưa nối environment thì đọc `@EnvironmentObject` là chết.
    /// ✅ 11/08 CHIỀU — ĐÃ ĐO BẰNG dSYM (log bản 2.0 + 2.3, UUID khớp). **DÒNG GÂY VĂNG KHÔNG PHẢI
    /// TIÊU ĐỀ, mà là `project` ở dòng ~100 dưới đây** (`store.project(with:)`), qua đường
    /// `body` → `content` → closure `Group` → `scans` (inline) → `project` → `store`.
    /// ⇒ **Thay đổi này VÔ CAN với vụ văng.** Nó vẫn ĐÚNG và GIỮ NGUYÊN, nhưng chỉ vì hai lý do
    /// TỰ THÂN: bớt một lần chạm environment ở chỗ sát thanh điều hướng, và vá một lỗi CÓ THẬT —
    /// dự án bị dọn mất thì tiêu đề cũ hiện chuỗi RỖNG. ✗ ghi ở đâu rằng nó chữa crash.
    /// 🔴 Suy luận "tại `.navigationTitle`" nay CHẾT BẰNG ĐO (trước mới chết bằng lý luận:
    /// `.navigationTitle(_:)` nhận STRING nên tính trong THÂN VIEW này). Lý luận đó ĐÚNG.
    /// 🔴 CÁCH ĐO LẠI, ✗ cần máy Mac: `tools/ips-symbolicate/` + `dsym-<app_version>/`.
    /// 🔴 LUẬT VẪN ĐÚNG và vẫn nên theo: thứ nuôi thanh điều hướng — tiêu đề, item `.toolbar`,
    /// nhãn nút Back màn sau thừa hưởng — nên là dữ liệu THƯỜNG (`let`/`@State`). Đọc `@State`
    /// ở host chưa nối thì AN TOÀN (chỉ trả giá trị hiện có) — lý do ở `ScanDetailView.ShareSnapshot`.
    /// Chi tiết + stack: SESSION-HANDOFF §CRASH ĐANG MỞ.
    let projectName: String
    /// Đường dẫn điều hướng của NavigationStack đang chứa màn này (sở hữu bởi HomeView) — cần
    /// để màn preview sau khi quét đẩy được sang trang bản quét.
    @Binding var path: NavigationPath

    @State private var isMeshScanning = false
    @State private var showGuide = false
    /// Người dùng đã BẤM "Bắt đầu quét" trong guide (khác với "guide đang mở"). Reset ở LỐI VÀO
    /// chứ không chỉ trong onDismiss — xem giải thích đầy đủ ở HomeView.startAfterGuide.
    @State private var startAfterGuide = false
    /// Khách bấm "Quét thêm khu vực còn thiếu" ở màn preview → mở lại phiên quét cho CÙNG căn.
    @State private var pendingScanMore = false
    /// Bản quét khách vừa bấm "Đặt hàng ngay" ở màn preview.
    @State private var pendingOrderRecord: ScanRecord?
    @State private var meshCapFollowUp = false
    @State private var showScanNextPart = false
    /// Mục tiêu của form đặt hàng: DANH TÍNH các bản quét đã chốt đúng lúc mở form.
    ///
    /// 🔴 Dùng `.sheet(item:)`, KHÔNG dùng `.sheet(isPresented:)` + cờ Bool riêng. Đây là chỗ đã
    /// trả giá một lần: bản trước để `@State showOrderSheet` (Bool) và một `@State` thứ hai chứa
    /// danh sách id, cả hai set CÙNG một nhịp trong `presentSendSheet()`. Nhưng `.sheet(isPresented:)`
    /// dựng nội dung khi cờ lật true, và ở nhịp đó `@State` thứ hai CHƯA kịp commit — lần ĐẦU mở
    /// form của mỗi `ProjectView` (giá trị còn nil) cho ra một sheet TRẮNG trượt lên rồi phải vuốt
    /// xuống; lần sau đã có giá trị nên hết, mở dự án khác (ProjectView mới) lại nil → trắng lại.
    /// Đúng triệu chứng khách báo trên máy thật, mà hai vòng review đối kháng KHÔNG bắt được vì nó
    /// là race lúc CHẠY, không phải lỗi logic đọc trên máy Windows.
    /// `.sheet(item:)` truyền thẳng `target` (đã unwrap) vào closure nên nội dung LUÔN có dữ liệu
    /// ngay lần đầu — không còn khe nil.
    ///
    /// 🔴 `scanIds` CHỈ giữ `[UUID]`, TUYỆT ĐỐI KHÔNG giữ `[ScanRecord]`. Chụp cả bản ghi là đóng
    /// băng luôn `cloudScanId`, mà `OrderSheet.ensureUploaded` đọc đúng trường đó để biết "tầng này
    /// đã lên server chưa". Đóng băng nó thì lần đặt thứ hai (sau timeout 30s / 403 chưa xác minh /
    /// rớt 4G — đều là ca thật) sẽ TẢI LÊN LẠI 40–200MB mỗi tầng và đẻ scan id MỚI; hai chốt
    /// chống-đơn-trùng phía server đều khoá theo scan id nên id mới lọt cả hai → đơn thứ hai cho
    /// cùng căn nhà, trừ hai lần suất miễn phí. Chốt danh tính, giải GIÁ TRỊ sống mỗi lần render.
    private struct OrderSheetTarget: Identifiable {
        let id = UUID()
        let scanIds: [UUID]
    }
    @State private var orderTarget: OrderSheetTarget?
    /// Đích của màn **GỬI BỔ SUNG** — cùng khuôn `OrderSheetTarget` và cùng lý do: chỉ giữ
    /// `[UUID]`, ✗ `[ScanRecord]` (đóng băng `cloudScanId` = tải lên lại + đẻ scan id mới).
    /// Kiểu RIÊNG chứ ✗ dùng lại `OrderSheetTarget`: hai `.sheet(item:)` phân biệt nhau bằng
    /// KIỂU của binding, và một cờ Bool chung là đúng lỗi đã trả giá ở chính `orderTarget`.
    private struct SupplementTarget: Identifiable {
        let id = UUID()
        let scanIds: [UUID]
    }
    @State private var supplementTarget: SupplementTarget?
    /// Cổng đăng nhập/xác minh mở tại chỗ — xem `AccountGateSheet`.
    @State private var showAccountGate = false
    @State private var showLowQualityConfirm = false
    @State private var recordToRename: ScanRecord?
    @State private var renameText = ""
    @State private var showRenameProject = false
    @State private var projectNameText = ""
    @State private var showDeleteConfirm = false
    @State private var pendingSaveError: String?
    @State private var saveError: String?
    /// Tên MỚI sau khi khách đổi tên ngay trên màn này (lối đổi tên DUY NHẤT của dự án —
    /// `store.renameProject` chỉ có một call site, trong `.alert` bên dưới). nil = chưa đổi.
    /// 🔴 Phải là `@State`, ✗ đọc lại `store`: xem chú thích ở `projectName`.
    @State private var renamedTitle: String?
    /// 🔴 BẢN ĐO TẠM 2.10 — quan sát số lượt `repair()` đã chạy để nhãn vàng tự vẽ lại.
    /// GỠ CÙNG `safeAreaProbe`. Có giá trị mặc định nên KHÔNG đổi memberwise init.
    @ObservedObject private var repairStats = SafeAreaRepairStats.shared

    /// Tiêu đề màn — CHỈ đọc `let` + `@State`, không chạm `store`. Xem `projectName`.
    private var displayTitle: String { renamedTitle ?? projectName }

    /// 🔴🔴 **DÒNG NÀY TỪNG LÀM VĂNG APP — ĐO BẰNG dSYM 11/08. ĐÃ VÁ cùng ngày** bằng cách đổi
    /// `store` sang `@ObservedObject` truyền vào (khối 🔴🔴 ở khai báo `store`). Giữ ghi chú này
    /// vì nó là thứ giải thích VÌ SAO khai báo đó không được đổi ngược.
    ///
    /// Khi còn `@EnvironmentObject`: chữ `store` ở dòng dưới (cột 41) chính là chỗ
    /// `EnvironmentObject.error()` bắn ra — khung 3 của CẢ HAI `.ips` (bản 2.0 và 2.3),
    /// `ProjectView.project.getter + 852`. `UIKitBarItemHost.initializeSize()` đo bar item giữa
    /// cú push → kéo chạy `body` của MÀN NÀY trong ViewGraph mà cầu environment CHƯA nối → trap.
    ///
    /// ⚠🔴 **VÌ SAO PHẢI VÁ TẬN GỐC CHỨ ✗ BỊT TỪNG CHỖ: màn này có BỐN cửa**, dòng dưới chỉ là
    /// cửa nổ TRƯỚC (vì `Group` được dựng sớm nhất). Bịt nó là văng ở cửa 2, rồi cửa 3. Cả bốn
    /// đều nằm trên đường render ĐẦU TIÊN, không cần khách bấm gì:
    ///  1. `content` → `Group` (`scans.isEmpty`) → `scans` → `project`   ← cửa đã nổ
    ///  2. `content` → `.safeAreaInset` → `bottomButtons` (`orderableScans`) → `scans` → `project`
    ///  3. `content` → `.safeAreaInset` → `bottomButtons` (`projectOrderNumber`) → `store`
    ///  4. `body` → `.onChange(of: project == nil)` — ĐỐI SỐ, ✗ closure ⇒ tính mỗi lượt dựng body
    /// (✗ ghi số dòng ở đây: danh sách này đã lạc hậu một lần vì chính chú thích thêm vào phía
    /// trên đẩy số dòng đi. Tên thì không trôi.)
    /// ⚠ Chưa kiểm: nội dung `.alert` (`scans.count`) và `.confirmationDialog` (`lowQualityNames`)
    /// — CÓ VẺ lười, nhưng chưa ai chứng minh. Nay vô hại vì `store` không còn là env; ai đưa
    /// `@EnvironmentObject` trở lại thì phải kiểm hai chỗ đó TRƯỚC.
    /// ⚠ `ScanDetailView` có SÁU cửa cùng loại, cũng đã vá cùng lượt. Chi tiết:
    /// SESSION-HANDOFF §CRASH ĐANG MỞ.
    private var project: ScanProject? { store.project(with: projectId) }
    /// 🔴 Cửa THỨ NHẤT tới `project` ở trên: hàm này bị INLINE vào closure `Group` của `content`,
    /// nên nó không có khung riêng trong crash log (log chỉ thấy 4 khung cho 5 chặng).
    private var scans: [ScanRecord] { project.map { store.scans(in: $0) } ?? [] }
    private var orderableScans: [ScanRecord] { scans.filter { $0.cloudOrderNumber == nil } }
    /// Dự án ĐÃ có đơn ⇒ mọi bản quét sau chỉ còn đường GỬI BỔ SUNG, ✗ đặt đơn thứ hai.
    /// Chủ app chốt 11/08: *"1 dự án chỉ có 1 đơn"*. Hỏi `ScanStore` — nguồn DUY NHẤT trả lời câu
    /// này cho cả ba màn; ✗ tự lọc `cloudOrderNumber` tại chỗ.
    private var projectOrderNumber: String? { store.orderNumber(ofProject: projectId) }
    /// Xem ghi chú ở `HomeView.isSupported` — hỏi ARKit, không hỏi RoomPlan.
    private var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    var body: some View {
        content
            // 🔴🔴 **BẢN ĐO TẠM — GỠ NGAY SAU KHI ĐỌC ĐƯỢC SỐ. ✗ ĐỂ LẪN VÀO BẢN GIAO KHÁCH.**
            // Cùng luật với `ScanPerfProfiler`/hai khoá Files app: mọi thứ CHỈ-ĐỂ-ĐO phải ra khỏi
            // app ngay khi xong. Bản 2.6 sinh ra chỉ để đọc một con số.
            //
            // Việc nó đo: lỗi "header đè lên bản quét + nút Đặt làm mặt bằng bị đĩa Scan đè" chỉ
            // xảy ra SAU KHI QUÉT, thoát app vào lại là hết. Hai cơ chế đều khớp triệu chứng và
            // đòi hai cách vá NGƯỢC nhau, phân biệt được bằng đúng con số này:
            //  · `win` = 0 ⇒ vùng an toàn của CỬA SỔ bị bỏ về 0 thật ⇒ rò từ `.ignoresSafeArea()`
            //    của cover quét ⇒ vá = đưa việc present cover ra ngoài `.safeAreaInset`.
            //  · `win` VẪN ĐÚNG (t≈47–59, b≈34) mà chữ vẫn đè ⇒ lề không hỏng, chỉ là `List`
            //    không được GẮN với thanh điều hướng ⇒ thủ phạm là `.toolbar(.hidden, for:.tabBar)`
            //    / `BarAppearanceBridge`, và hoisting cover là công cốc.
            // `geo` = lề mà chính view này nhìn thấy (đã trừ `.safeAreaInset` của màn) — kèm theo
            // để biết chênh lệch nằm ở tầng cửa sổ hay tầng SwiftUI.
            .overlay(alignment: .topLeading) { safeAreaProbe }
            // 🔴 Phát bổ sung của `SafeAreaRepair` (2.9): đặt lịch sửa lề sau khi màn này xuất
            // hiện. Nhắm giả thuyết "lỗi tái nhiễm LÚC PUSH" — crash 11/08 nổ trong bộ máy bar
            // item GIỮA cú push, nên riêng phát ở onDismiss của cover có thể luôn tới sớm quá.
            // ⚠ `nudge()` CHỈ ĐẶT LỊCH (chạy sau 0,6s, lúc transition đã xong) — ✗ sửa thành gọi
            // thẳng `pass/repair` tại đây "cho nhanh": bắn đồng bộ trong onAppear là ép layout
            // toàn cửa sổ GIỮA hoạt ảnh push, đúng án review vòng 2 đã bắt (BLOCKER).
            // Vô hình + idempotent + tự gộp; chạy cả ở lần push lành cũng không sao.
            .onAppear { SafeAreaRepair.nudge() }
            // Dự án biến mất trong lúc màn này đang mở → thoát ra.
            // ⚠ NGUỒN GÂY RA ĐÃ ĐỔI Ở BẢN 1.8, GUARD THÌ KHÔNG. Trước đây thủ phạm DUY NHẤT là
            // việc dọn-sau-khi-giao chạy ngầm (nay đã tắt — `RootView.autoPurgeAfterDelivery`).
            // Nay chỉ còn đường KHÁCH TỰ BẤM XOÁ, và đường đó tự `dismiss()` ngay trong nút của
            // hộp thoại — tức hai lối thoát cùng bắn cho một cú xoá. Vô hại và đã như vậy từ
            // trước: `leaveDeadProject` hoãn một nhịp rồi mới `dismiss()`, mà `dismiss()` lần hai
            // trên một màn đã pop là việc không làm gì cả.
            // ✗ GỠ hai `onChange` này theo (bẫy #3 ngược lại: ở đây LÝ DO VẪN CÒN — hàm
            // `deleteProjectAndScans` vẫn nil hoá `project`, và cờ dọn có thể được bật lại).
            // NavigationStack giữ `ScanProject` trong path nên màn KHÔNG tự pop: tiêu đề thành
            // trắng, danh sách rỗng, mà nút "Quét căn nhà này" vẫn đó và trỏ vào một projectId
            // không còn tồn tại. Xảy ra thật khi app quay lại foreground lúc khách đang ở đây.
            // KHÔNG dismiss khi đang quét. Lý do ĐỔI ở 2.11 nhưng guard thì GIỮ: đời
            // `.fullScreenCover` thì view này sở hữu cover, pop là tháo phiên quét; nay cover
            // present bằng UIKit từ VC trên cùng nên pop KHÔNG tháo cover nữa — nhưng pop là gỡ
            // mất cái `.onChange(of: isMeshScanning)` đang cầm đường ĐÓNG cover: khách bấm xong
            // phiên quét thì binding lật mà không ai gọi `ScanCoverPresenter.dismiss`, cover kẹt.
            // `ScanStore.beginBusy()` đã chặn dọn suốt phiên nên ca này gần như không xảy ra —
            // đây là lớp thứ hai; pop nhầm lúc đang quét vẫn đắt hơn nán lại một màn rỗng.
            // 🔴 CỬA SỐ 4 CỦA VỤ VĂNG (đo 11/08) — nay AN TOÀN vì `store` đã là `@ObservedObject`.
            // Giữ ghi chú vì nó dễ bị hiểu nhầm là vô hại: `project == nil` là ĐỐI SỐ của
            // `.onChange`, ✗ closure, nên nó được tính MỖI lượt dựng `body`. Bảng dòng của
            // `body.getter` xác nhận đây là hàng NGAY SAU lời gọi `content`.
            // ⇒ Ai đưa `@EnvironmentObject` trở lại màn này thì dòng này văng lại NGAY, kể cả khi
            // đã "vá" cửa `scans`. Danh sách đủ 4 cửa ở khối 🔴🔴 tại khai báo `project`.
            .onChange(of: project == nil) { _, gone in
                if gone && !isMeshScanning { leaveDeadProject() }
            }
            // Cover đóng mà dự án đã biến mất trong lúc đó → giờ mới thoát.
            .onChange(of: isMeshScanning) { _, presented in
                if !presented && project == nil { leaveDeadProject() }
            }
    }

    /// 🔴🔴 **BẢN ĐO TẠM CỦA 2.6 (ba tầng ở 2.9; 2.10 thành NÚT BẤM + đếm lượt sửa) — GỠ CÙNG
    /// `.overlay` ở `body` VÀ `repairStats` VÀ `forceRepairNow`. ✗ giữ lại "cho lần sau".**
    /// Đọc BA nguồn vì chúng có thể lệch nhau, và chính chỗ lệch mới là câu trả lời:
    ///  · `win` = `safeAreaInsets` của CỬA SỔ, hỏi thẳng UIKit ⇒ sự thật gốc, không qua SwiftUI.
    ///  · `root` = `safeAreaInsets` UIKit của view root VC ⇒ tầng GIỮA.
    ///  · `geo` = lề mà view này nhìn thấy qua `GeometryProxy` ⇒ tầng SwiftUI.
    /// 2.10 đổi hai điều, cả hai vì vòng 2.9 để lộ lỗ đo:
    ///  · nhãn tụt xuống 180pt — bản cũ nằm ở y=0, đúng chỗ header đè lên LÚC LỖI nên chủ app
    ///    không đọc được số đúng lúc cần nhất;
    ///  · nhãn là NÚT: chạm = `forceRepairNow()` (bỏ lịch + cổng) + hiện `fix n` = số lượt
    ///    `repair()` đã THẬT SỰ chạy. Đang lỗi mà chạm nhãn → màn tự sửa ⇒ sửa-từ-ngoài SỐNG,
    ///    lỗi ở lịch/cổng; chạm mà trơ ⇒ 3 phát trượt thật ⇒ mới đáng đổi cách trình bày cover.
    /// `GeometryReader` đặt trong `.overlay` nên KHÔNG đụng vào bố cục đang đo; vùng GR ngoài
    /// nhãn không có nội dung nên cú chạm xuyên qua bình thường — chỉ đúng miếng nhãn nuốt chạm.
    @ViewBuilder
    private var safeAreaProbe: some View {
        GeometryReader { geo in
            // Mốc lành (chủ app, 2.9): `win t47 b34 · root t47 b34 · geo t91 b34` (91 = 47 + 44).
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }.first
            let win = scene?.keyWindow?.safeAreaInsets ?? .zero
            let root = scene?.keyWindow?.rootViewController?.view.safeAreaInsets ?? .zero
            Button {
                SafeAreaRepair.forceRepairNow()
            } label: {
                Text(
                    "fix\(repairStats.repairCount)"
                    + " · win t\(Int(win.top)) b\(Int(win.bottom))"
                    + " · root t\(Int(root.top)) b\(Int(root.bottom))"
                    + " · geo t\(Int(geo.safeAreaInsets.top)) b\(Int(geo.safeAreaInsets.bottom))"
                )
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.yellow)
                .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .padding(.top, 180)
        }
    }

    /// Thoát khỏi một dự án đã bị dọn mất — HOÃN MỘT NHỊP, không `dismiss()` ngay tại chỗ.
    ///
    /// ⚠ Đoạn giải thích dưới đây tả cơ chế của việc DỌN TỰ ĐỘNG, thứ đã TẮT ở bản 1.8. Giữ
    /// nguyên vì nó là lý do hàm này phải hoãn một nhịp thay vì `dismiss()` thẳng, và vì cờ
    /// `autoPurgeAfterDelivery` bật lại là một dòng.
    ///
    /// 🔴 Vì sao phải hoãn: `purgeDeliveredScans()` (RootView) chạy mỗi lần app quay lại
    /// foreground và nó `await APIClient.listOrders()` TRƯỚC khi xoá — tức thời điểm nó xoá dự án
    /// là một cú MẠNG về, trễ 0,3–3 giây, hoàn toàn không đồng bộ với ngón tay người dùng. Nếu nó
    /// đáp về đúng lúc khách vừa chạm một dòng dự án, chuỗi sau xảy ra: `NavigationStack` bắt đầu
    /// PUSH màn này → thân view chạy → `project` đã là nil → `onChange` bắn → `dismiss()` → POP
    /// một view controller mà cú PUSH của nó còn chưa chạy xong. Đó là kiểu làm
    /// `UINavigationController` mất đồng bộ, và nó khớp với triệu chứng chủ app báo: "THỈNH
    /// THOẢNG bấm vào dự án thì app tự văng" — thỉnh thoảng, vì phải trúng đúng cửa sổ vài trăm
    /// mili-giây đó.
    ///
    /// `Task { @MainActor in … }` đẩy việc thoát sang nhịp chạy KẾ TIẾP, sau khi SwiftUI đã đóng
    /// gói xong bản cập nhật hiện tại (và cú push đã ổn định). KIỂM LẠI điều kiện bên trong, vì
    /// giữa hai nhịp mọi thứ có thể đã đổi — nhất là `isMeshScanning`: pop nhầm lúc khách đang
    /// quét là mất trắng 10–30 phút đi bộ.
    private func leaveDeadProject() {
        Task { @MainActor in
            guard project == nil, !isMeshScanning else { return }
            dismiss()
        }
    }

    private var content: some View {
        Group {
            if scans.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        ForEach(scans) { record in
                            ScanRow(
                                store: store,
                                record: record,
                                onRename: {
                                    renameText = record.name
                                    recordToRename = record
                                }
                            )
                        }
                    } footer: {
                        Text(L.t(
                            "Give each scan a clear name (Whole home, Part 1, Shed…) so we can assemble the home correctly.",
                            "Đặt tên rõ cho từng bản quét (Cả căn, Part 1, Nhà kho…) để đội xử lý ghép nhà chính xác."
                        ))
                    }
                }
            }
        }
        // `displayTitle` = `let` + `@State`, không tra `store`. Dòng này từng là
        // `project?.name ?? ""`. ⚠ ĐỌC khối ở khai báo `projectName` trước khi đụng: đây là GIA
        // CỐ + vá lỗi tiêu đề rỗng, KHÔNG phải bản vá đã chứng minh của vụ văng app.
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        // Màn PUSH tự khai trạng thái thanh tab — mục 3a. Lý do đầy đủ, số học của chỗ hở và
        // việc "đây là ỨNG VIÊN chứ ✗ bản vá đã chứng minh" ghi ở CHÍNH chỗ này trong
        // `ScanDetailView`; ✗ chép lại, ĐỌC nó.
        // Màn này chưa ai báo lệch — lối vào DUY NHẤT của nó là chạm một dòng dự án ở Home
        // (`NavigationLink(value: project)`), tức đúng kiểu đẩy vẫn cho ra bố cục đúng. Vẫn khai
        // vì nó là màn PUSH thứ hai và cũng tự chừa `CedarTabBar.reservedHeight` bên dưới: để
        // hai màn khai khác nhau là tự đẻ ra một cặp màn song sinh lệch nhau, thứ repo này đã
        // trả giá nhiều lần.
        //
        // 🔴 **LỊCH SỬ 11/08 — dòng dưới từng bị GỠ ở bản 2.7 làm nghi can của lỗi đè chữ, và đã
        // được MINH OAN BẰNG ĐO: 2.7 không có nó vẫn lỗi y nguyên.** Khai lại từ 2.8. Kết quả đo
        // 2.6→2.10 (`win t47 b34 · root t47 b34 · geo t0 b0`, mọi cú sửa-từ-ngoài đều trơ) chỉ
        // vào cú THÁO-GẮN cây view của `.fullScreenCover` — **vá thật là `ScanCoverPresenter`
        // (2.11): cover quét present `.overFullScreen`, không tháo cây nữa.**
        // ⇒ Câu dặn cũ "gỡ modifier này là lỗi (3a) quay lại" SỐNG LẠI nguyên hiệu lực.
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        // Đọc `store` ở đây AN TOÀN: closure hành động của Menu chỉ chạy khi
                        // khách CHẠM, lúc đó thanh điều hướng đã gắn xong từ lâu và cầu
                        // environment đã nối. Chỉ THÂN VIEW của bar item mới là chỗ chết
                        // (xem `projectName`). Cùng lời khai với `48dc791`.
                        projectNameText = displayTitle
                        showRenameProject = true
                    } label: {
                        Label(L.t("Rename property", "Đổi tên dự án"), systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label(L.t("Delete property", "Xóa dự án"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            // 🔴 TỰ CHỪA CHỖ CHO THANH TAB. Màn này được PUSH bên trong `NavigationStack` của
            // tab Home, mà vùng an toàn do `.safeAreaInset` của TabView tạo ra KHÔNG chảy tới
            // đây — nên nếu không cộng thêm, thanh tab che mất nút dưới cùng. Xem giải thích
            // đầy đủ ở `CedarTabBar.reservedHeight` (chủ app đã gặp: "nút Quét bổ sung bị che").
            bottomButtons
                .padding(.bottom, CedarTabBar.reservedHeight)
        }
        .alert(L.t("Rename property", "Đổi tên dự án"), isPresented: $showRenameProject) {
            TextField(L.t("Name", "Tên"), text: $projectNameText)
            Button(L.t("Save", "Lưu")) {
                // Tiêu đề KHÔNG còn tự theo store nữa (nó chỉ đọc `let`/`@State` — xem
                // `projectName`), nên phải cập nhật tay ở đây.
                // 🔴 Nằm TRONG `if let project` và dùng ĐÚNG phép chuẩn hoá của
                // `ScanStore.renameProject` (cắt khoảng trắng, rỗng thì bỏ qua): tiêu đề chỉ
                // được đổi khi đĩa THẬT SỰ đã đổi. Đặt ngoài thì dự án vừa bị dọn mất (project
                // == nil) vẫn đổi được tiêu đề sang một cái tên chưa từng được ghi.
                if let project {
                    store.renameProject(project, to: projectNameText)
                    let trimmed = projectNameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { renamedTitle = trimmed }
                }
            }
            Button(L.t("Cancel", "Hủy"), role: .cancel) {}
        }
        // 🔴 XOÁ DỰ ÁN NAY XOÁ LUÔN FILE BẢN QUÉT KHỎI MÁY (mục 5b — chủ app chốt 10/08). Câu
        // chữ lấy từ `DeleteProjectPrompt` chứ ✗ gõ tại chỗ: lối vào THỨ HAI là nút giỏ rác trên
        // dòng dự án ở `HomeView`, và hai lối phải nói y hệt nhau. Xem chú thích ở enum đó.
        // ⚠ Số bản quét đọc SỐNG (`scans.count`) ngay lúc dựng hộp thoại — đúng cái khách đang
        // nhìn thấy trong danh sách ngay trên.
        .alert(DeleteProjectPrompt.title, isPresented: $showDeleteConfirm) {
            Button(DeleteProjectPrompt.confirmLabel(scanCount: scans.count), role: .destructive) {
                if let project { store.deleteProjectAndScans(project) }
                dismiss()
            }
            Button(L.t("Cancel", "Hủy"), role: .cancel) {}
        } message: {
            Text(DeleteProjectPrompt.message(scanCount: scans.count))
        }
        .alert(L.t("Rename scan", "Đổi tên bản quét"), isPresented: renameAlertBinding) {
            TextField(L.t("New name", "Tên mới"), text: $renameText)
            Button(L.t("Save", "Lưu")) {
                if let record = recordToRename { store.rename(record, to: renameText) }
                recordToRename = nil
            }
            Button(L.t("Cancel", "Hủy"), role: .cancel) { recordToRename = nil }
        }
        .alert(L.t("Could not save", "Lỗi khi lưu"), isPresented: saveErrorBinding) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        // Bắt đầu quét từ onDismiss chứ không từ callback của guide — ScanGuideView gọi
        // dismiss() rồi onStart() cùng một transaction, present thẳng ở đó là present-trong-
        // lúc-sheet-đang-đóng. Xem giải thích đầy đủ ở HomeView.
        .sheet(isPresented: $showGuide, onDismiss: {
            guard startAfterGuide else { return }
            startAfterGuide = false
            startScanning()
        }) {
            ScanGuideView { startAfterGuide = true }
        }
        // 🔴🔴 COVER QUÉT PRESENT BẰNG UIKIT `.overFullScreen` TỪ 2.11 — cùng khuôn, cùng lý do,
        // cùng lời giải thích "vì sao onChange ở đây KHÔNG phạm lệnh cấm 06/08" với HomeView
        // (đọc chú thích dài ở đó). Hai màn phải giữ khuôn GIỐNG NHAU.
        // (Cái `.onChange(of: isMeshScanning)` còn lại ở `body` — leaveDeadProject — là việc
        // KHÁC và vẫn đúng chỗ: nó không present gì, đã tự hoãn nhịp.)
        .onChange(of: isMeshScanning) { _, presenting in
            if presenting {
                ScanCoverPresenter.present(
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
                                name: result.name, projectId: projectId, quality: result.quality,
                                geometryOnly: result.geometryOnly,
                                // Thanh % của màn "Đang dựng mô hình 3D…" — chuyển thẳng, ✗ nuốt.
                                progress: saveProgress
                            )
                            if result.hitCap { meshCapFollowUp = true }
                            return saved
                        } catch {
                            pendingSaveError = error.localizedDescription
                            return nil
                        }
                    }
                    // 🔴 BẮT BUỘC — rời cây SwiftUI, environment không tự chảy. Xem HomeView.
                    .environmentObject(store),
                    // Present thất bại → trả binding về false. Xem HomeView + ScanCoverPresenter.
                    onFailure: { isMeshScanning = false }
                )
            } else {
                ScanCoverPresenter.dismiss {
                    afterScanCoverClosed()
                }
            }
        }
        .alert(
            L.t("Part of the home is missing", "Còn một phần nhà chưa vào bản quét"),
            isPresented: $showScanNextPart
        ) {
            Button(L.t("Scan the rest now", "Quét phần còn lại ngay")) {
                pendingOrderRecord = nil
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
        .sheet(item: $orderTarget) { target in
            orderSheetBody(target)
        }
        .sheet(item: $supplementTarget) { target in
            supplementSheetBody(target)
        }
        .sheet(isPresented: $showAccountGate, onDismiss: {
            // Qua được cổng thì ĐI TIẾP việc khách đang làm dở, đừng bắt họ bấm lại đúng cái nút
            // vừa bấm.
            //
            // Màn này khác `ScanDetailView` ở chỗ nguy hiểm: ở đó thẻ dịch vụ vẽ THEO TRẠNG THÁI
            // nên cổng vừa đóng là dòng chữ + nút "Đăng nhập" tự biến thành nút "Đặt làm mặt bằng"
            // ngay tại chỗ vừa bấm — khách thấy rõ mình vừa tiến một bước. Ở đây nhãn nút KHÔNG
            // phụ thuộc `account`, nên thiếu đoạn này thì đăng nhập xong màn hình không đổi MỘT
            // PIXEL: khách đọc thành "đăng ký xong vẫn không đặt được" rồi bỏ đi.
            //
            // 🔴 Phải nằm ở `onDismiss`, KHÔNG được đổi sang `.onChange` của trạng thái tài khoản:
            // mở sheet thứ hai trong lúc sheet thứ nhất chưa tháo xong là đúng họ lỗi trình bày
            // lồng nhau mà repo đã trả giá ở luồng "Quét thêm" (SESSION-HANDOFF mục 2.E).
            // 🔴 Điều kiện ở đây HẸP HƠN guard ở nút bấm, và đó là CỐ Ý — đừng "sửa cho khớp".
            // Hai chỗ hỏi hai câu khác nhau:
            //  · Nút bấm hỏi "có CHẶN khách không?" → chỉ `isSignedIn`. Gác thêm `needsVerification`
            //    ở đó là khoá nhầm người đã xác minh khi cờ còn cũ (giải thích dài ở nút).
            //  · Chỗ này hỏi "có TỰ ĐI TIẾP HỘ khách không?" → phải đủ điều kiện đặt hàng thật.
            //    Gác hẹp ở đây KHÔNG chặn ai: khách bấm lại nút là qua ngay, vì nút chỉ gác
            //    `isSignedIn`. Nên hướng sai duy nhất có thể xảy ra là "bắt bấm thêm một lần".
            //
            // Vì sao phải hẹp: `isSignedIn` bật lên NGAY GIỮA LÚC sheet còn mở — khách đăng ký
            // xong thì rơi sang màn nhập mã, sheet chưa đóng vì chưa đủ điều kiện. Từ giây đó MỌI
            // kiểu đóng sheet đều thoả `isSignedIn`, kể cả VUỐT XUỐNG hoặc bấm "Hủy" — tức đúng
            // lúc khách vừa nói THÔI thì form đặt hàng lại tự bật ra, rồi kết thúc bằng lỗi server
            // vì chưa xác minh. Gác hẹp là để cú rút lui đó được tôn trọng.
            guard account.isSignedIn, !account.needsVerification else { return }
            startOrderFlow()
        }) {
            AccountGateSheet()
        }
    }

    /// Mở luồng đặt hàng SAU khi đã qua cổng tài khoản.
    ///
    /// Dùng chung cho nút bấm và cho `onDismiss` của cổng: hai lối vào phải cư xử y hệt. Tách ra
    /// để không lối nào lỡ quên bước cảnh báo chất lượng thấp.
    private func startOrderFlow() {
        // Chặn mềm: có bản quét chất lượng thấp → khuyên quét lại, vẫn cho gửi
        if orderableScans.contains(where: { $0.qualityRescan == true }) {
            showLowQualityConfirm = true
        } else {
            presentSendSheet()
        }
    }

    /// LỐI VÀO DUY NHẤT của form đặt hàng **và** của màn gửi bổ sung.
    ///
    /// Mọi chỗ muốn mở sheet phải gọi hàm này, ĐỪNG gán `orderTarget`/`supplementTarget` thẳng ở
    /// nơi khác: đóng gói việc chốt danh tính vào một chỗ. Có đúng hai lối vào (nút đáy và nút
    /// "Vẫn đặt hàng" của cảnh báo chất lượng thấp), và lối thứ hai đã một lần bị bỏ quên khi sửa
    /// lối thứ nhất.
    ///
    /// 🔴 **RẼ NHÁNH THEO STORE, ✗ theo nút nào vừa bấm.** Cùng một điều kiện
    /// (`projectOrderNumber != nil`) quyết định CẢ nhãn nút LẪN việc mở sheet nào — nên nhãn
    /// không thể nói một đằng mà hành động đi một nẻo, kể cả khi khách qua cổng tài khoản rồi
    /// `onDismiss` tự đi tiếp hộ họ (đường đó cũng vào đây).
    private func presentSendSheet() {
        // Tập rỗng thì không có gì để gửi. Nút gọi hàm này vốn đã ẩn khi rỗng, nên đây là lớp thứ
        // hai — fail-closed. Tính `ids` TRƯỚC rồi mới dựng target: gán target là thao tác DUY
        // NHẤT bật sheet (sheet(item:) hiện khi item != nil), nên target phải đủ dữ liệu ngay.
        let ids = orderableScans.map(\.id)
        guard !ids.isEmpty else { return }
        if projectOrderNumber != nil {
            supplementTarget = SupplementTarget(scanIds: ids)
        } else {
            orderTarget = OrderSheetTarget(scanIds: ids)
        }
    }

    /// Nội dung form đặt hàng: DANH TÍNH chốt lúc mở (trong `target`), GIÁ TRỊ đọc SỐNG từ store
    /// mỗi lần render.
    ///
    /// Tách thành hàm nhận `target` theo đúng lệ của repo — biểu thức SwiftUI lồng nhiều tầng là
    /// thứ CI này từng chết vì "Swift type-check timeout". Cũng vì lẽ đó mà gọi `liveScans(of:)`
    /// HAI LẦN thay vì hứng vào một `let` cục bộ: khai báo cục bộ trong thân ViewBuilder là đúng
    /// mẫu bị cấm ở `ScanAddressView.expandRow`. Gọi hai lần vô hại — cùng một nhịp render, cùng
    /// một trạng thái store.
    ///
    /// 🔴 KHÔNG có callback đóng dấu "đã đặt" ở đây, và đừng thêm lại. Chỗ này từng chạy
    /// `for record in orderableScans { store.setOrderNumber(...) }`, tức đóng dấu lên cả tầng
    /// khách vừa BỎ CHỌN trong form — hậu quả ghi đầy đủ ở `OrderSheet.submit()`, nơi duy nhất
    /// biết khách đã tick những tầng nào và nay tự lo việc đóng dấu.
    @ViewBuilder
    private func orderSheetBody(_ target: OrderSheetTarget) -> some View {
        if let primary = liveScans(of: target).first {
            OrderSheet(
                record: primary,
                projectName: project?.name,
                candidateScans: liveScans(of: target)
            )
        }
    }

    /// Nội dung màn GỬI BỔ SUNG. Cùng khuôn `orderSheetBody`: danh tính chốt lúc mở, giá trị đọc
    /// sống. `projectOrderNumber` đọc lại ở đây (✗ chụp vào target) vì nó là thứ QUYẾT ĐỊNH gửi
    /// vào đơn nào — chụp một số đơn cũ rồi gửi vào đó là nhét file sang nhầm đơn.
    @ViewBuilder
    private func supplementSheetBody(_ target: SupplementTarget) -> some View {
        if let orderNumber = projectOrderNumber, !liveScans(of: target).isEmpty {
            SupplementSheet(records: liveScans(of: target), orderNumber: orderNumber)
        }
    }

    /// Giải danh tính đã chốt thành bản ghi SỐNG. Bản quét bị dọn mất giữa chừng thì rơi khỏi
    /// danh sách (compactMap) thay vì kéo theo dữ liệu ma.
    private func liveScans(of target: OrderSheetTarget) -> [ScanRecord] {
        target.scanIds.compactMap { id in store.records.first { $0.id == id } }
    }

    private func liveScans(of target: SupplementTarget) -> [ScanRecord] {
        target.scanIds.compactMap { id in store.records.first { $0.id == id } }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(get: { recordToRename != nil }, set: { if !$0 { recordToRename = nil } })
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(L.t("No scans in this property yet", "Dự án chưa có bản quét nào"))
                .font(.headline)
            Text(L.t(
                "Scan the whole home in one continuous pass — multiple floors are fine. If it's very large, split it into several scans (Part 1, Part 2…). Or long-press an existing scan in the main list to move it here.",
                "Quét liền một mạch cả căn nhà là tốt nhất (kể cả nhiều tầng). Nhà quá lớn thì chia thành nhiều bản quét (Part 1, Part 2…). Hoặc nhấn giữ bản quét có sẵn ở danh sách chính để chuyển vào đây."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Tách khỏi thân nút để guide gọi lại được từ onDismiss.
    /// Reset hai cờ ở LỐI VÀO — xem giải thích đầy đủ ở HomeView.startScanning.
    ///
    /// 🔴 VÀO THẲNG cover, không còn sheet trung gian: `ScanQualityPickerView` đã xoá cùng picker
    /// độ nét (2026-07-31). Gọi từ onDismiss của guide vẫn AN TOÀN — onDismiss chạy SAU khi sheet
    /// guide đóng hẳn, đúng khuôn "present cover từ onDismiss" mà HomeView đang dùng.
    /// Căn nhà đã biết (`projectId` của màn này) nên không có gì để hỏi trước khi quét nữa.
    private func startScanning() {
        pendingOrderRecord = nil
        pendingScanMore = false
        isMeshScanning = true
    }

    /// 🔴 Thân `onDismiss` cũ của cover (06/08), chuyển nguyên vẹn sang khuôn 2.11 — chạy từ
    /// `completion` của `ScanCoverPresenter.dismiss`, SAU KHI cover đóng HẲN. Cùng khuôn + cùng
    /// chú thích đầy đủ với `HomeView.afterScanCoverClosed` — hai màn phải giữ GIỐNG NHAU.
    /// Thứ tự ưu tiên GIỮ NGUYÊN: lỗi lưu > quét thêm > chạm trần > đặt hàng.
    private func afterScanCoverClosed() {
        SafeAreaRepair.nudge()
        if let message = pendingSaveError {
            pendingSaveError = nil
            meshCapFollowUp = false
            pendingOrderRecord = nil
            pendingScanMore = false
            saveError = message
        } else if pendingScanMore {
            pendingScanMore = false
            meshCapFollowUp = false
            pendingOrderRecord = nil
            isMeshScanning = true
        } else if meshCapFollowUp {
            // Xem giải thích thứ tự ưu tiên ở HomeView.
            meshCapFollowUp = false
            showScanNextPart = true
        } else {
            goToPendingOrder()
        }
    }

    /// Xem HomeView.goToPendingOrder — cùng một việc, trên cùng một NavigationStack, và phải đẩy
    /// CÙNG MỘT KIỂU (`ScanOrderIntent`): `navigationDestination` khai ở HomeView phục vụ cả hai
    /// màn, nên đẩy `ScanRecord` trần ở đây là rơi vào destination "chỉ xem" và mục 3b chết đúng
    /// một nửa — im lặng, chỉ ở đường quét-từ-dự-án.
    private func goToPendingOrder() {
        guard let record = pendingOrderRecord else { return }
        pendingOrderRecord = nil
        path.append(ScanOrderIntent(record: record))
    }

    /// Lặp lại lời giải thích ở ĐÂY chứ không trông vào việc người dùng đã đọc ở trang chủ.
    ///
    /// Từng viết comment "vào được màn này nghĩa là đã qua trang chủ, nơi đã nói rõ lý do" —
    /// SAI: lời giải thích đầy đủ của trang chủ nằm trong `emptyState`, mà `emptyState` chỉ hiện
    /// khi CẢ records LẪN projects đều rỗng. Chỉ cần tạo một dự án là nó biến mất VĨNH VIỄN.
    /// Mà nút "Dự án mới" lại KHÔNG bị khoá theo isSupported, nên đường đó rất dễ đi vào.
    @ViewBuilder
    private var unsupportedNote: some View {
        if !isSupported {
            Text(L.t(
                "This iPhone has no LiDAR sensor. CedarScan needs an iPhone Pro (12 Pro or newer).",
                "iPhone này không có cảm biến LiDAR. CedarScan cần iPhone bản Pro (12 Pro trở lên)."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
    }

    private var bottomButtons: some View {
        VStack(spacing: 8) {
            unsupportedNote
            Button {
                // Guide lần đầu Y HỆT HomeView. Trước P3 màn này KHÔNG hề kiểm seenKey: khách
                // tạo Dự án trước rồi quét từ đây sẽ không bao giờ đọc hướng dẫn, và vì seenKey
                // vẫn false nên lần sau quét từ Home guide mới nhảy ra — sau khi bản quét đầu
                // tiên đã hỏng.
                if !UserDefaults.standard.bool(forKey: ScanGuideView.seenKey) {
                    startAfterGuide = false
                    showGuide = true
                } else {
                    startScanning()
                }
            } label: {
                Label(L.t("Scan more", "Quét bổ sung"), systemImage: "viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            // Máy không LiDAR: khoá nút (luồng quay video đã gỡ 2026-07-19).
            .disabled(!isSupported)

            if !orderableScans.isEmpty {
                Button {
                    // 🔴 CỔNG CHẶN TÀI KHOẢN — ĐỨNG TRƯỚC cả cảnh báo chất lượng. Chưa đăng nhập
                    // thì hỏi chuyện "có muốn quét lại không" là vô nghĩa: khách còn chưa có tài
                    // khoản để đặt.
                    //
                    // Cổng này TỪNG KHÔNG TỒN TẠI và đó là ngõ cụt tệ nhất của luồng đặt hàng.
                    // `OrderSheet` KHÔNG tự kiểm tra đăng nhập (nó chỉ khai `store`), nên nút này
                    // mở thẳng sheet → `.task` gọi `catalog()` với token nil → hỏng → khách thấy
                    // chuỗi lỗi thô kèm nút "Thử lại" bấm mãi không bao giờ chạy được, và KHÔNG
                    // câu nào nhắc tới đăng nhập. Khách không hiểu vì sao mình bị chặn.
                    //
                    // Lỗi tồn tại được là vì màn này là BẢN SAO gần-y-hệt của HomeView và cổng
                    // chặn chỉ được thêm ở `ScanDetailView.serviceCard`. Ai sửa luồng đặt hàng ở
                    // một bên thì phải soi bên kia — hai đường vào cùng một `OrderSheet`.
                    //
                    // 🔴 CHỈ gác `isSignedIn`, CỐ Ý KHÔNG gác `needsVerification` — đừng "thêm cho
                    // nhất quán với ScanDetailView". Đã thử và phải gỡ ra sau ba vòng review:
                    // `emailVerified` chỉ đúng sau khi `refresh()` nói chuyện được với server, mà
                    // `refresh()` nuốt lỗi mạng. Gác thêm cờ đó nghĩa là khách ĐÃ xác minh, mở app
                    // ở công trường sóng yếu, bị khoá khỏi nút đặt hàng của cả căn nhà — một hồi
                    // quy do chính cổng chặn tạo ra, vì màn này TRƯỚC GIỜ KHÔNG chặn xác minh.
                    // Mọi cách chống đỡ (lưu cờ xuống đĩa, cờ "đã biết chắc", fail-open, thêm mốc
                    // thử lại) đều đẻ ra lỗi mới ở vòng sau — nặng nhất là làm `VerifyEmailView`
                    // biến mất khỏi app vì `needsVerification` là lối vào DUY NHẤT tới nó.
                    //
                    // Ngõ cụt cần sửa ở đây là "chưa đăng nhập → sheet lỗi thô + Thử lại vô tận",
                    // và nó thuộc về `isSignedIn`. Việc chưa xác minh vẫn để server từ chối như
                    // trước bản vá — chưa đẹp, nhưng KHÔNG phải hồi quy, và có việc riêng theo dõi.
                    guard account.isSignedIn else {
                        showAccountGate = true
                        return
                    }
                    startOrderFlow()
                } label: {
                    // 🔴 Dự án ĐÃ có đơn ⇒ nhãn phải là "Gửi bổ sung", ✗ "Đặt làm mặt bằng".
                    // Bỏ sót chỗ này là khách vẫn đặt được ĐƠN THỨ HAI cho cùng căn nhà và quy
                    // tắc "1 dự án 1 đơn" của chủ app chỉ đúng một nửa. Nhãn và hành động cùng
                    // đọc MỘT điều kiện (`projectOrderNumber`) — xem `presentSendSheet()`.
                    Label(
                        projectOrderNumber != nil
                            ? L.t("Send extra scan (\(orderableScans.count))",
                                  "Gửi bổ sung bản quét (\(orderableScans.count))")
                            : L.t("Order Floor Plan (\(orderableScans.count) scan(s))",
                                  "Đặt làm mặt bằng (\(orderableScans.count) bản quét)"),
                        systemImage: "paperplane.fill"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .confirmationDialog(
                    L.t("Some scans have low quality", "Có bản quét chất lượng thấp"),
                    isPresented: $showLowQualityConfirm,
                    titleVisibility: .visible
                ) {
                    Button(L.t("Order anyway", "Vẫn đặt hàng")) {
                        presentSendSheet()
                    }
                    Button(L.t("I'll rescan first", "Để tôi quét lại"), role: .cancel) {}
                } message: {
                    Text(L.t(
                        "Rescanning the flagged floors usually gives a more accurate floor plan: \(lowQualityNames). You can still order — our team will be notified.",
                        "Quét lại các tầng bị đánh dấu thường cho bản vẽ chính xác hơn: \(lowQualityNames). Bạn vẫn có thể đặt — đội xử lý sẽ được báo trước."
                    ))
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private var lowQualityNames: String {
        orderableScans.filter { $0.qualityRescan == true }.map(\.name).joined(separator: ", ")
    }
}

/// Câu chữ của hộp xác nhận "Xóa dự án" — VIẾT MỘT LẦN, DÙNG CHO CẢ HAI LỐI VÀO.
///
/// Hai lối: menu "…" của `ProjectView` (ngay trên) và **nút giỏ rác trên dòng dự án ở
/// `HomeView`** (mục 6 của phản hồi 1.4). Chủ app chốt hai lối làm ĐÚNG MỘT VIỆC
/// (`ScanStore.deleteProjectAndScans`) — mà repo này đã trả giá nhiều lần vì hai màn song sinh
/// trôi khỏi nhau, nên chữ cũng chỉ được phép tồn tại ở một chỗ. Thêm lối thứ ba thì gọi vào đây.
///
/// 🔴 CÂU "ĐƠN ĐÃ ĐẶT KHÔNG BỊ ẢNH HƯỞNG" LÀ BẮT BUỘC, ✗ RÚT GỌN. Chủ app nói thẳng lý do:
/// *"đơn đặt hàng là file floorplan hay gì đó thì phải giữ lại vì đó là những thứ họ đã trả
/// tiền"*. Không có câu đó thì khách đọc nút giỏ rác thành "xoá luôn bản vẽ mình vừa mua" và sẽ
/// không bao giờ bấm — tức tính năng thay thế cho việc dọn tự động chết ngay từ đầu.
/// Câu này ĐÚNG SỰ THẬT về kỹ thuật: app không có endpoint nào xoá đơn hay file thành phẩm; nó
/// chỉ xoá `Documents/Scans/<uuid>/` trên chính máy này.
enum DeleteProjectPrompt {
    static var title: String { L.t("Delete this property?", "Xóa dự án này?") }

    /// Nhãn nút phá huỷ, CÓ SỐ BẢN QUÉT trong nhãn (chủ app duyệt). Người dùng bấm xuyên qua phần
    /// chữ mô tả nhưng gần như luôn đọc nhãn nút — nên con số phải nằm ở đây, không chỉ trong
    /// message.
    static func confirmLabel(scanCount: Int) -> String {
        guard scanCount > 0 else { return L.t("Delete property", "Xóa dự án") }
        return L.t(
            "Delete property and \(scanCount) scan(s)",
            "Xóa dự án và \(scanCount) bản quét"
        )
    }

    static func message(scanCount: Int) -> String {
        guard scanCount > 0 else {
            return L.t(
                "This property has no scans on this iPhone.",
                "Dự án này chưa có bản quét nào trên máy."
            )
        }
        return L.t(
            "\(scanCount) scan(s) will be deleted from this iPhone and cannot be recovered. Orders you have already placed and the finished drawings are NOT affected — they stay on Cedar247 and you can download them from the Orders tab any time.",
            "\(scanCount) bản quét sẽ bị xóa khỏi iPhone, không lấy lại được. Đơn đã đặt và file thành phẩm KHÔNG bị ảnh hưởng — chúng nằm trên máy chủ Cedar247, tải lại ở tab Đơn hàng bất cứ lúc nào."
        )
    }
}
