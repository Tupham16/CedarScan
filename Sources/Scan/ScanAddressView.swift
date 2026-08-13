import CoreLocation // CLLocationCoordinate2D — toạ độ ghim lên bản đồ xác nhận
import Foundation
import MapKit // Map/Marker — bản đồ xác nhận vị trí ở đầu màn
import SwiftUI
import UIKit // UIApplication.openSettingsURLString — đưa khách sang Cài đặt khi quyền vị trí bị tắt

/// Màn chèn giữa nút Quét và màn quét: gắn bản quét sắp tới vào một CĂN NHÀ (dự án).
/// Ô chọn độ nét đã BỎ 2026-07-31 (chỉ còn một mức — xem `MeshQuality`), nên màn này giờ hỏi
/// đúng một thứ: căn nhà.
///
/// VÌ SAO ĐỊA CHỈ PHẢI ĐI QUA `ScanProject` CHỨ KHÔNG PHẢI `ScanRecord`:
/// thẻ Kanban gửi đội vẽ lấy tên căn nhà từ DỰ ÁN — `ScanDetailView` gửi
/// `projectName: store.project(with: current.projectId)?.name`, không phải tên bản quét.
/// Bản quét mở từ HomeView trước đây luôn lưu `projectId = nil`, nên đơn tới tay đội vẽ
/// KHÔNG kèm địa chỉ nào. Nhét địa chỉ vào tên bản quét sẽ không chạy tới thẻ.
///
/// ĐỊA CHỈ BẮT BUỘC (chủ app chốt 2026-07-19, đảo lại quyết định "có nút Bỏ qua" trước đó):
/// không điền thì không quét được. Lý do: bản quét không gắn căn nhà là đơn tới tay đội vẽ
/// không có địa chỉ — đúng thứ màn này sinh ra để chống, mà cho bỏ qua thì ai cũng bỏ qua.
/// Chấp nhận CHỮ TỰ DO (không ép đúng định dạng địa chỉ) để người dùng luôn đi tiếp được khi
/// GPS yếu trong nhà, mất mạng, hoặc từ chối cấp quyền vị trí.
///
/// 🔴 MÀN NÀY LÀ ĐƯỜNG QUÉT CĂN **MỚI** (2026-07-23, chủ app chốt). Nó KHÔNG còn bày danh sách
/// các căn đã quét nữa. Muốn quét thêm cho một căn ĐÃ CÓ thì đường đúng là: Trang chủ → mở dự án
/// đó → nút quét trong `ProjectView` (màn đó không hỏi lại địa chỉ vì đã biết căn nào). Ở đây chỉ
/// còn gợi ý khi chữ vừa gõ TRÙNG một căn đã có — để không đẻ ra hai căn cùng địa chỉ.
struct ScanAddressView: View {
    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss
    /// projectId để gắn bản quét sắp tới. Từ 2026-07-19 địa chỉ là BẮT BUỘC nên thực tế luôn
    /// non-nil; giữ Optional vì `createProject` vẫn có thể trả nil (tên toàn ký tự lạ bị lọc
    /// sạch) — lúc đó thà cho quét còn hơn nuốt mất buổi quét vì một cái tên kỳ quặc.
    let onStart: (UUID?) -> Void

    @State private var address = ""
    @State private var pickedProjectId: UUID?
    /// "Dùng vị trí hiện tại" + gợi ý địa chỉ khi gõ. Cả hai là ĐƯỜNG TẮT — xem `AddressLookup.swift`.
    @StateObject private var locator = LocationLookup()
    @StateObject private var completer = AddressCompleter()
    /// Chữ trong ô → toạ độ cho bản đồ ở đầu màn. Chỉ để NHÌN, không đi kèm đơn hàng.
    @StateObject private var geocoder = AddressGeocoder()
    /// Con trỏ đang nằm trong ô địa chỉ. Là CÔNG TẮC DUY NHẤT của danh sách gợi ý: đang gõ thì
    /// hiện, chạm một gợi ý (view tự bỏ focus) hoặc điền bằng nút vị trí thì tắt. Không cần cờ
    /// "vừa chọn xong" — cờ đó là thứ luôn kẹt sai ở lần dùng thứ hai.
    @FocusState private var addressFocused: Bool
    /// Ô địa chỉ đang chứa gì LÚC BẤM nút "Dùng vị trí hiện tại".
    ///
    /// Tra vị trí + reverse geocode mất vài giây. Không có mốc này thì kịch bản rất thật sau đây
    /// mất trắng dữ liệu: khách bấm nút, chờ 3 giây thấy chưa ra gì nên bắt đầu gõ tay, rồi GPS
    /// trả về và ĐÈ SẠCH chữ họ vừa gõ — ở màn BẮT BUỘC, không có nút hoàn tác. Chỉ ghi đè khi ô
    /// vẫn y nguyên như lúc bấm. (Bấm lại lần nữa vẫn chạy được: mốc được chụp lại tại mỗi lần bấm.)
    @State private var addressWhenLocating: String?
    /// Lần đổi `address` sắp tới là do APP tự điền (bấm vị trí / chạm gợi ý), không phải khách gõ.
    /// Không có cờ này thì mỗi lần tự điền lại bắn NGAY một truy vấn MapKit mới bằng chính chuỗi
    /// vừa điền — gửi thừa cả địa chỉ đầy đủ sang Apple để lấy về đúng thứ vừa chọn.
    @State private var suppressCompleter = false

