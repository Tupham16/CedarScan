import SwiftUI
import UIKit // Color(uiColor:) cho nền đục + đo chiều cao CỬA SỔ cho cú trượt (`travel`)

/// **Cover quét là một LỚP PHỦ SwiftUI trong chính cây view của app** (dựng ở bản 2.13):
/// `MeshScanFlowView` được vẽ như một nhánh ZStack ngay trên `RootView`, cùng một
/// `UIHostingController`, cùng một ViewGraph. Không present, không cửa sổ riêng, không tháo-gắn.
///
/// 🔴🔴 **FILE NÀY ✗ PHẢI BẢN VÁ CỦA LỖI "LỀ ĐÔNG CỨNG" — ĐỌC KỸ TRƯỚC KHI DỰA VÀO NÓ.**
/// Nó ra đời như MỘT LẦN THỬ VÁ lỗi đó, và **nó đã KHÔNG vá được** (bản 2.13 vẫn lỗi y nguyên).
/// Thủ phạm thật nằm ở chỗ khác hẳn và được tìm ra ở **bản 2.18**: **cú NẢY TAB** — đĩa SCAN đặt
/// `selection = .scan` rồi `RootView` bật ngược về `.home` trong cùng một nhịp, qua một tab
/// `Color.clear` giả. Số đo + ma trận đối chứng: khối 🔴🔴 đầu `CedarTabBar.swift`.
/// ⇒ **✗ ghi ở đâu rằng lớp phủ chữa được lỗi lề, và ✗ dùng "để khỏi đông cứng lề" làm lý do giữ
/// nó.** Lý do giữ là lý do KHÁC, ghi ngay dưới đây.
///
/// # Vì sao VẪN GIỮ lớp phủ (chủ app chốt 12/08, sau khi biết nó không phải bản vá)
/// Hoàn nguyên về `.fullScreenCover` là thêm một refactor lớn nữa vào vùng bẫy dày nhất repo, để
/// đổi lấy một khác biệt khách không nhìn thấy. Lớp phủ thì đã qua **5 vòng review đối kháng** và
/// đã chạy thật qua các bản 2.13/2.14/2.18 không ai báo lỗi. Nên: giữ, và vá riêng hai lỗ đã biết
/// ở khối 🟡 bên dưới khi nào gặp.
/// ⚠ Nhưng nó KHÔNG còn "bất khả xâm phạm" như đời trước tưởng: nếu sau này có lý do thật (vd hai
/// lỗ 🟡 kia thành phiền), hoàn nguyên là một lựa chọn HỢP LỆ — cơ chế trình bày nào cũng được,
/// vì không cơ chế nào trong số đó là nguyên nhân của lỗi lề.
///
/// # Lịch sử — 8 bản IPA vá NHẦM MÀN (2.6→2.14). Giữ để ✗ ai đi lại
/// Cả tám đều nhắm vào màn quét / cách trình bày cover, trong khi thủ phạm (cú nảy tab) chạy
/// TRƯỚC tất cả: `.toolbar(.hidden, for:.tabBar)` (2.7, minh oan) · `SafeAreaRepair` v1/v2 +
/// bắn tay (2.8→2.10, trơ hoàn toàn, file đã xoá) · `.overFullScreen` (2.11) · **cửa sổ riêng**
/// (2.12) · lớp phủ này (2.13) · bỏ `.safeAreaInset` trong sheet màn địa chỉ (2.14).
/// 🔴 **Cái làm cả tám trượt là một lỗi ĐỌC, không phải lỗi kỹ thuật:** câu "mở màn quét → Hủy
/// ngay" bị đọc thành MỘT thao tác, trong khi nó là BA khúc — đĩa SCAN → cú nảy tab → sheet địa
/// chỉ. Sáu vòng không ai tách ra đo. Harness CI tách được trong một lượt 8 phút.
/// **Luật rút ra: trước khi vá, tách đường đi ra từng màn và đo từng khúc. Một câu mô tả thao tác
/// ✗ phải một phép đo.**
///
/// # Cái phải TỰ LO (lớp phủ không có sẵn như presentation)
///  · **Nền ĐỤC** — `MeshScanFlowView` để camera tự vẽ nền, mà hai đường alert (LiDAR/camera bị từ
///    chối) thì camera KHÔNG BAO GIỜ chạy ⇒ thiếu nền là thấy Home lấp ló sau lưng.
///  · **VoiceOver** — lớp phủ chặn CHẠM nhưng KHÔNG chặn focus của VoiceOver (repo đã trả giá 2
///    lần vụ này, bẫy #10), và `.toolbar`/`.searchable` được SwiftUI ĐẨY RA thanh điều hướng UIKit
///    nên `.accessibilityHidden` ở cây dưới KHÔNG với tới chúng. Cần CẢ hai: ẩn cây dưới + đánh
///    dấu cover là MODAL.
///  · **Chặn chạm suốt CẢ HAI lượt trượt** — 0,35s lên và 0,3s xuống là hai cửa sổ mà lớp phủ chưa
///    che kín màn hình; presentation của UIKit tự khoá màn dưới, lớp phủ thì không. Cửa sổ ĐÓNG
///    nguy hiểm hơn cửa sổ MỞ (ngón tay khách vừa bấm xong một nút, còn đang di chuyển).
///  · **Thanh tab + thanh điều hướng**: lớp phủ gắn ở `CedarScanApp`, tức NGOÀI `RootView` và
///    ngoài cả `.safeAreaInset` dựng `CedarTabBar` ⇒ nó phủ luôn thanh tab. Gắn thấp hơn (trong
///    HomeView / ProjectView) là thanh tab và thanh điều hướng vẽ ĐÈ LÊN cover.
///
/// 🟡 **LỖ CÒN LẠI — VÀ NÓ LÀ **MỘT** CÂU HỎI DUY NHẤT, ✗ phải bốn lỗ rời:**
/// > **Một cú chạm lên vùng `UINavigationBar` có xuyên qua được lớp phủ SwiftUI không?**
/// `.allowsHitTesting` chỉ chặn trong cây SwiftUI, mà SwiftUI ĐẨY `.toolbar`/`.searchable` ra
/// thanh điều hướng UIKit thật; nút Back và cử chỉ vuốt-back thì do UIKit tự dựng, không modifier
/// nào của SwiftUI chạm tới. Bốn thứ ngồi đúng chỗ đó: **Back · vuốt-back · menu "…" của
/// ProjectView · ô tìm kiếm của Home.** Trả lời được câu hỏi trên là đóng hoặc mở cả bốn cùng lúc.
///  · **Phép thử 15 giây (§TEST của handoff):** mở quét TỪ MỘT DỰ ÁN, rồi lần lượt bấm vào đúng
///    chỗ nút Back, chỗ nút "…", chỗ ô tìm kiếm, và vuốt từ mép trái. Không cái nào ăn ⇒ đóng cả
///    bốn, và mấy lớp gác dưới đây chỉ là bảo hiểm.
///  · Hậu quả nếu LỌT, theo thứ tự nặng dần: **ô tìm kiếm** (bàn phím nổi LÊN TRÊN cover, đội vùng
///    an toàn ⇒ màn quét bị bóp ngắn cả buổi, mà nút Hủy của ô tìm kiếm thì nằm sau lớp phủ nên
///    khách không gỡ ra được) · **Back / vuốt-back** (pop `ProjectView` giữa buổi quét ⇒ mất cái
///    `.onChange` đang cầm đường ĐÓNG cover ⇒ **cover kẹt vĩnh viễn, chỉ còn cách tắt app**).
///    ⚠ Ca ô tìm kiếm có MỘT đường thoát, và chính nó — ✗ phải câu "lúc đó chưa quét được gì nên
///    tắt app không mất gì" — mới là thứ chặn trần thiệt hại: bấm "Dừng & Lưu" là ô nhập TÊN BẢN
///    QUÉT giành lấy first responder, lưu xong bàn phím đi theo ⇒ buổi quét XẤU ĐI chứ không CHẾT.
///    ✗ dùng lập luận "chưa quét gì": khách không tắt app ở giây thứ 0,35 — họ tưởng bàn phím tự
///    đi rồi cứ thế đi bộ 25 phút, tới lúc trả giá thì đã có dữ liệu chưa lưu. (Review vòng 5.)
///    Vá tương ứng: `.navigationBarBackButtonHidden` lúc đang phủ (hoặc dời đường đóng cover ra
///    khỏi ProjectView), và `.ignoresSafeArea(.keyboard)` cho cover + trả lại việc né bàn phím cho
///    riêng `ScanNameOverlay` (nó là ô nhập DUY NHẤT trong cover).
///  · **ĐÃ GÁC SẴN, ✗ gỡ:** menu "…" của `ProjectView` khai `.disabled(scanCover.blocksInput)` —
///    đường DUY NHẤT trong bốn thứ trên dẫn tới xoá dữ liệu; lớp phủ khai `.isModal` cho VoiceOver
///    (VoiceOver thì chưa bao giờ bị hình vẽ chặn, nên cái đó cần bất kể câu trả lời ở trên).
///    ⚠ `HomeView` KHÔNG có chốt tương ứng và đó là NGOẠI LỆ CÓ LÝ của luật "hai màn phải khai
///    giống nhau": toolbar của Home đã gỡ hẳn từ 2026-07-23 (không có item nào để mà gác), còn
///    `.searchable` thì không `.disabled` được. ✗ "cân bằng lại cho giống".
///  · **Bàn phím vật lý / Full Keyboard Access:** `.allowsHitTesting` chỉ chặn CHẠM, không rút
///    control khỏi chuỗi focus — gõ Tab vẫn tới được nút sau lưng cover. (`.disabled` thì chặn
///    được, nhưng nó làm xám cả màn — xem chú thích tại chỗ.) iPad có bàn phím rời mới gặp.
///  · app hiện MỘT scene (không khai `UIApplicationSupportsMultipleScenes`), mà `ScanCoverModel`
///    là singleton TOÀN TIẾN TRÌNH còn `.scanCoverLayer()` gắn theo scene. Ai bật đa cửa sổ iPad
///    sau này (`TARGETED_DEVICE_FAMILY: "1,2"` đã sẵn) sẽ vẽ CÙNG một cover ở hai scene ⇒ hai
///    `ARSession` giành camera. ✗ bật đa cửa sổ mà không đổi model thành theo-scene.
///  · **Swift 6:** `finish` trong `hide` là closure khai trong hàm `@MainActor` nên nó thừa hưởng
///    isolation, mà closure của `asyncAfter` thì `@Sendable` (không thừa hưởng). Ở
///    `SWIFT_VERSION: "5.0"` đây KHÔNG phải lỗi; ai nâng lên Swift 6 phải bọc
///    `MainActor.assumeIsolated { finish() }` hoặc đưa `finish` ra thành `@MainActor static func`.
///
/// ⚠ **Trình xem 3D (`ScanDetailView.viewerTarget`) vẫn là `.fullScreenCover` — VÀ NAY KHÔNG CÒN
/// LÝ DO NÀO PHẢI ĐỔI NÓ.** Đời 2.13 để dành đổi sau vì tưởng `.fullScreenCover` gây đông cứng
/// lề; 2.18 chứng minh không phải (thủ phạm là cú nảy tab). ⇒ **✗ "đưa nó qua khuôn lớp phủ cho
/// đồng bộ"** — đó là refactor không có lý do, mà nó lại đắt: cover đang GỠ `ScanDetailView` khỏi
/// cây nên `onDisappear` chạy và VIDEO TỰ TẠM DỪNG (cố ý — bộ giải mã H.264 và cảnh 3D không nên
/// cùng sống); lớp phủ KHÔNG gỡ cây nên phải tự dựng đường tạm dừng video trước.
enum ScanCover {
    /// Thời lượng hoạt ảnh trượt lên/xuống — thay hoạt ảnh present mặc định của view controller.
    private static let showDuration = 0.35
    private static let hideDuration = 0.3
    /// 🔴 **LƯỚI CUỐI, ✗ hạ xuống gần `hideDuration`.** Đây KHÔNG phải mốc chạy `completion` bình
    /// thường (mốc đó là completion của chính hoạt ảnh) mà là phao cho ca hoạt ảnh không bao giờ
    /// báo xong. Hạ nó xuống sát 0,3s là biến phao thành đồng hồ chạy đua với hoạt ảnh — đúng cái
    /// bẫy đã bị bắt ở review vòng 2: một cú nghẽn main-thread (dọn AVPlayer + tháo SceneKit +
    /// dựng lại List, đều xảy ra ngay sau khi lưu bản quét) đẩy hoạt ảnh trễ mà KHÔNG đẩy đồng hồ.
    private static let hideBackstop = 1.2

