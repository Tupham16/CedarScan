import SwiftUI

/// 🔴🔴 **BỘ TÁI HIỆN LỖI "LỀ SwiftUI ĐÔNG CỨNG" TRÊN SIMULATOR — CHỈ ĐỂ ĐO, GỠ KHI ĐÓNG VỤ.**
///
/// **Vì sao có file này.** Vụ lề đông cứng đã tốn **8 bản IPA** (2.6→2.14), mỗi bản là một lượt
/// chủ app phải sideload rồi thử tay, và cả 8 đều trượt. Không phải vì hết giả thuyết — mà vì mỗi
/// giả thuyết tốn một lượt của ông. File này lật ngược chỗ đó: vòng lặp thử-sai chuyển vào CI.
///
/// **Tiền đề khiến nó KHẢ THI (mới biết 12/08, ✗ có ở các vòng trước):** bệnh **không cần LiDAR,
/// không cần ARKit, không cần quét gì cả** — chỉ mở rồi đóng màn ĐỊA CHỈ là đủ (chủ app đo được).
/// Mà mở-đóng một sheet thì simulator làm được. Runner `macos-26` có Xcode 26.6 + iOS 26.5
/// (đo ở `.github/workflows/diag.yml`), tức đúng họ iOS đang lỗi.
///
/// **Bật bằng launch argument `-safeAreaHarness`** — ✗ bằng `#if DEBUG` (bản giao chủ app build
/// Release, mà bệnh chỉ thấy ở bản Release trên máy thật, nên harness phải sống được trong đúng
/// cấu hình đó). Không truyền cờ thì `isEnabled` = false và app KHÔNG đổi một pixel nào: app
/// sideload không có đường nào nhận launch argument.
///
/// 🔴 **CHỖ ĐẶT PHẢI Ở TRONG CÂY GỐC THẬT** (`HomeView` bên trong `TabView` + `CedarTabBar` gắn
/// bằng `.safeAreaInset`, bên trong `NavigationStack`). ✗ dựng một `RootView` giả cho gọn: chính
/// cấu trúc gốc đó đang là nghi can, thay nó đi là đo một app khác.
enum SafeAreaHarness {
    /// Đọc MỘT LẦN lúc nạp — `ProcessInfo.arguments` không đổi giữa chừng.
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-safeAreaHarness")

    /// Tên dự án hạt giống. XCUITest tìm hàng theo đúng chuỗi này.
    static let seedProjectName = "HARNESS HOUSE"

    /// Dựng sẵn một dự án để có đường vào `ProjectView` — nơi có nhãn đo.
    ///
    /// 🔴 Cần vì trên simulator KHÔNG tạo được dự án bằng đường thật: đường đó đi qua màn quét, mà
    /// `ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)` là false trên simulator
    /// nên nút SCAN chỉ hiện alert "Cần LiDAR". Idempotent: chạy nhiều lần vẫn một dự án.
    @MainActor
    static func seedIfNeeded(_ store: ScanStore) {
        guard isEnabled else { return }
        guard !store.projects.contains(where: { $0.name == seedProjectName }) else { return }
        _ = store.createProject(name: seedProjectName)
    }
}

/// Bảng nút của harness — chèn vào đầu danh sách ở `HomeView`, chỉ khi cờ bật.
///
/// Mỗi nút mở MỘT KIỂU trình bày khác nhau rồi để người/test đóng lại. Mục đích là chạy được
/// **ma trận đối chứng trong CÙNG một lượt CI**, thay vì mỗi giả thuyết một bản IPA:
///  · `H_ADDR`  — chính `ScanAddressView` (thủ phạm đã đo được trên máy thật);
///  · `H_PLAIN` — `.sheet` SwiftUI RỖNG (chỉ một dòng chữ). Lỗi ⇒ **mọi sheet đều gây bệnh**, nghi
///    can chuyển sang cấu trúc gốc chứ ✗ màn nào; lành ⇒ màn địa chỉ có gì đó riêng;
///  · `H_NAV`   — sheet có `NavigationStack` + `.toolbar` nhưng KHÔNG có gì khác. Chèn giữa hai
///    cái trên để biết `NavigationStack`-trong-sheet có phải điều kiện không.
/// ✗ gộp ba nút thành một: giá trị của bảng này nằm ở chỗ ba lượt đo ĐỘC LẬP, mỗi lượt một tiến
/// trình mới (XCUITest tự khởi động lại app cho từng test method).
struct SafeAreaHarnessPanel: View {
    // ⚠ CỐ Ý không khai `@EnvironmentObject store`: bảng này không đọc store dòng nào (việc gieo
    // dự án nằm ở `HomeView.task`). `ScanAddressView` bên trong sheet vẫn nhận store từ
    // `.environmentObject` ở `CedarScanApp` như mọi sheet khác.
    @State private var showAddress = false
    @State private var showPlain = false
    @State private var showNav = false

    /// ⚠ Ba `.sheet` gắn lên TỪNG HÀNG, ✗ lên `Section`: modifier đặt trên một `Section` nằm trong
    /// `List` là chỗ SwiftUI dễ hiểu thành "một hàng thường" và mất ngữ nghĩa section — không đáng
    /// đánh đổi trong một bộ đo mà mọi thứ phải chắc.
    /// ⚠ Và ba `.sheet` RIÊNG, ✗ gộp bằng một enum + `.sheet(item:)`: gộp là nhét thêm một biến số
    /// (`item:` dựng nội dung ở nhịp khác `isPresented:`) vào đúng thứ đang đo.
    var body: some View {
        Section("HARNESS") {
            Button("H_ADDR") { showAddress = true }
                .accessibilityIdentifier("H_ADDR")
                .sheet(isPresented: $showAddress) {
                    ScanAddressView { _ in }
                }
            Button("H_PLAIN") { showPlain = true }
                .accessibilityIdentifier("H_PLAIN")
                .sheet(isPresented: $showPlain) {
                    Text("H_PLAIN_SHEET")
                        .accessibilityIdentifier("H_PLAIN_SHEET")
                }
            Button("H_NAV") { showNav = true }
                .accessibilityIdentifier("H_NAV")
                .sheet(isPresented: $showNav) {
                    NavigationStack {
                        Text("H_NAV_SHEET")
                            .accessibilityIdentifier("H_NAV_SHEET")
                            .navigationTitle("H_NAV")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button("Close") { showNav = false }
                                }
                            }
                    }
                }
        }
    }
}