    /// Số dòng "căn đã quét trùng tên" hiện tối đa.
    ///
    /// KHÔNG có nút "xem tất cả" và KHÔNG có danh sách đầy đủ (chủ app chốt 2026-07-23 — xem
    /// `matchingProjects`). Ba dòng là đủ để nhận ra căn mình định quét tiếp; gõ thêm vài chữ là
    /// nó thu về đúng một dòng.
    private static let matchRowLimit = 3

    /// Căn đã quét TRÙNG với chữ đang gõ.
    ///
    /// 🔴 TRƯỚC 2026-07-23 chỗ này in RA TOÀN BỘ danh sách căn đã quét ngay khi mở màn (ô nhập
    /// rỗng cũng hiện, kèm nút "Xem tất cả N căn"). Chủ app chốt BỎ: bấm SCAN là đang định quét
    /// một căn MỚI, mà màn hình lại mở ra bằng một danh sách cũ dài — vừa che mất ô nhập vừa đẩy
    /// nút "Bắt đầu quét" xuống. Muốn quét tiếp một căn đã có thì đường đúng là vào TRANG CHỦ,
    /// mở đúng dự án đó rồi bấm quét từ trong đó (`ProjectView` đã có nút riêng).
    ///
    /// Ở đây chỉ còn vai trò NHẮC: gõ địa chỉ mà trùng căn đã có thì hiện ra để chạm, khỏi tạo
    /// căn thứ hai cùng địa chỉ. Ô rỗng → KHÔNG hiện gì.
    /// 🔴 KHỚP HAI CHIỀU (`a.contains(b) || b.contains(a)`), đừng "dọn" về một chiều.
    /// Chiều cũ chỉ có `tênDựÁn.contains(chữĐangGõ)`, đúng khi khách gõ tay từng chữ. Nhưng nút
    /// "Dùng vị trí hiện tại" và gợi ý MapKit đổ vào ô một địa chỉ ĐẦY ĐỦ
    /// ("1600 College Ave, Fort Worth, TX 76110") trong khi dự án cũ tên ngắn ("1600 College Ave")
    /// — chuỗi tìm DÀI HƠN tên dự án nên một chiều là KHÔNG khớp gì cả: dòng "Đã quét — chạm để
    /// dùng lại" biến mất đúng lúc cần nhất, khách tạo căn thứ hai cho cùng một căn nhà. Hậu quả
    /// thật: `ScanDetailView` gom tầng phụ theo `projectId`, nên Part 1 và Part 2 nằm hai dự án
    /// khác nhau không bao giờ vào chung một đơn được → hai đơn, hai lần tiền.
    private var matchingProjects: [ScanProject] {
        let key = Self.matchKey(address)
        guard !key.isEmpty else { return [] }
        let scored: [(project: ScanProject, name: String)] = store.projects.compactMap { p in
            let name = Self.matchKey(p.name)
            guard !name.isEmpty else { return nil }
            // Chiều XUÔI (tên chứa chữ đang gõ) không cần sàn độ dài — đó là ca gõ dần từng chữ.
            if name.contains(key) { return (p, name) }
            // 🔴 Chiều NGƯỢC phải có SÀN ĐỘ DÀI. Không có sàn thì một dự án đặt tên ngắn ("Lan",
            // "A1", "Nhà") khớp gần như MỌI địa chỉ dài mà GPS/MapKit đổ vào, và app mời khách
            // "dùng lại" nhầm căn — bản quét chui vào nhà người khác, đội vẽ không có cách nào
            // biết. Sàn 5 vẫn bắt đủ ca thật đã sinh ra chiều này ("1600 college ave" nằm trong
            // "1600 college ave, fort worth, tx 76110").
            if name.count >= Self.reverseMatchFloor, key.contains(name) { return (p, name) }
            return nil
        }
        // XẾP HẠNG TRƯỚC rồi mới cắt. `store.projects` xếp theo thời gian, nên cắt thẳng 3 dòng
        // đầu có thể VỨT ĐI đúng căn khớp chính xác nhất chỉ vì nó cũ hơn — mà đó là dòng duy
        // nhất khách cần thấy.
        let ranked = scored.sorted { a, b in
            if (a.name == key) != (b.name == key) { return a.name == key }
            return a.name.count > b.name.count
        }
        // `.map { $0.project }` chứ KHÔNG phải `.map(\.project)`: Swift không có key path vào
        // phần tử tuple, viết `\.project` là lỗi biên dịch (mà máy này không compile được để bắt).
        return ranked.prefix(Self.matchRowLimit).map { $0.project }
    }

    /// Tên dự án phải dài ít nhất bấy nhiêu ký tự (sau khi bỏ dấu) thì mới được khớp theo chiều
    /// NGƯỢC. Xem giải thích trong `matchingProjects`.
    private static let reverseMatchFloor = 5

