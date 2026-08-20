import SwiftUI

/// Mục **"Hỏi đáp về đơn hàng"** của tab Learn — chủ app đặt 19/08:
/// *"thêm 1 mục hướng dẫn đơn hàng kiểu q&a về đơn hàng … nói chung là tất cả câu hỏi về cách
/// đặt hàng và các mẹo"*.
///
/// 🔴🔴 **MỌI CÂU TRẢ LỜI Ở ĐÂY PHẢI ĐO ĐƯỢC TRONG CODE, ✗ VIẾT CHO XUÔI TAI.** Đây là văn bản
/// app HỨA với khách, và một câu hứa sai ở đây đi thẳng ra tiền: khách đọc "được X" rồi không
/// thấy X thì hoặc khiếu nại, hoặc chủ app phải làm không công. Sửa luồng đặt hàng thì phải soi
/// lại file này. Nguồn của từng con số, để người sau kiểm chứ khỏi phải tin:
///  · "12 giờ" + "5.000 sq ft (464 m²)" của Express — khối `footer` của mục Add-ons trong
///    `ScanDetailView`;
///  · "1–3 ảnh mỗi phòng" của Virtual Tour — cùng khối footer đó;
///  · "tối đa 10 file" của Yêu cầu sửa — `OrdersView.maxFiles` (form đặt hàng cũng 10:
///    `ScanDetailView.maxOrderFiles`);
///  · "1 dự án 1 đơn" — `ScanStore.orderNumber(ofProject:)`, lời chốt của chủ app 11/08;
///  · 🔴 "bản quét bổ sung KHÔNG BAO GIỜ tính thêm phí" — **LỜI CHỐT CỦA CHỦ APP**, nguyên văn
///    11/08: *"ok cứ để miễn phí hết, hiện tại chỉ tính order không tính diện tích"* (§QUYẾT ĐỊNH
///    mục 5 của `PLAN-GUI-BO-SUNG-BAN-QUET.md`), và ông XÁC NHẬN LẠI 19/08: *"đơn đã đặt hay đã
///    giao thì khi khách quét bổ sung vẫn không tính phí"*. Code khớp: `SupplementSheet` KHÔNG chạm
///    `catalog()`, không bảng giá, không link thanh toán; `OrderSheet.totalUSD` không có số hạng nào
///    nhân theo số bản quét.
///    ⚠⚠ **`LegalDoc.terms` mục "Revisions" ĐANG NÓI NGƯỢC LẠI** — nó viết *"ask us to draw an area
///    your scan does not cover … are new work and are quoted as such"*. Đó là văn bản có hiệu lực
///    pháp lý VÀ đã sinh ra trang công khai `cedar247.com/cedarscan-terms/`. **VIỆC CÒN TỒN, ĐÃ BÁO
///    CHỦ APP 19/08** — sửa Điều khoản là việc của ông (kéo theo sinh lại 3 trang web). ✗ ai đọc Điều
///    khoản rồi "sửa lại" file này cho khớp: **quyết định của chủ app mới là nguồn.**
///    ⚠ TRỎ THEO `id` CỦA MỤC, ✗ theo câu hỏi: câu chữ đã đổi một lần (20/08, đổi giọng văn)
///    và mọi chú thích trích nguyên văn câu hỏi đều lạc hậu theo.
///    ✅ **LỔ HỔNG ĐÃ VÁ 19/08** — trước đó đơn ĐÃ GIAO không có đường nào gửi bản quét mới
///    (server trả `order_delivered`, mà `RevisionSheet` chỉ nhận `[.image, .pdf]` nên gói mesh
///    40–200MB không đi qua được). Nay `supplement-scan` NHẬN đơn đã giao và kéo thẻ `done → fix`.
///    🔴🔴 **RÀNG BUỘC GIAO HÀNG: ✗ ĐƯA IPA 2.28 CHO CHỦ APP TRƯỚC KHI THAY ĐỔI SERVER ĐÃ LÊN
///    PROD.** Hai mục FAQ bên dưới ("đã giao rồi vẫn gửi được") nói đúng với server MỚI; server cũ
///    vẫn trả `order_delivered` ⇒ app vẫn xử đúng (mở `RevisionSheet`) nhưng VĂN BẢN NÓI SAI.
///    Trạng thái deploy ghi ở `C:\\Block\\order-webapp\\HANDOFF.md` §1;
///  · suất miễn phí tính theo CẢ tài khoản LẪN thiết bị — `LegalDoc`, mục định danh thiết bị;
///  · tên bốn trạng thái đơn — `OrdersView.StatusBadge`;
///  · email liên hệ — `LegalDoc.contactEmail`, ✗ gõ lại chuỗi email vào đây.
///    🔴 KIỂU TÊN LÀ `LegalDoc`, ✗ `LegalView` — `LegalView.swift` chỉ là TÊN FILE, trong đó khai
///    `enum LegalDoc`. Bản nháp đầu của file này viết `LegalView.contactEmail` và đó là lỗi
///    "cannot find in scope", tức một lượt CI chết. Vòng soi đối kháng bắt được, ✗ trình biên dịch.
///
/// 🔴🔴 **ĐỊNH DẠNG FILE GIAO NẰM Ở BA CHỖ, ✗ MỘT — ĐỔI CHÍNH SÁCH THÌ PHẢI SỬA CẢ BA:**
///  (1) mục `id: "formats"` trong file này (dời từ footer mục "Giới thiệu" của
///      `AccountView` sang, ngày 19/08, khi chủ app cho xoá dòng đó);
///  (2) **`LegalDoc.terms` — mục "The service"** đã liệt kê đủ y hệt, và đó là bản có HIỆU LỰC
///      PHÁP LÝ (nó còn được sinh ra ba trang web công khai trên cedar247.com);
///  (3) **`HUONG-DAN.md` — bảng ở mục "Bạn nhận được định dạng nào"**, sổ tay chủ app gửi KHÁCH.
/// (Vòng soi 19/08 đếm nhầm "hai" ở lượt đầu rồi vòng hai bắt ra chỗ thứ ba. Đếm lại trước khi tin.)
/// ⚠ Chú thích cũ ở `AccountView` dặn "đây là chỗ DUY NHẤT" — **câu đó vốn đã SAI** từ khi văn bản
/// pháp lý ra đời; vòng soi đối kháng 19/08 bắt được. ✗ chép lại lời dặn sai đó.
/// Cả hai chỗ phải giữ đúng chính sách chốt 2026-07-20: mặc định PDF + JPG · SVG/PNG khi khách
/// yêu cầu · "CAD File" (DWG) là add-on TÍNH TIỀN. Gộp DWG vào như thể đã bao gồm là lỗi đã trả giá.
///
/// ⚠ **TÊN ADD-ON TRONG CÁC CÂU TRẢ LỜI ("Express", "Virtual Tour", "CAD File") DO SERVER TRẢ VỀ**
/// (`CatalogAddon.name`, bảng `AppSetting["scan-catalog"]`), ✗ nằm trong code app. Server đổi tên
/// là FAQ tự lạc hậu trong im lặng, không CI nào bắt được (đã đổi một lần: "CAD file (DWG)" →
/// "CAD File", 13/08). Đổi tên add-on bên `order-webapp` thì soi lại file này.
///
/// 🔴 **CÂU CHỮ QUANH THANH TOÁN PHẢI TRUNG TÍNH** — mở đầu điều 3.1.3 của App Store cấm
/// "khuyến khích khách dùng cách thanh toán khác IAP". ✗ viết "rẻ hơn khi mua trên web", ✗ "tránh
/// phí App Store". Chỉ mô tả việc đang xảy ra: bấm nút thì trang thanh toán mở ra. Cùng lý do:
/// ✗ hứa **xem** được bản vẽ trong app (ràng buộc số (1) ở §App Store của SESSION-HANDOFF) —
/// file thành phẩm mở bằng TRÌNH DUYỆT, và câu ở đây phải nói đúng như vậy.
///
/// Dựng từ MẢNG DỮ LIỆU + `ForEach` chứ ✗ viết thẳng 17 `DisclosureGroup` vào body: repo này đã
/// chết "Swift type-check timeout" trên CI vì biểu thức SwiftUI lớn (xem `OrdersView.filterChip`,
/// `HomeView.projectRow`). Mỗi nhóm là một `static let` riêng, cùng lý do.
struct OrderFAQContent: View {
    struct FAQItem: Identifiable {
        let id: String
        let question: String
        let answer: String
    }