    /// Bật cover. Idempotent: đang có cover thì bỏ qua.
    ///
    /// ✗ có `onFailure` như khuôn present-bằng-UIKit (2.11/2.12): ở đó việc mở CÓ THỂ HỎNG (không
    /// tìm ra scene đang hiện) nên call site phải lật binding về false. Ghi vào một `@Published`
    /// thì không có nhánh hỏng nào để mà bắt — thêm tham số đó lại là dựng một closure KHÔNG BAO
    /// GIỜ chạy, đúng loại code chết mà repo này đã xoá một lần (biến `generation` của 2.11).
    @MainActor
    static func show<Content: View>(_ content: Content) {
        // 🔴 GUARD ĐỨNG TRƯỚC cú tăng `generation`, ✗ đảo lại: một lượt `show` bị nuốt mà vẫn đổi
        // thế hệ là đổi DANH TÍNH của cover ĐANG SỐNG ⇒ SwiftUI gỡ hẳn phiên quét đang chạy rồi
        // dựng lại từ đầu = mất trắng buổi quét.
        guard ScanCoverModel.shared.content == nil else { return }
        // 🔴 ✗ GỠ. Hạ bàn phím TRƯỚC khi phủ. Ca thật, rất dễ đi vào: khách gõ vào ô tìm kiếm ở
        // Home rồi bấm thẳng nút SCAN — bàn phím VẪN ĐANG MỞ lúc cover trượt lên, mà lớp phủ không
        // cướp first responder của ai cả. Bàn phím đó vẫn đội vùng an toàn dưới của cả cây view
        // ⇒ màn quét bị BÓP NGẮN suốt buổi, và khách không tắt được (cover nuốt hết cú chạm).
        // ✗ chữa bằng `.ignoresSafeArea(.keyboard)` cho cover: màn ĐẶT TÊN bản quét có ô nhập,
        // nó CẦN né bàn phím.
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
        // 🔴 TĂNG TRƯỚC khi ghi `content` — xem `ScanCoverModel.generation`.
        ScanCoverModel.shared.generation &+= 1
        ScanCoverModel.shared.blocksInput = true
        withAnimation(.easeOut(duration: showDuration)) {
            ScanCoverModel.shared.content = AnyView(content)
        }
    }