    /// Căn đã có TRÙNG HẲN tên với chữ đang gõ (không phải chỉ chứa).
    ///
    /// Chỉ dùng để nhắc một dòng, KHÔNG tự gộp. Gộp im lặng nguy hiểm hơn chính lỗi nó sửa:
    /// tách nhầm làm đơn THIẾU một tầng (đội vẽ thấy ngay), gộp nhầm làm đơn THỪA tầng của nhà
    /// khác — đội vẽ dựng ra một căn nhà không tồn tại và không ai phát hiện được. Ô này ghi
    /// "Địa chỉ hoặc tên" nên tên người là dữ liệu hợp lệ, mà hai khách cùng gọi "Nhà chị Lan"
    /// là chuyện thường ngày. Nên: chỉ NHẮC, để người dùng chạm.
    private var exactMatch: ScanProject? {
        let key = Self.matchKey(address)
        guard !key.isEmpty, pickedProjectId == nil else { return nil }
        return store.projects.first { Self.matchKey($0.name) == key }
    }

    var body: some View {
        NavigationStack {
            // 🔴🔴 **NÚT ĐÁY GHIM BẰNG `VStack`, ✗ BẰNG `.safeAreaInset` — ĐÂY LÀ BẢN VÁ CỦA LỖI
            // "LỀ SwiftUI ĐÔNG CỨNG SAU KHI BẤM QUÉT" (bản 2.14). ✗ ĐỔI NGƯỢC LẠI.**
            //
            // Bệnh: mở màn này rồi ĐÓNG LẠI (kể cả bấm Hủy ngay, KHÔNG vào màn quét) là mọi màn
            // sau đó mất vùng an toàn — header đè danh sách, nút đáy bị đĩa Scan đè, TẤT CẢ dự án,
            // chỉ thoát app vào lại mới hết. Số đo lúc lỗi: `win t47 b34 · root t47 b34 · geo t0 b0`
            // (UIKit LÀNH tới tận view gốc, chỉ cây SwiftUI đọc 0).
            //
            // 🔴 **BẢY BẢN IPA (2.6→2.13) ĐÃ MỔ NHẦM MÀN.** Cả bảy đều đi vá MÀN QUÉT — đổi
            // `.fullScreenCover` → present `.overFullScreen` → cửa sổ UIWindow riêng → lớp phủ
            // SwiftUI không trình bày gì cả — và cả bốn cơ chế đều VẪN LỖI, vì thủ phạm chưa bao
            // giờ nằm ở đó. Câu "mở màn quét rồi Hủy ngay" trong mọi mô tả lỗi đã GIẤU màn này vào
            // bên trong: bấm SCAN là mở SHEET NÀY trước, cover chỉ hiện sau khi bấm "Bắt đầu quét".
            // Phép thử tách nó ra (12/08): mở sheet này → vuốt đóng → vào dự án ⇒ `geo t0 b0`.
            // Màn quét không hề chạy. ⇒ Nó ĐỦ để gây bệnh một mình.
            //
            // 🔴 **VÌ SAO LÀ `.safeAreaInset`:** trong toàn app chỉ có BỐN chỗ dùng nó — thanh tab
            // (`CedarScanApp`), nút đáy `ProjectView`, thẻ dịch vụ `ScanDetailView`, và chỗ này.
            // Ba chỗ đầu nằm trong cây gốc và chính là BA THỨ CHỦ APP THẤY HỎNG; chỗ này là chỗ
            // DUY NHẤT nằm TRONG MỘT SHEET, tức thứ duy nhất sửa vùng an toàn từ bên trong một
            // presentation rồi bị tháo đi. Đối chứng: `SupplementSheet`/`AccountGateSheet` cũng là
            // sheet, cũng `NavigationStack` + `.toolbar`, KHÔNG có `.safeAreaInset` — không gây
            // bệnh; Share sheet (UIActivityViewController của UIKit) cũng không.
            //
            // ⚠ **✗ GỠ `.safeAreaInset` Ở BA CHỖ KIA** — chúng là NẠN NHÂN, không phải thủ phạm,
            // và chúng đang gánh layout thật (thiếu là thanh tab che mất nút đặt hàng, bẫy đã ghi
            // ở `CedarTabBar.reservedHeight`).
            //
            // Lý do nút phải GHIM (giữ nguyên từ 2026-07-20, ✗ đưa nó trở lại làm section cuối
            // của Form): trước đây nó là section CUỐI, nằm SAU danh sách căn đã quét — danh sách
            // đó không giới hạn số dòng nên khách có nhiều căn là nút bị đẩy khỏi màn hình, phải
            // cuộn xuống đáy mới bấm được. Nút chính của một màn BẮT BUỘC không được phụ thuộc
            // vào việc người dùng có bao nhiêu dữ liệu cũ.
            // `VStack` giữ nguyên tính chất đó mà không đụng một byte nào vào vùng an toàn: Form
            // chiếm phần trên và cuộn riêng, `startBar` chiếm phần dưới, hai bên không chồng nhau
            // nên cũng không cần chừa chỗ cho nhau. Bàn phím đẩy cả cụm lên — ở màn GÕ ĐỊA CHỈ thì
            // đó là đúng thứ mình muốn (nút "Bắt đầu quét" không bị bàn phím nuốt), khác hẳn ca
            // thanh tab ở `RootView` (chỗ đó phải nằm im, lý do ghi tại chỗ).
            //
            // Tách từng Section thành computed property riêng — CI từng timeout type-check
            // với biểu thức SwiftUI lớn, và Form nhiều section là đúng dạng dễ dính.
            //
            // THỨ TỰ TỪ 2026-08-13 (chủ app chốt): **BẢN ĐỒ TRÊN, cụm nhập + nút ở DƯỚI.** Bản đồ
            // là thứ khách liếc một cái là biết đúng nhà hay chưa, nên nó ăn phần trên màn hình;
            // ô nhập và nút nằm trong tầm ngón cái. Bản đồ đứng NGOÀI `Form` — nhét nó vào một
            // hàng của Form là nó cuộn đi mất đúng lúc danh sách gợi ý dài ra.
            VStack(spacing: 0) {
                AddressMapView(coordinate: geocoder.coordinate, state: geocoder.state)
                    // Thu nhỏ khi bàn phím lên. Cả cụm này bị bàn phím đẩy lên (VStack, cố ý —
                    // xem khối 🔴 ở trên), nên bản đồ cao cố định là bản đồ bị đẩy khuất một nửa
                    // VÀ bóp phần Form còn lại xuống còn hai dòng: gợi ý địa chỉ + danh sách căn
                    // đã quét không còn chỗ hiện, đúng lúc khách đang gõ và cần chúng nhất.
                    .frame(height: addressFocused ? 130 : 230)
                    .animation(.easeInOut(duration: 0.25), value: addressFocused)
                Form {
                    homeSection
                }
                startBar
            }
            // Tiêu đề "Trước khi quét" đổi thành TÊN THỨ MÀN NÀY HỎI (chủ app chốt 2026-08-13) và
            // để cỡ LỚN cho dễ nhận. Nhãn "Địa chỉ căn nhà" của section đã bỏ theo — hai chữ y hệt
            // nhau cách nhau 30pt là một dòng thừa, mà màn này vốn chỉ hỏi đúng một thứ.
            .navigationTitle(L.t("Property address", "Địa chỉ căn nhà"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("Cancel", "Hủy")) { dismiss() }
                }
            }
            // Địa chỉ tra được từ GPS đổ vào ô nhập ở ĐÂY, không phải trong `LocationLookup`:
            // `address` thuộc về view này và có `onChange` riêng (xoá căn đang chọn, cập nhật gợi
            // ý). Để hai nơi cùng ghi vào nó là mất dấu ai ghi đè ai.
            //
            // Đặt `resolvedAddress = nil` ngay sau khi dùng: không thì bấm nút vị trí lần hai ở
            // cùng một chỗ sẽ ra ĐÚNG chuỗi cũ, `onChange` thấy giá trị không đổi và ô nhập đứng
            // im — trông y như nút hỏng.
            .onChange(of: locator.resolvedAddress) { _, newValue in
                guard let newValue, !newValue.isEmpty else { return }
                locator.resolvedAddress = nil
                // Khách đã gõ thêm trong lúc chờ GPS → chữ của họ THẮNG. Xem `addressWhenLocating`.
                guard address == (addressWhenLocating ?? address) else {
                    addressWhenLocating = nil
                    return
                }
                // 🔴 Khách CHẠM MỘT CĂN ĐÃ QUÉT trong lúc chờ GPS thì lựa chọn đó cũng THẮNG.
                // Nhánh chạm không đổi `address` (cố ý — xem `matchingRows`), nên guard bên trên
                // KHÔNG bắt được ca này: GPS về sẽ ghi đè ô nhập, `onChange(of: address)` xoá
                // `pickedProjectId`, và bản quét rơi vào một căn MỚI tạo thay vì căn khách vừa
                // chọn → hai dự án cho cùng một căn nhà → hai đơn. Đúng lớp lỗi tiền đã tả ở
                // `matchingProjects`.
                guard pickedProjectId == nil else {
                    addressWhenLocating = nil
                    return
                }
                addressWhenLocating = nil
                suppressCompleter = true
                addressFocused = false
                // GHIM TRƯỚC, gán chữ SAU. `geocoder.pin` nhớ luôn chuỗi vừa ghim, nên `onChange`
                // của `address` ngay dưới đây thấy đúng chuỗi đó và không bắn thêm lượt tra nào —
                // giữ nguyên toạ độ GPS THẬT thay vì thay bằng kết quả tra ngược lại từ chữ.
                if let coordinate = locator.lastCoordinate {
                    geocoder.pin(coordinate, for: newValue)
                }
                address = newValue
                completer.clear()
            }
        }
    }

    /// Thứ tự các dòng trong mục này KHÔNG tuỳ tiện (chủ app chốt 2026-07-23):
    /// ô nhập → nút "Dùng vị trí hiện tại" → trạng thái định vị →
    /// **căn đã quét trùng tên** → gợi ý địa chỉ MapKit → dòng "đang thêm vào căn X".
    ///
    /// 🔴 NÚT ĐỨNG NGAY DƯỚI Ô NHẬP, MỌI THỨ ĐỘNG NẰM DƯỚI NÓ. Đây là lý do: trạng thái định vị,
    /// danh sách căn trùng và gợi ý MapKit đều là những dòng XUẤT HIỆN/BIẾN MẤT theo lúc. Nếu chen
    /// bất kỳ dòng nào trong số đó vào giữa hoặc lên trên nút thì nút sẽ NHẢY xuống ngay lúc người
    /// dùng đang nhắm ngón tay vào nó — cùng lớp lỗi với bẫy #2 ở handoff ("dòng vừa chạm nhảy đi
    /// → người dùng tưởng chạm hụt").
    ///
    /// 🔴 NÚT "TÌM ĐỊA CHỈ" (kính lúp) ĐÃ BỎ 2026-08-13 — chủ app: *"khi điền địa chỉ nó đã tự tìm
    /// rồi, nút hơi thừa"*. Đúng: nút đó không tìm gì cả, nó chỉ đưa con trỏ vào chính ô nhập nằm
    /// ngay phía trên nó, còn việc tra gợi ý do `onChange` của ô làm từ ký tự thứ ba. ✗ thêm lại.
    ///
    /// Căn đã quét đứng TRƯỚC gợi ý MapKit: khi cả hai cùng hiện thì "dùng lại căn đã có" là câu
    /// trả lời đúng, còn tạo thêm một căn thứ hai cùng địa chỉ là lỗi phải đi dọn bằng tay sau đó.
    private var homeSection: some View {
        Section {
            TextField(
                L.t("Address or name (e.g. 1600 College Ave)", "Địa chỉ hoặc tên (vd 1600 College Ave)"),
                text: $address
            )
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .focused($addressFocused)
            // Gõ = đang mô tả căn mới → bỏ dòng đang chọn. Hai đường loại trừ nhau, để cả hai
            // cùng "bật" là người dùng không đoán được cái nào thắng.
            //
            // XOÁ VÔ ĐIỀU KIỆN, không guard `!newValue.isEmpty`: guard đó là tàn dư từ hồi nút
            // chọn dòng còn đặt `address = ""` (phải chặn để lựa chọn vừa tạo không tự huỷ).
            // Bỏ dòng đó rồi mà giữ guard thì sinh ra trạng thái KHÔNG THOÁT ĐƯỢC: ô rỗng nhưng
            // `pickedProjectId` vẫn còn — màn hình nói "chưa gắn căn nào" (ô trống + footer +
            // nhãn nút) trong khi `start()` vẫn gắn. Giờ an toàn vì nhánh chạm dòng không ghi
            // vào `address` nữa nên không sinh vòng lặp.
            .onChange(of: address) { _, newValue in
                pickedProjectId = nil
                // Bản đồ đi theo chữ trong ô, kể cả khi chữ do app tự điền. `AddressGeocoder` tự
                // debounce + tự bỏ qua khi chuỗi trùng cái đang ghim, nên gọi vô điều kiện ở đây
                // là an toàn — ✗ nhét thêm điều kiện, chỗ này đã có `suppressCompleter` là một cờ
                // đủ để nhầm rồi.
                geocoder.update(address: newValue)
                if suppressCompleter {
                    suppressCompleter = false
                    completer.clear()
                } else {
                    completer.update(query: newValue)
                }
            }
            useLocationButton
            locationStatusRow
            matchingRows
            suggestionRows
            pickedRow
        } footer: {
            // Footer render SAU mọi dòng của section, nên KHÔNG dùng nó để chỉ đường ("chạm dòng
            // bên dưới" sẽ trỏ ngược lên trên).
            //
            // Câu chữ do chủ app chốt 2026-08-13, thay câu cũ "Bắt buộc — đội vẽ cần biết bản vẽ
            // này của căn nào.". CHỈ HIỆN KHI CHƯA CÓ ĐỊA CHỈ: từ 13/08 nó là chỗ DUY NHẤT còn
            // giải thích vì sao nút "Bắt đầu quét" đang xám (dòng nhắc trong `startBar` đã bỏ
            // theo yêu cầu chủ app), mà điền xong rồi thì một câu "vui lòng điền địa chỉ" nằm lại
            // dưới ô đã có chữ chỉ làm khách tưởng mình điền sai.
            if !hasHome {
                Text(L.t(
                    "Please enter the address to continue.",
                    "Vui lòng điền địa chỉ để tiếp tục."
                ))
            }
        }
    }

    /// Đường tắt 1: lấy địa chỉ từ GPS. Nút nổi bật hơn vì đây là đường NHANH NHẤT khi khách
    /// đang đứng ngay tại căn nhà — đúng tình huống của gần như mọi lần quét.
    private var useLocationButton: some View {
        Button {
            addressFocused = false // giấu bàn phím rồi mới xin quyền, không thì hộp thoại đè lên
            addressWhenLocating = address
            locator.requestAddress()
        } label: {
            Label(L.t("Use my location", "Dùng vị trí hiện tại"), systemImage: "location.fill")
                .font(.subheadline.weight(.semibold))
                // TRẮNG tường minh cho CẢ icon lẫn chữ. Trong List, icon của Label bị iOS tô
                // màu tint (accent) bất chấp buttonStyle — accent trên nền borderedProminent
                // cũng accent là mũi tên tàng hình (chủ app báo 2026-07-28: "không thấy icon").
                // Chữ vốn trắng theo style nút nên không ai nhận ra cho tới khi nhìn kỹ.
                //
                // NHƯNG chỉ trắng khi nút CÒN BẤM ĐƯỢC: lúc `.disabled` (đang định vị — quãng
                // này >15s nếu khách ngồi đọc hộp thoại quyền, trap #24) nền capsule chuyển
                // xám nhạt mà chữ vẫn trắng tinh là cả nút thành viên nhộng trống. Ép trắng
                // vô điều kiện chính là lỗi do bản vá đầu của nó đẻ ra (review 2026-07-29).
                .foregroundStyle(
                    locator.state == .working ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.white)
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .disabled(locator.state == .working)
        // `bottom: 8`, không phải 4: số 4 cũ là để nút này dính sát nút "Tìm địa chỉ" ngay dưới
        // thành một cặp. Nút đó đã xoá 13/08, giữ 4 thì nút nằm dí vào dòng gợi ý đầu tiên.
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    // 🔴 `searchAddressButton` (nút kính lúp "Tìm địa chỉ") ĐÃ XOÁ 2026-08-13 — lý do ghi ở
    // `homeSection`. Nó chỉ `addressFocused = true`, tức làm đúng việc mà chạm vào ô nhập đã làm.

    /// Dòng trạng thái của nút vị trí. CHỈ hiện khi có chuyện đang xảy ra — không chiếm chỗ lúc bình thường.
    @ViewBuilder
    private var locationStatusRow: some View {
        switch locator.state {
        case .idle:
            EmptyView()
        case .working:
            HStack(spacing: 8) {
                ProgressView()
                Text(L.t("Finding your address…", "Đang tìm địa chỉ của bạn…"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .denied:
            // Cùng khuôn với alert quyền Camera: nói rõ vì sao + đưa thẳng tới Cài đặt, chứ không
            // để khách đoán. Và nói luôn rằng gõ tay vẫn đi tiếp được — đây KHÔNG phải ngõ cụt.
            VStack(alignment: .leading, spacing: 6) {
                Text(L.t(
                    "Location is off for CedarScan. Turn it on in Settings, or just type the address below.",
                    "CedarScan chưa được cấp quyền vị trí. Bật trong Cài đặt, hoặc cứ gõ địa chỉ bên dưới."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link(L.t("Open Settings", "Mở Cài đặt"), destination: url)
                        .font(.footnote.weight(.semibold))
                }
            }
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Gợi ý địa chỉ của MapKit. Chỉ hiện lúc con trỏ đang ở trong ô nhập — xem `addressFocused`.
    @ViewBuilder
    private var suggestionRows: some View {
        if addressFocused && !completer.suggestions.isEmpty {
            ForEach(completer.suggestions) { suggestion in
                Button {
                    suppressCompleter = true
                    addressFocused = false
                    address = suggestion.full
                    completer.clear()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.circle")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(suggestion.title)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Trạng thái "đang dùng lại căn nào", LUÔN hiện ngay dưới ô nhập khi có lựa chọn.
    ///
    /// Không thể trông vào dấu tích trong danh sách: danh sách có thể dài, có thể bị lọc rỗng,
    /// và dấu tích dễ nằm ngoài màn hình. Cũng không thể dùng footer — footer render SAU mọi
    /// dòng. Dòng này nằm cùng section nên đúng thứ tự, và bản thân nó là LỐI THOÁT duy nhất:
    /// chạm lại một dòng đã chọn không bỏ chọn được, ô nhập rỗng thì cũng không xoá thêm được gì.
    @ViewBuilder
    private var pickedRow: some View {
        if let picked = store.projects.first(where: { $0.id == pickedProjectId }) {
            HStack {
                Label(
                    L.t("Adding to: \(picked.name)", "Thêm vào: \(picked.name)"),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.tint)
                Spacer(minLength: 8)
                Button(L.t("Clear", "Bỏ chọn")) { pickedProjectId = nil }
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
        }
    }

    /// Căn ĐÃ QUÉT trùng với chữ đang gõ — chạm để quét thêm vào đúng căn đó thay vì tạo căn mới.
    ///
    /// Chỉ hiện khi ô nhập CÓ CHỮ và chưa chọn căn nào. Không còn danh sách "tất cả các căn" như
    /// trước — xem lý do ở `matchingProjects`.
    @ViewBuilder
    private var matchingRows: some View {
        if pickedProjectId == nil && !matchingProjects.isEmpty {
            // Không có nhãn này thì mấy dòng bên dưới ô nhập trông như thông tin CHỈ ĐỂ XEM.
            Text(L.t("Already scanned — tap to reuse", "Đã quét — chạm để dùng lại"))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(matchingProjects) { project in
                Button {
                    // KHÔNG xoá `address`: xoá thì `onChange` chạy, `pickedProjectId` vừa gán bị
                    // xoá ngay và danh sách này biến mất dưới ngón tay → người dùng tưởng chạm hụt,
                    // gõ lại, rồi tạo ra căn trùng tên. Giữ nguyên chữ đã gõ thì dòng đứng im.
                    pickedProjectId = project.id
                    addressFocused = false
                } label: {
                    projectRow(project)
                }
            }
        }
    }

    /// Tách thành hàm nhận tham số thay vì viết trong ViewBuilder: cần tính `count` trước khi
    /// dựng view, mà khai báo cục bộ trong thân ViewBuilder là chỗ CI này từng chết vì
    /// "type-check timeout".
    ///
    /// MỘT DÒNG, không phải hai: mỗi dòng hai tầng thì ba căn đã chiếm một mảng lớn màn hình.
    ///
    /// KHÔNG còn dấu tích "đang chọn" trong dòng: `matchingRows` chỉ hiện khi CHƯA chọn căn nào,
    /// nên dấu tích đó vĩnh viễn không bao giờ vẽ ra. Trạng thái "đang thêm vào căn X" nằm ở
    /// `pickedRow`. (Giữ lại một guard đã hết lý do tồn tại là bẫy #3 trong handoff.)
    private func projectRow(_ project: ScanProject) -> some View {
        let count = store.scans(in: project).count
        return HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(project.name)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(L.t("\(count) scan(s)", "\(count) bản quét"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .layoutPriority(1)
        }
    }

    /// Thanh nút ghim đáy màn — LUÔN nhìn thấy, không phụ thuộc danh sách dài bao nhiêu.
    ///
    /// 🔴 DÒNG NHẮC "Điền địa chỉ trước — đội vẽ cần…" ĐÃ XOÁ 2026-08-13 theo yêu cầu chủ app.
    /// Nó từng nằm ngay đây vì footer của section render SAU mọi dòng gợi ý, tức có thể trôi khỏi
    /// màn hình; nay bản đồ chiếm phần trên và section chỉ còn vài dòng nên footer luôn nằm ngay
    /// trên thanh này. Câu giải thích "nút đang xám vì sao" vì vậy CHƯA MẤT — nó chuyển về footer
    /// của `homeSection` ("Vui lòng điền địa chỉ để tiếp tục."), và phải còn ở đâu đó: nút xám mà
    /// không nói vì sao là lỗi UX tệ nhất (cùng khuôn `ProjectView.unsupportedNote`). ✗ xoá nốt
    /// câu bên đó.
    private var startBar: some View {
        VStack(spacing: 6) {
            Button {
                start()
            } label: {
                Text(startLabel)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasHome)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .padding(.top, 8)
        .background(.ultraThinMaterial)
    }

    /// Đã xác định được căn nhà chưa — chạm một dòng trong danh sách HOẶC gõ chữ đều tính.
    /// Chạm dòng mà không gõ gì là đường đi hợp lệ (ô nhập vẫn rỗng), nên KHÔNG được chỉ xét
    /// mỗi `address`.
    private var hasHome: Bool {
        pickedProjectId != nil || !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Nút NÓI THẲNG hậu quả khi sắp tạo căn thứ hai trùng tên. Người dùng đọc chữ trên nút họ
    /// đang bấm, không đọc footer — nên đây là chỗ duy nhất cảnh báo chắc chắn tới được. Rẻ hơn
    /// mọi phương án khác: không thêm state, không thêm chạm, không thêm dòng nào trên màn hình.
    ///
    /// Cố ý KHÔNG chặn: tạo căn riêng cùng tên là việc hợp lệ (hai khách cùng gọi "Nhà chị Lan").
    /// Chỉ cần người dùng biết mình đang làm gì.
    private var startLabel: String {
        if exactMatch != nil {
            return L.t("Create a separate home with this name", "Tạo căn RIÊNG cùng tên")
        }
        return L.t("Start scanning", "Bắt đầu quét")
    }
    // KHÔNG có nút "Bỏ qua": địa chỉ giờ BẮT BUỘC, nút Bắt đầu bị khoá tới khi có căn nhà.
    // (Nút "Bỏ qua" từng tồn tại hồi địa chỉ còn tuỳ chọn — nó vừa thừa vừa dễ lẫn với "Hủy" ở
    // góc trên: hai lựa chọn cạnh nhau mà nghĩa ngược hẳn, Hủy = không quét, Bỏ qua = vẫn quét.)

    /// dismiss() TRƯỚC onStart(): người gọi present màn quét từ onDismiss của sheet này, nên
    /// onStart chỉ được set cờ, không được present gì.
    ///
    /// Chọn dòng trong danh sách → dùng căn đó. Không chọn → tạo căn mới theo chữ đã gõ. Ô rỗng
    /// → nil, bản quét không gắn căn nào (vẫn gắn sau được bằng "Chuyển vào dự án" ở màn chính).
    /// KHÔNG tự gộp khi trùng tên — chỉ nhắc một dòng ở footer rồi để người dùng chạm: gộp nhầm
    /// hai căn khác nhau vào một đơn tệ hơn tách nhầm, vì đội vẽ không có cách nào phát hiện.
    private func start() {
        let id: UUID?
        if let picked = pickedProjectId {
            id = picked
        } else {
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            id = trimmed.isEmpty ? nil : store.createProject(name: trimmed)?.id
        }
        dismiss()
        onStart(id)
    }

    /// Khoá so khớp tên căn nhà. Thân hàm đã dời sang `TextMatch.key` (dùng chung với ô tìm kiếm
    /// ở màn chính và tab Đơn hàng) — đọc chú thích 🔴 về `đ`/`Đ` ở đó trước khi đụng vào.
    private static func matchKey(_ s: String) -> String {
        TextMatch.key(s)
    }
}

/// Bản đồ xác nhận vị trí, nằm TRÊN cụm nhập (chủ app chốt 2026-08-13: *"khi nhập địa chỉ hoặc
/// dùng vị trí hiện tại thì nó hiển thị vị trí đó ngay trong bản đồ để khách xác nhận chính xác
/// vị trí"*).
///
/// 🔴 ĐÂY LÀ **APPLE MAPS (MapKit)**, ✗ Google Maps — dù chủ app gọi tên "google map". Nhúng Google
/// Maps thật đòi SDK bên thứ ba + API key + tài khoản billing của Google, và kéo theo nghĩa vụ mới
/// ở privacy manifest (`PrivacyInfo.xcprivacy`, chú thích số 3: *"THÊM SDK BÊN THỨ BA = PHẢI QUAY
/// LẠI ĐÂY"*) đúng lúc app đang nộp App Store. MapKit đã có sẵn trong app (`AddressLookup` chạy
/// `MKLocalSearchCompleter` từ 2026-07), không thêm một dòng phụ thuộc nào, và cho khách đúng thứ
/// họ cần: nhìn cái ghim để biết đúng nhà hay chưa. Muốn Google Maps thật thì đó là một quyết định
/// riêng — hỏi chủ app kèm ba khoản chi phí trên.
///
/// Bản đồ CHỈ ĐỂ NHÌN: không kéo ghim được, và toạ độ KHÔNG đi kèm đơn hàng (xem 🔴 ở
/// `AddressGeocoder`). Không tra ra ghim cũng không chặn gì — nút "Bắt đầu quét" chỉ nhìn chữ
/// trong ô.
private struct AddressMapView: View {
    let coordinate: CLLocationCoordinate2D?
    let state: AddressPinState

    /// Khung nhìn. Mặc định `.automatic` — có `UserAnnotation` trong nội dung nên khi khách ĐÃ cấp
    /// quyền vị trí thì MapKit tự khung quanh chỗ họ đang đứng, tức thường là chính căn nhà sắp
    /// quét, ngay trước khi gõ chữ nào.
    @State private var camera: MapCameraPosition = .automatic

    /// Bán kính khung khi đã có ghim: đủ rộng để thấy vài nhà hai bên (nhận ra góc phố), đủ hẹp để
    /// phân biệt được nhà này với nhà kế bên — thứ duy nhất khách cần xác nhận ở đây.
    private static let spanMeters: CLLocationDistance = 260

    var body: some View {
        Map(position: $camera) {
            if let coordinate {
                Marker(L.t("This property", "Căn này"), systemImage: "house.fill", coordinate: coordinate)
            }
            // Chấm xanh vị trí máy. CHỈ vẽ khi khách ĐÃ cấp quyền — `Map` của SwiftUI không tự đi
            // xin quyền, quyền vẫn chỉ được xin ở nút "Dùng vị trí hiện tại" (đúng như câu khai
            // `NSLocationWhenInUseUsageDescription` trong project.yml). Nó trả lời đúng câu khách
            // hỏi khi đang đứng trước cửa: "cái ghim kia có phải chỗ tôi đang đứng không?".
            UserAnnotation()
        }
        // `.flat`: không cần nhà nổi 3D — nó chỉ làm chậm và che mất số nhà.
        .mapStyle(.standard(elevation: .flat))
        .overlay(alignment: .bottom) { statusPill }
        // Theo dõi bằng CHUỖI lat/long chứ không phải `CLLocationCoordinate2D`: kiểu đó không
        // Equatable nên `onChange(of:)` không nhận.
        .onChange(of: pinKey) { _, _ in recenter() }
        .onAppear { recenter() }
    }

    private var pinKey: String {
        guard let coordinate else { return "" }
        return "\(coordinate.latitude),\(coordinate.longitude)"
    }

    /// Mất ghim thì GIỮ NGUYÊN khung hình cũ (guard, không reset về `.automatic`): trong lúc khách
    /// sửa vài ký tự cuối của địa chỉ, bản đồ nhảy về mặc định rồi nhảy lại là một cú giật vô nghĩa.
    private func recenter() {
        guard let coordinate else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            camera = .region(MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: Self.spanMeters,
                longitudinalMeters: Self.spanMeters
            ))
        }
    }

    /// Dải chữ nhỏ ở đáy bản đồ — CHỈ hiện khi CHƯA có ghim. Có ghim rồi thì cái ghim tự nói, thêm
    /// chữ chỉ che mất bản đồ.
    @ViewBuilder
    private var statusPill: some View {
        if state != .found {
            Text(pillText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
    }

    /// 🔴 Câu cho `.notFound` phải nói NGAY rằng vẫn quét được. Ô địa chỉ nhận CHỮ TỰ DO (tên kiểu
    /// "Nhà chị Lan" là dữ liệu hợp lệ) và mất mạng cũng rơi vào đây — một câu cụt kiểu "không tìm
    /// thấy địa chỉ" trên màn BẮT BUỘC sẽ làm khách tưởng mình bị chặn và quay ra sửa chữ đã đúng.
    private var pillText: String {
        switch state {
        case .searching:
            return L.t("Finding it on the map…", "Đang tìm trên bản đồ…")
        case .notFound:
            return L.t(
                "Not on the map — you can still scan.",
                "Không thấy trên bản đồ — vẫn quét được bình thường."
            )
        case .idle, .found:
            return L.t("Type the address to see it here", "Nhập địa chỉ để xem trên bản đồ")
        }
    }
}
