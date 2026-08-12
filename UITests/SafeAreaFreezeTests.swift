import XCTest

/// 🔴🔴 **BỘ TÁI HIỆN LỖI "LỀ SwiftUI ĐÔNG CỨNG SAU KHI MỞ MỘT SHEET" — CHẠY TRÊN CI.**
/// Đọc `Sources/Support/SafeAreaHarness.swift` trước: ở đó ghi vì sao có bộ này (8 bản IPA trượt,
/// mỗi bản một lượt sideload của chủ app) và vì sao simulator làm được (bệnh không cần LiDAR).
///
/// **Phép đo, giống hệt thao tác tay của chủ app:**
///  1. mở app → chạm dự án hạt giống → đọc nhãn vàng ⇒ **mốc LÀNH** (`geo` phải KHÁC 0);
///  2. quay lại Home → mở một sheet → đóng nó;
///  3. chạm lại dự án → đọc nhãn ⇒ `geo t0 b0` là **TÁI HIỆN ĐƯỢC**.
///
/// 🔴 **Bước 1 KHÔNG được bỏ.** Nó vừa là mốc đối chiếu vừa là chốt chống kết luận sai: nếu `geo`
/// đã bằng 0 NGAY TỪ ĐẦU thì simulator vốn không dựng được lề đúng (vd chọn nhầm máy không tai
/// thỏ) và mọi số sau đó vô nghĩa — test FAIL với thông báo riêng cho ca đó, thay vì báo "tái hiện
/// được" một cách oan uổng.
///
/// ⚠ Mỗi test method là một TIẾN TRÌNH MỚI (`app.launch()` riêng) — cố ý: bệnh này DÍNH cho tới
/// khi khởi động lại app, nên hai phép thử chung một tiến trình là phép thử thứ hai bị nhiễm.
final class SafeAreaFreezeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Ba biến thể — xem `SafeAreaHarnessPanel` để biết mỗi cái loại trừ điều gì

    /// Chính `ScanAddressView`: thứ chủ app đã đo được là gây bệnh trên máy thật.
    /// Đây là phép thử QUYẾT ĐỊNH việc harness có dùng được hay không.
    func testAddressSheetFreezesSafeArea() {
        runProbe(buttonID: "H_ADDR", variant: "ScanAddressView") { app in
            app.navigationBars["Before scanning"].firstMatch
        }
    }

    /// Sheet RỖNG. Lỗi ⇒ mọi sheet đều gây bệnh ⇒ nghi can là CẤU TRÚC GỐC, không phải màn nào.
    func testPlainSheetFreezesSafeArea() {
        runProbe(buttonID: "H_PLAIN", variant: "sheet rỗng") { app in
            app.staticTexts["H_PLAIN_SHEET"].firstMatch
        }
    }

    /// Sheet có `NavigationStack` + `.toolbar`, không có gì khác.
    func testNavigationSheetFreezesSafeArea() {
        runProbe(buttonID: "H_NAV", variant: "sheet + NavigationStack") { app in
            app.navigationBars["H_NAV"].firstMatch
        }
    }

    // MARK: - Vòng 2: CÚ NẢY TAB (nghi can sinh ra từ chính kết quả vòng 1)

    /// 🔴 **ĐƯỜNG ĐI THẬT CỦA CHỦ APP, ✗ phải nút thường.** Vòng 1 cho thấy mở `ScanAddressView`
    /// bằng một nút thường thì KHÔNG gây bệnh — trong khi trên máy thật, mở đúng màn đó qua ĐĨA
    /// SCAN thì gây. Khác biệt duy nhất giữa hai đường là **cú nảy tab**: đĩa SCAN đặt
    /// `selection = .scan`, rồi `RootView.onChange(of: tab)` bật NGƯỢC về `.home` và tăng
    /// `scanRequest` trong CÙNG một nhịp — tab `.scan` chỉ là một `Color.clear` giả, app nhảy vào
    /// rồi nhảy ra ngay. Cú đó chạy trên chính cái `TabView` bị ẩn thanh gốc + gắn `CedarTabBar`
    /// bằng `.safeAreaInset`, tức nó đụng thẳng vào bộ máy vùng an toàn ở tầng gốc.
    /// So sánh test này với `testAddressSheetFreezesSafeArea` là tách được cú nảy khỏi cái sheet.
    func testScanTabPathFreezesSafeArea() {
        runProbe(
            variant: "ĐĨA SCAN → cú nảy tab → màn địa chỉ",
            openSheet: { app in
                let scan = app.buttons["Scan a new space"].firstMatch
                XCTAssertTrue(scan.waitForExistence(timeout: 30), "không thấy đĩa SCAN")
                scan.tap()
            },
            sheetMarker: { app in app.navigationBars["Before scanning"].firstMatch }
        )
    }

    /// ĐỐI CHỨNG cho cú nảy: một cú đổi tab THƯỜNG (Home → Đơn hàng → Home), không sheet nào.
    /// Lỗi ⇒ mọi cú đổi tab đều gây bệnh, tức nghi can là `TabView` + `.safeAreaInset` nói chung
    /// chứ ✗ riêng cú nảy. Lành ⇒ chỉ cú NHẢY-VÀO-RỒI-RA của tab giả mới độc.
    func testPlainTabSwitchFreezesSafeArea() {
        let app = XCUIApplication()
        app.launchArguments = ["-safeAreaHarness"]
        app.launch()

        let before = readProbeByOpeningProject(app, phase: "TRƯỚC")
        assertBaselineIsHealthy(before)

        let orders = app.buttons["Orders"].firstMatch
        XCTAssertTrue(orders.waitForExistence(timeout: 30), "không thấy tab Đơn hàng")
        orders.tap()
        let home = app.buttons["Home"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 30), "không thấy tab Home")
        home.tap()

        let after = readProbeByOpeningProject(app, phase: "SAU")
        report(variant: "đổi tab thường (Home→Đơn hàng→Home)", before: before, after: after)
    }

    // MARK: - Khung đo dùng chung

    /// Biến thể mở sheet bằng một NÚT THƯỜNG trong bảng harness.
    private func runProbe(
        buttonID: String,
        variant: String,
        sheetMarker: @escaping (XCUIApplication) -> XCUIElement
    ) {
        runProbe(
            variant: variant,
            openSheet: { app in
                let button = app.buttons[buttonID].firstMatch
                XCTAssertTrue(button.waitForExistence(timeout: 30), "không thấy nút harness \(buttonID)")
                button.tap()
            },
            sheetMarker: sheetMarker
        )
    }

    /// Khung chung: đo → mở gì đó → đóng → đo lại. `openSheet` là chỗ DUY NHẤT các biến thể khác
    /// nhau, nên mọi thứ còn lại (mốc lành, cách đọc nhãn, cách đóng) là hằng số giữa các phép đo.
    private func runProbe(
        variant: String,
        openSheet: (XCUIApplication) -> Void,
        sheetMarker: (XCUIApplication) -> XCUIElement
    ) {
        let app = XCUIApplication()
        app.launchArguments = ["-safeAreaHarness"]
        app.launch()

        let before = readProbeByOpeningProject(app, phase: "TRƯỚC")
        assertBaselineIsHealthy(before)

        openSheet(app)
        XCTAssertTrue(
            sheetMarker(app).waitForExistence(timeout: 30),
            "[\(variant)] sheet không mở (không thấy dấu nhận biết bên trong nó)"
        )
        dismissSheetBySwipe(app, variant: variant)

        let after = readProbeByOpeningProject(app, phase: "SAU")
        report(variant: variant, before: before, after: after)
    }

    /// 🔴 Mốc lành phải KHÁC 0 thì mọi số sau mới có nghĩa — xem chú thích đầu file.
    private func assertBaselineIsHealthy(_ before: String) {
        XCTAssertFalse(
            before.contains("geo t0 b0"),
            """
            MỐC LÀNH ĐÃ SAI TỪ ĐẦU — simulator không dựng được lề đúng, mọi số sau vô nghĩa.
            Đọc được: \(before)
            Nhiều khả năng chọn nhầm máy (không tai thỏ) trong workflow. ✗ đọc kết quả run này.
            """
        )
    }

    /// ✗ `XCTAssert` cho vế "tái hiện được": ở đây KHÔNG có chiều nào là "sai" — cả hai đều là
    /// thông tin. Chỉ ĐO và IN; việc phán xử để người đọc log.
    private func report(variant: String, before: String, after: String) {
        let reproduced = after.contains("geo t0 b0")
        print("""

        ================ HARNESS KẾT QUẢ [\(variant)] ================
        trước : \(before)
        sau   : \(after)
        TÁI HIỆN ĐƯỢC : \(reproduced ? "CÓ — lề về 0" : "KHÔNG — lề giữ nguyên")
        =============================================================

        """)
    }

    /// Chạm dự án hạt giống → đọc nhãn vàng → quay lại Home.
    ///
    /// 🔴 PHẢI đi vào rồi QUAY RA mỗi lần đo: nhãn chỉ sống trong `ProjectView`, và chính cú PUSH
    /// là thứ để lộ lề sai (header đè danh sách). Đọc ở Home thì không thấy bệnh.
    private func readProbeByOpeningProject(_ app: XCUIApplication, phase: String) -> String {
        let row = projectRow(app)
        XCTAssertTrue(
            row.waitForExistence(timeout: 60),
            "[\(phase)] không thấy dòng dự án hạt giống — `SafeAreaHarness.seedIfNeeded` chưa chạy?"
        )
        row.tap()

        let probe = app.staticTexts["SAFE_AREA_PROBE"].firstMatch
        XCTAssertTrue(
            probe.waitForExistence(timeout: 30),
            "[\(phase)] không thấy nhãn đo trong ProjectView — nhãn đã bị gỡ khỏi app?"
        )
        let value = probe.label

        // Quay lại Home bằng nút đầu tiên của thanh điều hướng (nút Back).
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 10) { back.tap() }
        XCTAssertTrue(
            projectRow(app).waitForExistence(timeout: 30),
            "[\(phase)] không quay lại được Home sau khi đọc nhãn."
        )
        return value
    }

    /// Dòng dự án hạt giống. Tìm bằng CONTAINS trên mọi phần tử, ✗ bằng `app.buttons["tên"]`:
    /// dòng đó là một `Button` gói cả tên lẫn số bản quét nên nhãn trợ năng của nó là chuỗi GHÉP,
    /// khớp chính xác sẽ trượt. Rơi về `staticTexts` cho ca SwiftUI phơi dòng ra kiểu khác —
    /// chạm vào chữ bên trong một Button vẫn kích hoạt được Button đó.
    private func projectRow(_ app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", "HARNESS HOUSE")
        let button = app.buttons.matching(predicate).firstMatch
        if button.exists { return button }
        let cell = app.cells.matching(predicate).firstMatch
        if cell.exists { return cell }
        return app.staticTexts.matching(predicate).firstMatch
    }

    /// Đóng bằng CỬ CHỈ VUỐT XUỐNG — đúng thao tác chủ app làm lúc đo được lỗi, và là đường duy
    /// nhất dùng chung được cho mọi biến thể (sheet rỗng không có nút Đóng nào).
    /// Bắt đầu từ SÁT MÉP TRÊN của sheet (vùng "tay nắm"), ✗ từ giữa màn: giữa màn của
    /// `ScanAddressView` là ô nhập, kéo ở đó thành thao tác chọn chữ chứ không đóng sheet.
    private func dismissSheetBySwipe(_ app: XCUIApplication, variant: String) {
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.10))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        top.press(forDuration: 0.15, thenDragTo: bottom)

        // Chờ Home trở lại thay vì ngủ.
        XCTAssertTrue(
            projectRow(app).waitForExistence(timeout: 30),
            "[\(variant)] sheet không đóng được bằng vuốt xuống"
        )
    }
}