    /// Tắt cover rồi chạy `completion` SAU KHI trượt xong — đây là vai `onDismiss` của cover đời
    /// cũ, và luật 06/08 "mọi việc hậu-quét nằm ở onDismiss" giữ nguyên hiệu lực. Không có cover
    /// thì vẫn gọi `completion` (binding đã lật, việc hậu-quét vẫn phải chạy).
    ///
    /// 🔴 **HAI NGUỒN BẮN, CHẠY CÁI NÀO TỚI TRƯỚC, VÀ CHỈ MỘT LẦN — ✗ rút xuống còn một.**
    ///  · completion của CHÍNH hoạt ảnh = mốc ĐÚNG. Nó chạy theo ĐỒNG HỒ CỦA HOẠT ẢNH, nên một cú
    ///    nghẽn main-thread đẩy cả hai đi cùng nhau — khác hẳn một cái hẹn giờ cố định, thứ đứng
    ///    yên trong khi hoạt ảnh trôi về sau (bản đầu của 2.13 dính đúng lỗi đó).
    ///  · hẹn giờ `hideBackstop` = phao cho hướng MUỘN/KHÔNG BAO GIỜ. Thứ nằm trong `completion`
    ///    là đường "Đặt hàng ngay", "Quét thêm" và alert lỗi lưu — không nổ là mất đơn/mất bản
    ///    quét, IM LẶNG.
    /// ⚠ **Hướng còn lại — nổ SỚM — phao KHÔNG che được, và đừng cố che.** Apple ghi rõ: thay đổi
    /// nào không sinh hoạt ảnh thì completion chạy NGAY sau body. Nửa nguy hiểm của ca đó (bật lại
    /// cover khi cái cũ chưa gỡ xong) đã bị `generation` + `.id` nuốt; phần còn lại là `path.append`
    /// / alert chạy sớm một nhịp, chấp nhận. ✗ thêm "sàn thời gian tối thiểu" để chặn nốt — đó
    /// chính là cái đồng hồ đua với hoạt ảnh mà review vòng 2 đã giết.
    /// ⚠ `completionCriteria` để MẶC ĐỊNH (`.logicallyComplete`), ✗ đổi sang `.removed`: hai cái
    /// chỉ khác nhau với hoạt ảnh có đuôi rung (spring), mà đây là `.easeIn` — đổi thì không được
    /// gì, lại phải chờ MỌI hoạt ảnh khác bị gộp chung nhịp (đây là transaction ở tầng gốc).
    /// ⚠ Nhánh phao (1,2s) là nhánh "mọi thứ đã hỏng sẵn": nếu hoạt ảnh gỡ kẹt thật thì nhánh cover
    /// cũ còn nguyên trên cây, `onDisappear` của nó không chạy ⇒ `ARSession` + recorder cũ sống
    /// tiếp dưới phiên mới, `busyCount` kẹt ≥1. Chưa vá (xác suất rất thấp, và mọi cách vá đều đắt
    /// hơn rủi ro) — nhưng ai thấy hai `ARSession` cùng chạy thì tới đây tìm.
    ///
    /// 🔴 `content = nil` đặt NGAY (✗ chờ hết hoạt ảnh): nhánh "Quét thêm" bật cover lại từ trong
    /// `completion`, và `show` guard theo đúng biến này. Cú bật lại đó rơi trúng đuôi hoạt ảnh gỡ
    /// là chuyện BÌNH THƯỜNG — `ScanCoverModel.generation` lo phần đó, đọc chú thích ở đấy.
    @MainActor
    static func hide(completion: @escaping () -> Void) {
        guard ScanCoverModel.shared.content != nil else {
            // Không có cover thì cũng ✗ để cây dưới kẹt trạng thái bị chặn.
            ScanCoverModel.shared.blocksInput = false
            completion()
            return
        }
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            // Chỉ nhả chặn khi KHÔNG có cover mới — nhánh "Quét thêm" bật lại ngay trong
            // `completion()` ngay dưới, và nó tự đặt `blocksInput = true`.
            if ScanCoverModel.shared.content == nil {
                ScanCoverModel.shared.blocksInput = false
            }
            completion()
        }
        withAnimation(.easeIn(duration: hideDuration)) {
            ScanCoverModel.shared.content = nil
        } completion: {
            finish()
        }
        // Closure tường minh chứ ✗ `execute: finish` — tham số đó khai `@convention(block)`, và
        // máy này không compile được để thử phép chuyển kiểu ngầm.
        DispatchQueue.main.asyncAfter(deadline: .now() + hideBackstop) {
            finish()
        }
    }
}

