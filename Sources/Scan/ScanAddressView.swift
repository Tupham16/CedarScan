import Foundation
import SwiftUI
import UIKit // UIApplication.openSettingsURLString — đưa khách sang Cài đặt khi quyền vị trí bị tắt

/// Màn chèn giữa nút Quét và màn quét: gắn bản quét sắp tới vào một CĂN NHÀ (dự án), rồi chọn
/// độ nét. Thay cho sheet chỉ-chọn-độ-nét của P2 — gộp vào một màn để không thêm một chạm.
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

    @AppStorage("meshQuality") private var meshQuality: MeshQuality = MeshQuality.storageDefault
    @State private var address = ""
    @State private var pickedProjectId: UUID?
    /// "Dùng vị trí hiện tại" + gợi ý địa chỉ khi gõ. Cả hai là ĐƯỜNG TẮT — xem `AddressLookup.swift`.
    @StateObject private var locator = LocationLookup()
    @StateObject private var completer = AddressCompleter()
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
            // Tách từng Section thành computed property riêng — CI từng timeout type-check
            // với biểu thức SwiftUI lớn, và Form nhiều section là đúng dạng dễ dính.
            Form {
                homeSection
                qualitySection
            }
            .navigationTitle(L.t("Before scanning", "Trước khi quét"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("Cancel", "Hủy")) { dismiss() }
                }
            }
            // Nút GHIM ĐÁY, không nằm trong Form nữa.
            //
            // Trước đây nó là section CUỐI của Form, tức nằm SAU danh sách căn đã quét — mà danh
            // sách đó không giới hạn số dòng. Khách có nhiều căn là nút bị đẩy khỏi màn hình và
            // phải cuộn xuống đáy mới bấm được (chủ app báo 2026-07-20). Nút chính của một màn
            // bắt buộc thì không được phụ thuộc vào việc người dùng có bao nhiêu dữ liệu cũ.
            // Cùng khuôn với HomeView/ProjectView — cả hai đã ghim nút quét bằng safeAreaInset.
            .safeAreaInset(edge: .bottom) {
                startBar
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
                address = newValue
                completer.clear()
            }
        }
    }

    /// Thứ tự các dòng trong mục này KHÔNG tuỳ tiện (chủ app chốt 2026-07-23):
    /// ô nhập → nút "Dùng vị trí hiện tại" → nút "Tìm địa chỉ" → trạng thái định vị →
    /// **căn đã quét trùng tên** → gợi ý địa chỉ MapKit → dòng "đang thêm vào căn X".
    ///
    /// 🔴 HAI NÚT ĐỨNG SÁT NHAU VÀ NGAY DƯỚI Ô NHẬP, MỌI THỨ ĐỘNG NẰM DƯỚI CHÚNG. Đây là lý do:
    /// trạng thái định vị, danh sách căn trùng và gợi ý MapKit đều là những dòng XUẤT HIỆN/BIẾN
    /// MẤT theo lúc. Nếu chen bất kỳ dòng nào trong số đó vào giữa hoặc lên trên hai nút thì hai
    /// nút sẽ NHẢY xuống ngay lúc người dùng đang nhắm ngón tay vào chúng — cùng lớp lỗi với bẫy
    /// #2 ở handoff ("dòng vừa chạm nhảy đi → người dùng tưởng chạm hụt").
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
                if suppressCompleter {
                    suppressCompleter = false
                    completer.clear()
                } else {
                    completer.update(query: newValue)
                }
            }
            useLocationButton
            searchAddressButton
            locationStatusRow
            matchingRows
            suggestionRows
            pickedRow
        } header: {
            Text(L.t("Property address", "Địa chỉ căn nhà"))
        } footer: {
            // Footer render SAU mọi dòng của section, nên KHÔNG dùng nó để chỉ đường ("chạm dòng
            // bên dưới" sẽ trỏ ngược lên trên). Giữ đúng một câu chung, không đổi theo tình huống
            // — việc cảnh báo trùng tên đã chuyển lên chữ trên NÚT, chỗ người dùng thật sự đọc.
            Text(L.t(
                "Required — the drafting team needs to know which home the drawing is for.",
                "Bắt buộc — đội vẽ cần biết bản vẽ này của căn nào."
            ))
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
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .disabled(locator.state == .working)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
    }

    /// Đường tắt 2: tự gõ. KHÔNG mở màn nào cả — nó đưa con trỏ lên chính ô nhập ngay phía TRÊN
    /// và bật danh sách gợi ý. Làm thành một màn riêng thì khách gõ xong lại phải quay về đây;
    /// làm thành một chế độ ẩn/hiện thì ô nhập biến mất trước mắt người đang định gõ.
    private var searchAddressButton: some View {
        Button {
            addressFocused = true
        } label: {
            Label(L.t("Search address", "Tìm địa chỉ"), systemImage: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
    }

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

    private var qualitySection: some View {
        Section(L.t("Mesh detail", "Độ nét mesh")) {
            Picker(L.t("Mesh detail", "Độ nét mesh"), selection: $meshQuality) {
                ForEach(MeshQuality.allCases) { q in
                    Text(q.label).tag(q)
                }
            }
            .pickerStyle(.segmented)
            Text(meshQuality.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(MeshQuality.sharedNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Thanh nút ghim đáy màn — LUÔN nhìn thấy, không phụ thuộc danh sách dài bao nhiêu.
    ///
    /// Lý do nút xám nằm NGAY TRONG thanh, không trông vào footer của section: từ khi ghim đáy,
    /// nút hiện ngay lúc mở màn, còn footer "Bắt buộc — đội vẽ cần biết…" render SAU mọi dòng gợi
    /// ý nên với khách đã có vài căn thì nó nằm dưới đáy màn. Nút xám mà không nói vì sao là lỗi
    /// UX tệ nhất — cùng khuôn nút-xám-kèm-lý-do của `ProjectView.unsupportedNote`.
    private var startBar: some View {
        VStack(spacing: 6) {
            if !hasHome {
                Text(L.t(
                    "Enter the address first — the drafting team needs it.",
                    "Điền địa chỉ trước — đội vẽ cần biết bản vẽ này của căn nào."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
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

    /// dismiss() TRƯỚC onStart() — cùng khuôn với ScanQualityPickerView: người gọi present màn quét
    /// từ onDismiss của sheet này, nên onStart chỉ được set cờ, không được present gì.
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