    struct FAQGroup: Identifiable {
        let id: String
        let title: String
        let items: [FAQItem]
    }

    var body: some View {
        List {
            ForEach(Self.groups) { group in
                Section {
                    ForEach(group.items) { item in
                        row(item)
                    }
                } header: {
                    Text(group.title)
                }
            }
            bottomSpacer
        }
    }

    /// 🔴 CHỖ CHỪA CHO THANH TAB TỰ VẼ. Màn này được **PUSH** trong `NavigationStack` của tab
    /// Learn, mà `CedarTabBar` gắn bằng `.safeAreaInset` trên **TabView** — vùng an toàn đó KHÔNG
    /// chảy tới màn push (lý do đầy đủ ở `CedarTabBar.reservedHeight`; chủ app đã gặp đúng lỗi này
    /// một lần: *"nút Quét bổ sung bị che"*). Thiếu dòng này thì mục cuối cùng nằm dưới thanh tab
    /// và **cuộn xuống cũng không thấy được** — cuộn đã hết cỡ rồi.
    ///
    /// Làm bằng một hàng `List` trong suốt chứ ✗ `.safeAreaInset` thứ hai: `safeAreaInset` LỒNG
    /// nhau vẫn đang nằm trong danh sách nghi can chưa vá của §LỖI ĐÈ CHỮ, ✗ mời nó vào một màn
    /// mới toanh chỉ để chừa chỗ trống.
    private var bottomSpacer: some View {
        Color.clear
            .frame(height: CedarTabBar.reservedHeight)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    /// 🔴 **✗ DÙNG `**…**` HAY BẤT KỲ CÚ PHÁP MARKDOWN NÀO TRONG `answer`.** `item.answer` là một
    /// `String` (biến, ✗ string literal) nên `Text(_:)` bắt overload `init<S: StringProtocol>` —
    /// overload đó in NGUYÊN VĂN, không phân tích Markdown. Chỉ `Text(LocalizedStringKey)` (tức
    /// truyền THẮNG một string literal) mới hiểu `**…**`. Bản nháp 19/08 dùng in đậm ở mục
    /// "delivered" và vòng soi đối kháng bắt được: khách sẽ đọc ra bốn cụm dấu sao nằm giữa câu.
    /// Muốn nhấn thì dùng CHỮ HOA hoặc tách dòng, ✗ Markdown.
    ///
    /// Một câu hỏi. GẬP LẠI mặc định — mở màn ra là thấy toàn bộ danh sách câu hỏi trong một màn
    /// hình, thay vì một bức tường chữ phải cuộn mãi mới biết ở đây có những mục gì.
    private func row(_ item: FAQItem) -> some View {
        DisclosureGroup {
            Text(item.answer)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } label: {
            Text(item.question)
                .font(.subheadline.weight(.semibold))
        }
    }

    static let groups: [FAQGroup] = [
        orderingGroup,
        supplementGroup,
        afterOrderGroup,
        tipsGroup,
    ]

    // MARK: - Đặt hàng
    //
    // 🔴 GIỌNG VĂN: **khách hỏi "Tôi…", app trả lời "Bạn…"** — chủ app chốt 20/08 sau khi
    // đọc bản đầu: *"thấy viết cứng quá … nên đóng vai là khách hàng và đặt câu hỏi"*, và
    // *"nên ngắn gọn thôi, toàn chữ là chữ"*.
    // ⇒ Câu hỏi viết ở ngôi THỨ NHẤT, trả lời xưng "bạn", mỗi câu trả lời **2–4 câu ngắn**.
    // ✗ viết lại thành văn phong tài liệu ("Khách hàng có thể…", "Hệ thống sẽ…").
    // ⚠ Ngắn chứ ✗ ĐƠN GIẢN HOÁ: mọi con số và điều kiện ở khối chú thích đầu file vẫn phải còn
    // đủ — cắt mất một vế điều kiện là quay về đúng lớp lỗi "hứa sai ra tiền" đã trả giá.

    private static let orderingGroup = FAQGroup(
        id: "ordering",
        title: L.t("Ordering", "Đặt hàng"),
        items: [
            FAQItem(
                id: "how",
                question: L.t("How do I order a floor plan?", "Tôi muốn đặt bản vẽ mặt bằng, làm thế nào?"),
                answer: L.t(
                    """
                    1. Scan the property, then open it and tap "Order Floor Plan".
                    2. Sign in if the app asks. Your email has to be verified before an order goes through.
                    3. Pick a package, switch on any add-ons, write a note.
                    4. Tap "Place order". Use Wi-Fi and leave the app open until your order number appears — your scan is a big upload.
                    5. Tap "Pay Now". We start drawing once the payment lands.
                    """,
                    """
                    1. Quét xong, bạn mở dự án rồi bấm "Đặt làm mặt bằng".
                    2. App hỏi thì đăng nhập. Tài khoản cần xác minh email thì đơn mới đi được.
                    3. Chọn gói, bật thêm dịch vụ nếu cần, viết ghi chú.
                    4. Bấm "Đặt hàng". Dùng Wi-Fi và để app mở tới khi số đơn hiện ra nhé — bản quét khá nặng.
                    5. Bấm "Thanh toán ngay". Nhận được tiền là đội ngũ bắt đầu vẽ.
                    """
                )
            ),
            FAQItem(
                id: "floors",
                question: L.t("My house has several floors — how does that work?",
                              "Nhà tôi nhiều tầng thì sao?"),
                answer: L.t(
                    "Keep them all in one property. Scanning the whole house in a single pass is best — keep scanning as you walk up the stairs. If it is too big for one go, split it into several scans; as long as they sit in the same property they go into one order.",
                    "Bạn cứ để chung một dự án. Quét liền một mạch cả nhà là đẹp nhất — vừa quét vừa đi lên cầu thang. Nhà lớn quá thì chia làm nhiều bản quét cũng được, miễn cùng một dự án là chúng đi chung một đơn."
                )
            ),
            FAQItem(
                id: "one-order",
                question: L.t("Do I need one order per floor?", "Tôi có phải đặt mỗi tầng một đơn không?"),
                answer: L.t(
                    "No — one house, one order. Once you have ordered, later scans go into that same order through \"Send extra scan\", and they never cost extra: the price is per order, not per scan.",
                    "Không — một căn nhà một đơn thôi. Đặt rồi thì bản quét sau đi vào đúng đơn đó qua nút \"Gửi bổ sung bản quét\", và không tính thêm tiền — giá tính theo đơn chứ không theo số bản quét."
                )
            ),
            FAQItem(
                id: "free",
                question: L.t("Do I get a free order?", "Tôi có được đơn miễn phí nào không?"),
                answer: L.t(
                    "New customers get their first few orders free. When yours qualifies the button reads \"FREE 🎁\" and the form shows how many you have left. The allowance counts per account and per phone, so a new account on the same phone will not give you more.",
                    "Khách mới được vài đơn đầu miễn phí. Đơn của bạn được thì nút đặt hàng ghi \"MIỄN PHÍ 🎁\" và form hiện số lượt còn lại. Suất này tính theo cả tài khoản lẫn máy, nên lập tài khoản mới trên cùng một máy cũng không thêm lượt đâu."
                )
            ),
            FAQItem(
                id: "price",
                question: L.t("How much will I pay?", "Tôi phải trả bao nhiêu?"),
                answer: L.t(
                    "Exactly what the \"Place order\" button says: the packages plus the add-ons you picked. A coupon comes off on the payment page, so the button still shows the full price. Very large homes can carry a surcharge — the app cannot measure floor area, so we work that out afterwards and always tell you before charging it.",
                    "Đúng con số trên nút \"Đặt hàng\": gói cộng dịch vụ thêm bạn chọn. Mã giảm giá được trừ ở trang thanh toán nên nút vẫn hiện giá đầy đủ. Nhà rất lớn có thể có phụ phí — app không tự đo được diện tích nên khoản đó tính sau, và luôn báo bạn trước khi thu."
                )
            ),
            FAQItem(
                id: "coupon",
                question: L.t("I have a coupon — where do I put it?", "Tôi có mã giảm giá, nhập ở đâu?"),
                answer: L.t(
                    "In the \"Coupon code\" box near the bottom of the order form. The discount comes off on the payment page, so do not worry when the button still shows full price. If the code turns out to be invalid, the screen right after ordering tells you.",
                    "Ô \"Mã giảm giá\" gần cuối form đặt hàng. Mức giảm áp ở trang thanh toán, nên nút vẫn hiện giá đầy đủ thì bạn đừng lo. Mã không hợp lệ thì màn hình ngay sau khi đặt sẽ báo bạn."
                )
            ),
            FAQItem(
                id: "addons",
                question: L.t("I keep seeing Express and Virtual Tour — what are they?",
                              "Tôi thấy có Express với Virtual Tour, là gì vậy?"),
                answer: L.t(
                    "Two add-ons in the order form. Express gets your drawing back within 12 hours — not available for homes over 5,000 sq ft (464 m²). With Virtual Tour you add 1–3 photos per room after ordering; we pin them on your floor plan and send you a tour link you can share.",
                    "Hai dịch vụ thêm trong form. Express giao trong 12 giờ — không áp dụng cho nhà trên 5.000 sq ft (464 m²). Virtual Tour thì sau khi đặt bạn thêm 1–3 ảnh mỗi phòng, chúng tôi ghim lên mặt bằng và gửi bạn link tour chia sẻ được."
                )
            ),
        ]
    )

    // MARK: - Quét thiếu

    private static let supplementGroup = FAQGroup(
        id: "supplement",
        title: L.t("Missed an area", "Quét thiếu"),
        items: [
            FAQItem(
                id: "missed",
                question: L.t("I missed part of the house — what now?",
                              "Tôi quét sót mất một khu, giờ sao?"),
                answer: L.t(
                    "Just scan it. There is no extra charge, even after your drawing has been delivered. Open the property, tap \"Scan more\", scan what you missed, then tap \"Send extra scan\". You can also start from the Orders tab — tap \"Add a scan\" and we take you to the right property. Please do not place a second order.",
                    "Bạn cứ quét thêm. Không mất phí, kể cả khi đơn đã giao. Mở dự án, bấm \"Quét bổ sung\", quét phần còn thiếu rồi bấm \"Gửi bổ sung bản quét\". Đi từ tab Đơn hàng cũng được — bấm \"Thêm bản quét\" là app đưa bạn sang đúng dự án. Đừng đặt đơn thứ hai nhé."
                )
            ),
            FAQItem(
                id: "delivered",
                question: L.t("Can I still change things after I get the drawing?",
                              "Nhận bản vẽ rồi tôi vẫn sửa được chứ?"),
                answer: L.t(
                    "Yes. If the drawing is wrong somewhere you did scan, go to Orders, tap \"Request a revision\", say what to change and attach a marked-up photo or PDF (up to 10 files). Our mistakes are fixed free, within 90 days of delivery and up to three times per order. If you simply missed an area, send the new scan as usual — still free. We draw it in and send you an updated drawing; meanwhile the old download link pauses. Wanting something different from what you ordered — another package or add-on — is new work, and we quote that separately.",
                    "Được. Bản vẽ sai ở khu bạn đã quét thì vào tab Đơn hàng, bấm \"Yêu cầu sửa\", nói rõ chỗ cần sửa và đính ảnh hoặc PDF đánh dấu (tối đa 10 file). Lỗi bên chúng tôi thì sửa miễn phí, trong 90 ngày kể từ ngày giao và tối đa 3 lần mỗi đơn. Còn nếu bạn quét sót hẳn một khu thì cứ gửi bổ sung như bình thường, vẫn miễn phí — chúng tôi vẽ thêm rồi gửi lại bản cập nhật, trong lúc đó link tải bản cũ tạm ngưng. Còn muốn thứ khác với đơn ban đầu — đổi gói, thêm dịch vụ — thì đó là công mới, chúng tôi báo giá riêng."
                )
            ),
            FAQItem(
                id: "quality",
                question: L.t("The app says my scan is low quality — does that matter?",
                              "App báo bản quét của tôi chất lượng thấp?"),
                answer: L.t(
                    "You can still order and we will be told in advance, but rescanning that floor usually gives you a more accurate drawing. If the scan screen shows an orange line saying no 3D model was captured, please do scan that area again — we cannot draw a floor plan from video alone.",
                    "Bạn vẫn đặt được và đội ngũ sẽ được báo trước, nhưng quét lại tầng đó thường cho bản vẽ chính xác hơn. Còn nếu màn bản quét hiện dòng cam báo chưa thu được mô hình 3D thì bạn quét lại khu đó giúp nhé — chỉ có video thì chúng tôi không dựng được mặt bằng."
                )
            ),
        ]
    )

    // MARK: - Thanh toán và nhận hàng

    private static let afterOrderGroup = FAQGroup(
        id: "after",
        title: L.t("Payment and delivery", "Thanh toán và nhận hàng"),
        items: [
            FAQItem(
                id: "pay",
                question: L.t("Where do I pay?", "Tôi thanh toán ở đâu?"),
                answer: L.t(
                    "Tap \"Pay Now\" — on the screen right after you order, or in the Orders tab. It opens the payment page in your browser. No button yet? Give it a few minutes; the link reaches your email.",
                    "Bạn bấm \"Thanh toán ngay\" — ở màn hình ngay sau khi đặt, hoặc ở tab Đơn hàng. Nút mở trang thanh toán bằng trình duyệt. Chưa thấy nút thì đợi vài phút, link sẽ tới email của bạn."
                )
            ),
            FAQItem(
                id: "track",
                question: L.t("How do I follow my order?", "Tôi theo dõi đơn ở đâu?"),
                answer: L.t(
                    "The Orders tab. Each order carries a badge — Processing, On hold, Delivered or Refunded. The search box finds an order by number or by scan name.",
                    "Tab Đơn hàng. Mỗi đơn có một nhãn — Đang xử lý, Tạm giữ, Đã giao hoặc Hoàn tiền. Ô tìm kiếm tìm được theo số đơn hoặc tên bản quét."
                )
            ),
            FAQItem(
                id: "formats",
                question: L.t("What files do I get?", "Tôi nhận được file gì?"),
                answer: L.t(
                    "PDF and JPG by default. Want SVG or PNG instead? Just say so in the \"Note\" box when you order. \"CAD File\" (DWG) is a paid add-on — switch it on under Add-ons.",
                    "Mặc định là PDF và JPG. Cần SVG hay PNG thì bạn ghi vào ô \"Ghi chú\" lúc đặt. \"CAD File\" (DWG) là dịch vụ thêm có tính tiền, bạn bật ở mục Dịch vụ thêm."
                )
            ),
            FAQItem(
                id: "download",
                question: L.t("Where do I download my drawing?", "Tôi tải bản vẽ ở đâu?"),
                answer: L.t(
                    "Orders tab — on an order marked \"Delivered\", tap \"Download deliverables\", or tap a single file in the list. The link opens in your browser and the file lands wherever your browser keeps downloads.",
                    "Tab Đơn hàng — đơn nào có nhãn \"Đã giao\" thì bạn bấm \"Tải file thành phẩm\", hoặc bấm thẳng từng file. Link mở bằng trình duyệt, file về đúng chỗ trình duyệt hay lưu."
                )
            ),
            FAQItem(
                id: "cancel",
                question: L.t("I want to cancel or get a refund", "Tôi muốn huỷ đơn hoặc hoàn tiền"),
                answer: L.t(
                    "There is no cancel button in the app. Write to \(LegalDoc.contactEmail) with your order number and we will sort it out. The full terms are in the Account tab, under Legal & Privacy.",
                    "App không có nút huỷ. Bạn viết cho \(LegalDoc.contactEmail) kèm số đơn nhé. Điều khoản đầy đủ ở tab Tài khoản, mục Legal & Privacy."
                )
            ),
        ]
    )

    // MARK: - Mẹo

    private static let tipsGroup = FAQGroup(
        id: "tips",
        title: L.t("Tips", "Mẹo"),
        items: [
            FAQItem(
                id: "tips-order",
                question: L.t("How do I get the drawing I actually want?",
                              "Làm sao để bản vẽ đúng ý tôi?"),
                answer: L.t(
                    """
                    • Name each scan from the list the app offers (Main floor, Basement, Garage…). Our team assembles the house from those names.
                    • The clearer your note, the less there is to revise.
                    • Got an old drawing or a logo? Attach it while ordering.
                    • Set units and language the first time — we remember them for you.
                    • The address you type before scanning is the one on the order.
                    """,
                    """
                    • Đặt tên bản quét theo đúng tên app gợi ý (Main floor, Basement, Garage…). Đội vẽ ghép nhà theo mấy cái tên đó, bạn đừng dịch sang tiếng Việt.
                    • Ghi chú càng rõ thì càng ít phải sửa.
                    • Có bản vẽ cũ hay logo thì đính kèm luôn lúc đặt.
                    • Chọn đơn vị đo và ngôn ngữ ngay từ đầu — app nhớ cho bạn lần sau.
                    • Địa chỉ bạn nhập trước khi quét chính là địa chỉ trên đơn.
                    """
                )
            ),
            FAQItem(
                id: "help",
                question: L.t("I need a hand", "Tôi cần người hỗ trợ"),
                answer: L.t(
                    "Write to \(LegalDoc.contactEmail). If it is about one particular order, add the order number and we will be quicker.",
                    "Bạn viết cho \(LegalDoc.contactEmail) nhé. Hỏi về một đơn cụ thể thì kèm số đơn cho nhanh."
                )
            ),
        ]
    )
}