/// Hộp chứa nội dung cover. MỘT thể hiện duy nhất; `.scanCoverLayer()` quan sát nó.
///
/// ⚠ Là `class` chia sẻ chứ ✗ `@State` của một màn, vì cover có HAI chủ (`HomeView` và
/// `ProjectView`) và phải sống ở tầng cao hơn cả hai — xem lý do "thanh tab vẽ đè" ở `ScanCover`.
final class ScanCoverModel: ObservableObject {
    static let shared = ScanCoverModel()
    /// nil = không có cover. `fileprivate(set)`: chỉ `ScanCover` (cùng file) được ghi, để hai đường
    /// bật/tắt luôn đi kèm hoạt ảnh + lịch chạy `completion`.
    @Published fileprivate(set) var content: AnyView?
    /// 🔴 **SỐ THẾ HỆ — DANH TÍNH của nhánh cover (`.id(...)`). ✗ GỠ, ✗ đổi thành hằng.**
    /// Không có nó thì mọi phiên quét dùng CHUNG một chỗ trong ZStack và chung một kiểu view, nên
    /// khi "Quét thêm" bật cover lại đúng lúc hoạt ảnh gỡ chưa xong, SwiftUI **quay ngược cú gỡ và
    /// DÙNG LẠI view cũ**: `@StateObject controller` + `@State savedRecord` của phiên trước còn
    /// nguyên ⇒ khách thấy lại màn preview của bản quét vừa lưu thay vì phiên quét mới, `onAppear`
    /// không bắn nên `startSession()` không chạy, và `onDisappear` của phiên cũ không bao giờ chạy
    /// (mất `endBusy` + `controller.cancel()`). Đổi danh tính là ép SwiftUI GỠ HẲN cái cũ rồi
    /// DỰNG MỚI — hai vế `onAppear`/`onDisappear` lại cân bằng.
    /// ⚠ Cố ý KHÔNG `@Published`: nó luôn đổi CÙNG NHỊP với `content` (và trước `content`), nên
    /// lượt vẽ lại do `content` kích hoạt đã đọc được giá trị mới. Khai `@Published` chỉ thêm một
    /// lượt vẽ thừa. Ai tách hai cú ghi đó ra thì phải khai `@Published`.
    fileprivate(set) var generation = 0
    /// 🔴 **CHẶN CHẠM + CHẶN VoiceOver CHO CÂY BÊN DƯỚI. CỜ RIÊNG, ✗ suy ra từ `content != nil`.**
    /// Vòng đời của nó DÀI HƠN `content`: `hide` đặt `content = nil` NGAY ở nhịp đầu trong khi
    /// cover còn nằm trên màn hình thêm 0,3s nữa. Suy từ `content` là suốt 0,3s trượt xuống, phần
    /// màn hình vừa lộ ra (thanh điều hướng, ô tìm kiếm, mấy dòng dự án đầu) đã bấm được — trong
    /// khi ngón tay khách vừa bấm xong một nút và còn đang di chuyển. Ca thật: bấm "Đặt hàng ngay"
    /// → cover trượt xuống → tay chạm trúng một dòng dự án → màn đó bị ĐẨY, rồi 0,3s sau việc
    /// hậu-quét đẩy tiếp màn đặt hàng lên trên nó ⇒ khách bấm Back về một chỗ họ chưa từng đi qua.
    /// Nhả ở `hide`, trong `finish` (xem ở đó).
    @Published fileprivate(set) var blocksInput = false
}

