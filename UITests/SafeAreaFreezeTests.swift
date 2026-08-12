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

    // MARK: - Khung đo dùng chung

    private func runProbe(
        buttonID: String,
        variant: String,
        sheetMarker: @escaping (XCUIApplication) -> XCUIElement
    ) {
        let app = XCUIApplication()
        app.launchArguments = ["-safeAreaHarness"]
        app.launch()

        let before = readProbeByOpeningProject(app, phase: "TRƯỚC")
        XCTAssertFalse(
            before.contains("geo t0 b0"),
            """
            MỐC LÀNH ĐÃ SAI TỪ ĐẦU — simulator không dựng được lề đúng, mọi số sau vô nghĩa.
            Đọc được: \(before)
            Nhiều khả năng chọn nhầm máy (không tai thỏ) trong workflow. ✗ đọc kết quả run này.
            """
        )

        openAndDismissSheet(app, buttonID: buttonID, sheetMarker: sheetMarker)

        let after = readProbeByOpeningProject(app, phase: "SAU")
        let reproduced = after.contains("geo t0 b0")

        // ✗ `XCTAssert` cho vế "tái hiện được": ở đây KHÔNG có chiều nào là "sai" — cả hai đều là
        // thông tin. Test chỉ ĐO và IN; việc phán xử để người đọc log.
        print("""

        ================ HARNESS KẾT QUẢ [\(variant)] ================
        trước khi mở sheet : \(before)
        sau khi đóng sheet : \(after)
        TÁI HIỆN ĐƯỢC      : \(reproduced ? "CÓ — lề về 0" : "KHÔNG — lề giữ nguyên")
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

    private func openAndDismissSheet(
        _ app: XCUIApplication,
        buttonID: String,
        sheetMarker: (XCUIApplication) -> XCUIElement
    ) {
        let button = app.buttons[buttonID].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 30), "không thấy nút harness \(buttonID)")
        button.tap()

        // Chờ một phần tử BÊN TRONG sheet, ✗ ngủ theo đồng hồ.
        XCTAssertTrue(
            sheetMarker(app).waitForExistence(timeout: 30),
            "sheet \(buttonID) không mở (không thấy dấu nhận biết bên trong nó)"
        )

        // Đóng bằng CỬ CHỈ VUỐT XUỐNG — đúng thao tác chủ app làm lúc đo được lỗi, và là đường
        // duy nhất dùng chung được cho cả ba biến thể (sheet rỗng không có nút Đóng nào).
        // Bắt đầu từ SÁT MÉP TRÊN của sheet (vùng "tay nắm"), ✗ từ giữa màn: giữa màn của
        // `ScanAddressView` là ô nhập, kéo ở đó thành thao tác chọn chữ chứ không đóng sheet.
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.10))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        top.press(forDuration: 0.15, thenDragTo: bottom)

        // Chờ Home trở lại thay vì ngủ.
        XCTAssertTrue(
            projectRow(app).waitForExistence(timeout: 30),
            "sheet \(buttonID) không đóng được bằng vuốt xuống"
        )
    }
}
