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
///  (1) mục *"Tôi nhận được những file gì?"* trong file này (dời từ footer mục "Giới thiệu" của
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

    private static let orderingGroup = FAQGroup(
        id: "ordering",
        title: L.t("Placing an order", "Đặt hàng"),
        items: [
            FAQItem(
                id: "how",
                question: L.t("How do I place an order?", "Làm thế nào để đặt hàng?"),
                answer: L.t(
                    """
                    1. Scan the property: tap the round Scan button in the middle of the bottom bar, type the address, then scan. Walk through every room you want on the drawing.
                    2. Open the property (or the scan you just saved) and tap "Order Floor Plan".
                    3. If you are not signed in the app opens the sign-in screen right there. Your account also has to be verified by email before an order goes through, so verify early — it saves a wasted upload.
                    4. In the form: pick a package (you can pick more than one), switch on any add-ons, choose units and drawing language, and write a note.
                    5. Tap "Place order". The scan has to reach our servers before the order exists — the 3D mesh plus the video, often tens to hundreds of megabytes — so use Wi-Fi and leave the app open until your order number appears. (Depending on which screen you came from, the upload may already have run before the form opened.)
                    6. Tap "Pay Now" to open the payment page. Our team starts once payment is received.
                    """,
                    """
                    1. Quét căn nhà: bấm nút Scan tròn ở giữa thanh dưới, nhập địa chỉ rồi quét. Đi qua mọi phòng bạn muốn có trên bản vẽ.
                    2. Mở dự án (hoặc bản quét vừa lưu) rồi bấm "Đặt làm mặt bằng".
                    3. Chưa đăng nhập thì app mở màn đăng nhập ngay tại chỗ. Tài khoản còn phải xác minh email thì đơn mới đi được, nên xác minh sớm — đỡ tải lên một lần công cốc.
                    4. Trong form: chọn gói dịch vụ (chọn được nhiều gói), bật dịch vụ thêm nếu cần, chọn đơn vị đo và ngôn ngữ bản vẽ, viết ghi chú.
                    5. Bấm "Đặt hàng". Bản quét phải lên tới máy chủ thì đơn mới thành hình — mesh 3D kèm video, thường vài chục tới vài trăm MB — nên hãy dùng Wi-Fi và để app mở cho tới khi số đơn hiện ra. (Tuỳ bạn vào từ màn nào, cú tải lên có thể đã chạy xong từ trước khi form mở.)
                    6. Bấm "Thanh toán ngay" để mở trang thanh toán. Đội ngũ bắt đầu vẽ sau khi nhận được thanh toán.
                    """
                )
            ),
            FAQItem(
                id: "floors",
                question: L.t("How do I order a home with several floors?",
                              "Nhà nhiều tầng thì đặt thế nào?"),
                answer: L.t(
                    "One property = one home. The best result comes from scanning the whole home in one pass, walking up the stairs while still scanning. If the home is too big for one pass, split it into several scans but keep them in the SAME property — when you tap \"Order Floor Plan\" on the property page, every scan in it that has not been ordered yet goes into one single order (the count is printed on the button).",
                    "Một dự án = một căn nhà. Tốt nhất là quét liền một mạch cả nhà, vừa quét vừa đi lên cầu thang. Nhà lớn quá không quét hết một mạch thì chia thành nhiều bản quét nhưng để chung MỘT dự án — khi bấm \"Đặt làm mặt bằng\" ở trang dự án, mọi bản quét chưa đặt trong dự án đó đi chung MỘT đơn (số lượng ghi ngay trên nút)."
                )
            ),
            FAQItem(
                id: "one-order",
                question: L.t("How many orders can one property have?",
                              "Một dự án đặt được mấy đơn?"),
                answer: L.t(
                    "Exactly one. Once a property has an order, later scans do not create a second order — the button becomes \"Send extra scan\" and the new scan goes into the order you already have. Extra scans are never charged: an order is priced as one job for the whole home, not per scan.",
                    "Đúng một đơn. Sau khi dự án đã có đơn, các bản quét sau không tạo đơn mới nữa — nút đổi thành \"Gửi bổ sung bản quét\" và bản quét đi vào đúng đơn đang có. Bản quét bổ sung KHÔNG BAO GIỜ tính thêm phí: một đơn tính giá cho cả căn nhà, không tính theo số bản quét."
                )
            ),
            FAQItem(
                id: "free",
                question: L.t("Do I get any free orders?", "Tôi có đơn miễn phí không?"),
                answer: L.t(
                    "New customers get their first few orders free. When your order qualifies, the form shows how many free slots are left and the button reads \"FREE 🎁\" — no payment needed and our team starts right away. The free allowance counts per account AND per device, so making a new account on the same phone does not reset it.",
                    "Khách mới được miễn phí một số đơn đầu. Khi đơn của bạn thuộc diện đó, form ghi rõ còn bao nhiêu lượt và nút đặt hàng hiện \"MIỄN PHÍ 🎁\" — không cần thanh toán, đội ngũ bắt đầu ngay. Suất miễn phí tính theo CẢ tài khoản LẪN thiết bị, nên lập tài khoản mới trên cùng một máy không làm mới số lượt."
                )
            ),
            FAQItem(
                id: "price",
                question: L.t("What does the price include?", "Giá gồm những gì?"),
                answer: L.t(
                    "The \"Place order\" button shows the total of the packages you ticked plus the add-ons you switched on, in US dollars. A coupon is deducted on the payment page, so the button still shows the full price. One thing is NOT in that number: very large properties may attract a surcharge. The app cannot measure floor area on its own, so we work the surcharge out once the area has been measured — and we always tell you about it before we ask you to pay it.",
                    "Nút \"Đặt hàng\" hiện tổng của các gói bạn chọn cộng dịch vụ thêm bạn bật, tính bằng đô la Mỹ. Mã giảm giá được trừ ở trang thanh toán nên nút vẫn hiện giá đầy đủ. Có MỘT khoản không nằm trong con số đó: nhà rất lớn có thể chịu phụ phí. App không tự đo được diện tích sàn, nên phụ phí được tính sau khi đo — và Cedar247 luôn báo bạn trước khi thu."
                )
            ),
            FAQItem(
                id: "coupon",
                question: L.t("Where do I enter a coupon code?", "Có mã giảm giá thì nhập ở đâu?"),
                answer: L.t(
                    "In the \"Coupon code\" box near the bottom of the order form. The discount is applied on the payment page, so the number on the \"Place order\" button is still the full price. If the code turns out to be invalid, the screen right after ordering tells you and the order stays at full price.",
                    "Ô \"Mã giảm giá\" ở gần cuối form đặt hàng. Mức giảm được áp ở trang thanh toán, nên số trên nút \"Đặt hàng\" vẫn là giá đầy đủ. Mã không hợp lệ thì màn hình ngay sau khi đặt sẽ báo và đơn tính giá đầy đủ."
                )
            ),
            FAQItem(
                id: "addons",
                question: L.t("What are \"Express\" and \"Virtual Tour\"?",
                              "\"Express\" và \"Virtual Tour\" là gì?"),
                answer: L.t(
                    "Two add-ons in the order form. Express: delivered within 12 hours — not available for homes over 5,000 sq ft (464 m²). Virtual Tour: after ordering you add 1–3 photos per room, we pin them on your floor plan, and you get a shareable interactive tour link.",
                    "Hai dịch vụ thêm trong form đặt hàng. Express: giao trong vòng 12 giờ — không áp dụng cho nhà trên 5.000 sq ft (464 m²). Virtual Tour: sau khi đặt bạn thêm 1–3 ảnh cho mỗi phòng, đội ngũ ghim ảnh lên mặt bằng và bạn nhận link tour tương tác chia sẻ được."
                )
            ),
        ]
    )

    // MARK: - Quét thiếu, gửi bổ sung

    private static let supplementGroup = FAQGroup(
        id: "supplement",
        title: L.t("Missed an area?", "Quét thiếu, gửi bổ sung"),
        items: [
            FAQItem(
                id: "missed",
                question: L.t("I ordered, then noticed I missed part of the home. What now?",
                              "Đặt hàng xong mới phát hiện quét thiếu một khu, phải làm sao?"),
                answer: L.t(
                    "Just scan it — extra scans are never charged, before or after delivery. Open the property, tap \"Scan more\", scan the part you missed, then tap \"Send extra scan\". The new scan goes into the order you already have and our team adds it to your floor plan. Do not place a second order. Coming from the other direction works too: in the Orders tab, tap \"Add a scan\" on that order and the app takes you to the right property.",
                    "Cứ quét bổ sung — không bao giờ tính thêm phí, trước hay sau khi giao cũng vậy. Mở dự án, bấm \"Quét bổ sung\", quét phần còn thiếu, xong bấm \"Gửi bổ sung bản quét\". Bản quét mới đi vào đúng đơn đang có và đội ngũ cập nhật nó vào bản vẽ của bạn. Đừng đặt đơn thứ hai. Đi từ chiều ngược lại cũng được: ở tab Đơn hàng, bấm \"Thêm bản quét\" trên đơn đó là app đưa bạn sang đúng dự án."
                )
            ),
            FAQItem(
                id: "delivered",
                question: L.t("The order is already delivered — can I still change it?",
                              "Đơn đã giao rồi mà muốn sửa hoặc thêm?"),
                answer: L.t(
                    "Yes, and which route depends on what is wrong. — THE DRAWING IS WRONG OR INCOMPLETE for an area you did scan: Orders tab, pick the order, tap \"Request a revision\", describe what to change and attach a marked-up photo or PDF (up to 10 files). Mistakes on our side are fixed free of charge, within 90 days of delivery and up to three revisions per order. — YOU MISSED A WHOLE AREA and have now scanned it: send it exactly as before, with \"Send extra scan\" — still free after delivery. Our team draws the new area and sends you an updated drawing; while they work on it, the download link for the previous drawing is temporarily unavailable. Asking for something different from what you originally ordered — another package or add-on — is new work and is quoted separately.",
                    "Được, và đi đường nào thì tùy việc gì sai. — BẢN VẼ SAI HOẶC THIẾU CHI TIẾT ở khu bạn ĐÃ quét: tab Đơn hàng, chọn đơn, bấm \"Yêu cầu sửa\", mô tả chỗ cần sửa và đính kèm ảnh hoặc PDF có đánh dấu (tối đa 10 file). Lỗi từ phía Cedar247 thì sửa miễn phí, trong vòng 90 ngày kể từ ngày giao và tối đa 3 lần mỗi đơn. — BẠN QUÉT SÓT HẲN MỘT KHU và nay đã quét được: gửi y như bình thường bằng \"Gửi bổ sung bản quét\" — đã giao rồi vẫn không tính phí. Đội ngũ vẽ thêm phần mới và gửi lại bản vẽ cập nhật cho bạn; trong lúc đó link tải bản vẽ cũ tạm thời không dùng được. Yêu cầu thứ KHÁC so với đơn ban đầu — đổi gói, thêm dịch vụ — là công mới và được báo giá riêng."
                )
            ),
            FAQItem(
                id: "quality",
                question: L.t("What if a scan came out badly?",
                              "Bản quét bị lỗi hoặc chất lượng thấp thì sao?"),
                answer: L.t(
                    "The app marks low-quality scans, and the order screen usually warns you before you place the order. You can still order — our team is told in advance — but rescanning the flagged floor normally gives a more accurate drawing. If a scan holds video only and no 3D model, the scan screen says so in orange: our team cannot draw a floor plan from video, so please scan that area again.",
                    "App đánh dấu bản quét chất lượng thấp, và màn đặt hàng thường hỏi lại bạn trước khi đơn đi. Bạn vẫn đặt được — đội ngũ sẽ được báo trước — nhưng quét lại tầng bị đánh dấu thường cho bản vẽ chính xác hơn. Nếu bản quét chỉ có video mà không có mô hình 3D, màn bản quét ghi rõ bằng chữ màu cam: đội vẽ không dựng được mặt bằng từ video, hãy quét lại khu đó."
                )
            ),
        ]
    )

    // MARK: - Thanh toán, theo dõi, nhận hàng

    private static let afterOrderGroup = FAQGroup(
        id: "after",
        title: L.t("Payment, tracking, delivery", "Thanh toán, theo dõi, nhận hàng"),
        items: [
            FAQItem(
                id: "pay",
                question: L.t("Where do I pay?", "Thanh toán ở đâu?"),
                answer: L.t(
                    "Tap \"Pay Now\" — either on the screen right after you order, or in the Orders tab on any unpaid order. The button opens the payment page in your browser. If there is no button yet, we email you a payment link within a few minutes.",
                    "Bấm \"Thanh toán ngay\" — ở màn hình ngay sau khi đặt, hoặc ở tab Đơn hàng trên đơn chưa trả. Nút mở trang thanh toán bằng trình duyệt. Chưa thấy nút thì link thanh toán sẽ được gửi qua email trong ít phút."
                )
            ),
            FAQItem(
                id: "track",
                question: L.t("Where do I track my order?", "Theo dõi đơn ở đâu?"),
                answer: L.t(
                    "The Orders tab. Every order carries a status badge — Processing, On hold, Delivered or Refunded — with its order number and the date you placed it. The search box finds an order by number or by scan name.",
                    "Tab Đơn hàng. Mỗi đơn có nhãn trạng thái — Đang xử lý, Tạm giữ, Đã giao, Hoàn tiền — kèm số đơn và ngày đặt. Ô tìm kiếm tìm theo số đơn hoặc theo tên bản quét."
                )
            ),
            FAQItem(
                id: "formats",
                question: L.t("Which files do I get?", "Tôi nhận được những file gì?"),
                answer: L.t(
                    "PDF + JPG by default. Need SVG or PNG instead? Ask for it in the \"Note\" box when you order. \"CAD File\" (DWG) is a paid add-on — switch it on under Add-ons in the order form.",
                    "Mặc định: PDF + JPG. Cần SVG hoặc PNG thì ghi vào ô \"Ghi chú\" lúc đặt. \"CAD File\" (DWG) là dịch vụ thêm, tính tiền riêng — bật nó ở mục Dịch vụ thêm trong form đặt hàng."
                )
            ),
            FAQItem(
                id: "download",
                question: L.t("Where do I download the finished drawings?",
                              "Tải file thành phẩm ở đâu?"),
                answer: L.t(
                    "Orders tab → an order marked \"Delivered\" → \"Download deliverables\", or tap a single file in the list underneath. The link opens in your browser, and the file lands wherever your browser saves downloads (usually Files → Downloads).",
                    "Tab Đơn hàng → đơn có nhãn \"Đã giao\" → \"Tải file thành phẩm\", hoặc bấm thẳng từng file trong danh sách ngay bên dưới. Link mở bằng trình duyệt của máy, file tải về nằm ở nơi trình duyệt lưu (thường là Files → Tải về)."
                )
            ),
            FAQItem(
                id: "cancel",
                question: L.t("Can I cancel an order or get a refund?",
                              "Muốn huỷ đơn hoặc hoàn tiền?"),
                answer: L.t(
                    "There is no cancel button in the app. Write to \(LegalDoc.contactEmail) with your order number. The full terms are in the Account tab under Legal & Privacy.",
                    "App không có nút huỷ. Viết cho \(LegalDoc.contactEmail) kèm số đơn của bạn. Điều khoản đầy đủ ở tab Tài khoản, mục Legal & Privacy."
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
                question: L.t("Tips for a fast, accurate order",
                              "Mẹo để đơn được vẽ nhanh và đúng ý"),
                answer: L.t(
                    """
                    • Name each scan after its area, using the names the app offers you (Main floor, Basement, Upper floor, Garage, Shed…) — our drafting team reads those names to assemble the home.
                    • The more specific your note, the less there is to revise: room names, what to measure carefully, what to leave out.
                    • Attach photos or PDFs (an old drawing, a logo) while ordering rather than sending them afterwards.
                    • Set units and drawing language correctly the first time — the app remembers them for next time.
                    • Missed an area? Scan more and send it in — extra scans are never charged.
                    • The address you type before scanning is the address on the order — check it.
                    """,
                    """
                    • Đặt tên bản quét theo khu vực, dùng đúng những tên app gợi ý sẵn (Main floor, Basement, Upper floor, Garage, Shed…) — đội vẽ đọc chính mấy cái tên đó để ghép nhà, nên ĐỪNG dịch sang tiếng Việt.
                    • Ghi chú càng cụ thể càng ít phải sửa: tên phòng, chỗ cần đo kỹ, chỗ bỏ qua.
                    • Đính kèm ảnh hoặc PDF (bản vẽ cũ, logo) ngay lúc đặt thay vì gửi sau.
                    • Chọn đơn vị đo và ngôn ngữ bản vẽ đúng ngay từ đầu — app nhớ cho lần sau.
                    • Thiếu chỗ nào cứ quét bổ sung rồi gửi vào đơn — bản quét bổ sung không bao giờ tính thêm phí.
                    • Địa chỉ bạn nhập trước khi quét chính là địa chỉ trên đơn — kiểm lại cho đúng.
                    """
                )
            ),
            FAQItem(
                id: "help",
                question: L.t("I still need help", "Vẫn cần giúp thêm"),
                answer: L.t(
                    "Write to \(LegalDoc.contactEmail). If your question is about one particular order, include its order number.",
                    "Viết cho \(LegalDoc.contactEmail). Nếu câu hỏi về một đơn cụ thể thì kèm theo số đơn."
                )
            ),
        ]
    )
}