extension View {
    /// Gắn lớp phủ cover quét LÊN TRÊN toàn bộ cây view.
    ///
    /// 🔴 CHỖ GẮN DUY NHẤT LÀ `CedarScanApp` — ✗ gắn thêm ở màn nào khác (hai lớp phủ cùng đọc một
    /// `ScanCoverModel` là vẽ cover hai lần) và ✗ dời xuống thấp hơn `RootView` (thanh tab +
    /// thanh điều hướng sẽ vẽ đè lên cover).
    func scanCoverLayer() -> some View {
        modifier(ScanCoverLayerModifier())
    }
}

struct ScanCoverLayerModifier: ViewModifier {
    @ObservedObject private var model = ScanCoverModel.shared

    func body(content: Content) -> some View {
        ZStack {
            content
                // 🔴 ✗ GỠ. Lớp phủ chặn ngón tay nhưng KHÔNG chặn VoiceOver: thiếu dòng này thì
                // người dùng VoiceOver vuốt xuyên qua cover xuống danh sách bản quét/thanh tab
                // phía sau. Cùng họ bẫy #10 đã trả giá hai lần bên trong chính `MeshScanFlowView`.
                .accessibilityHidden(model.blocksInput)
                // 🔴 ✗ GỠ, và ✗ đổi thành `.disabled(...)`. Suốt hai lượt trượt, cover CHƯA che
                // kín màn hình — phần lộ ra vẫn bấm được (xem `blocksInput` để biết ca thật).
                // Presentation của UIKit tự khoá màn dưới; lớp phủ phải khai tay.
                // `.disabled` LÀ SAI Ở ĐÂY dù nó chặn được nhiều hơn (với tới cả `.toolbar` mà
                // SwiftUI đẩy ra thanh điều hướng): nó lật `isEnabled` nên MỌI nút phía sau XÁM
                // ĐI — mà cú lật đó nằm trong `withAnimation` của `show`, tức cả màn phía sau
                // chuyển xám dần trong 0,35s NGAY TRƯỚC MẮT khách, mỗi lần mở màn quét. Review
                // đối kháng vòng 2 bắt. `.allowsHitTesting` không đổi hình vẽ dòng nào.
                .allowsHitTesting(!model.blocksInput)
            if let cover = model.content {
                ZStack {
                    // Nền ĐỤC — ✗ gỡ, kể cả khi "màn quét tự có camera che kín rồi". Hai đường
                    // alert (máy không LiDAR / camera bị từ chối) không bao giờ chạy camera, và
                    // suốt lúc trượt lên thì camera chưa có khung hình nào.
                    Color(uiColor: .systemBackground)
                        .ignoresSafeArea()
                    cover
                }
                // Danh tính theo thế hệ — đọc `ScanCoverModel.generation` trước khi đụng.
                .id(model.generation)
                // VoiceOver: `.accessibilityHidden` ở trên KHÔNG với tới thanh điều hướng — SwiftUI
                // đẩy `.toolbar`/`.searchable` ra `UINavigationBar` của UIKit, ngoài cây con đó.
                // Đường thật đã lần ra được: menu "…" → "Xóa dự án" của `ProjectView` (hàm xoá CỐ Ý
                // không gác `isBusy`) ⇒ xoá dự án GIỮA buổi quét → `ProjectView` tự pop → cover mất
                // đường đóng, kẹt vĩnh viễn. `.isModal` là thứ bảo VoiceOver bỏ qua mọi thứ NGOÀI
                // container này, bất kể ai vẽ chúng. (Vế NGÓN TAY của đúng đường đó vá ở chính chỗ
                // item toolbar — xem `.disabled(isMeshScanning)` trong `ProjectView`.)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
                // 🔴 `.transition` + `.zIndex` để NGOÀI CÙNG, ✗ nhét vào giữa chuỗi. Cả hai là
                // "trait" truyền ra ngoài qua từng lớp modifier; không có gì bảo đảm mấy modifier
                // accessibility giữ nguyên trait khi truyền tiếp. Nếu trait rơi mất thì triệu
                // chứng ĐÚNG BẰNG cái bug vừa vá (cover trượt xuống ở lớp dưới màn Home), và sẽ bị
                // đổ oan cho chỗ khác. Để ngoài cùng thì không có gì chen vào được.
                //
                // 🔴 `.offset(y: travel)` chứ ✗ `.move(edge: .bottom)`. Khung layout của nhánh này
                // là vùng AN TOÀN (763pt trên iPhone 12 Pro), trong khi nền + view camera bên
                // trong đều `.ignoresSafeArea()` nên chúng vẽ tràn ra 47pt trên + 34pt dưới.
                // `.move` chỉ dịch đúng CHIỀU CAO KHUNG ⇒ ở trạng thái "đã ra ngoài" vẫn còn một
                // dải đục 81pt nằm đè lên thanh tab, hiện/biến mất trong một khung hình — nháy
                // đúng chỗ đĩa Scan. Trượt theo chiều cao CỬA SỔ mới ra khỏi màn hình thật, đúng
                // như hoạt ảnh của 2.11/2.12. (Review đối kháng 12/08.)
                .transition(.offset(y: travel))
                // 🔴 ✗ GỠ, và ✗ đổi về hằng `1`. Lúc GỠ nhánh khỏi ZStack, SwiftUI không còn thứ
                // tự khai báo để dựa vào; thiếu zIndex thì cover trượt xuống ở lớp DƯỚI màn Home.
                // Lấy theo THẾ HỆ (luôn tăng, luôn > 0 = lớp của cây bên dưới) để ca "Quét thêm"
                // — cover cũ đang trượt xuống, cover mới đã trượt lên — có thứ tự XÁC ĐỊNH: cái
                // mới luôn nằm trên. Hai nhánh cùng `zIndex(1)` thì SwiftUI xếp lớp tuỳ ý, ra một
                // đường ráp nham nhở ngay sau khi lưu bản quét (review đối kháng vòng 2).
                .zIndex(Double(model.generation))
            }
        }
    }

    /// Quãng đường trượt = chiều cao CỬA SỔ (✗ chiều cao khung layout) — xem chú thích ở
    /// `.transition`. Cùng cách đo với hoạt ảnh của `ScanCoverPresenter` đời 2.12 (`bounds` của
    /// cửa sổ, phao là `screen.bounds`): `bounds` có thể còn 0 ở lượt layout đầu tiên, và trượt 0
    /// là KHÔNG có hoạt ảnh.
    ///
    /// 🔴 **THIẾU thì để lại dải đục; DƯ thì KHÔNG mất gì** (`.offset` không cắt xén, và 64pt trên
    /// 0,35s mắt không thấy). Nên cộng biên và nên để phao CAO: phao cũ 1000 còn thấp hơn cửa sổ
    /// iPad dựng đứng (11" = 1194, 12,9" = 1366) — đúng cái bệnh đang chữa, trên máy to nhất.
    private var travel: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        let windowHeight = scene?.keyWindow?.bounds.height ?? 0
        if windowHeight > 0 { return windowHeight + 64 }
        return (scene?.screen.bounds.height ?? 1400) + 64
    }
}
