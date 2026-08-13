import CoreLocation
import Foundation
import MapKit

/// Ba thứ phục vụ ô địa chỉ ở `ScanAddressView`:
///  • `LocationLookup` — "Dùng vị trí hiện tại": xin quyền → lấy toạ độ MỘT LẦN → đổi ra địa chỉ.
///  • `AddressCompleter` — gõ tới đâu gợi ý tới đó (MapKit).
///  • `AddressGeocoder` — chiều NGƯỢC LẠI: chữ trong ô → toạ độ, để ghim lên bản đồ xác nhận.
///
/// 🔴 CẢ BA CHỈ LÀ ĐƯỜNG PHỤ. Ô nhập chữ tự do vẫn là đường chính và PHẢI luôn đi tiếp được:
/// app này dùng ở công trường — trong nhà bê tông GPS mù, 4G chập chờn, và khách hoàn toàn có
/// quyền từ chối cấp quyền vị trí. Mọi lỗi ở đây đều chỉ dẫn tới "không có gợi ý"/"không có ghim
/// trên bản đồ", không bao giờ chặn nút "Bắt đầu quét".

// MARK: - Vị trí hiện tại → địa chỉ

@MainActor
final class LocationLookup: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case working
        /// Khách từ chối quyền (hoặc thiết bị bị khoá quyền) — cần đưa họ sang Cài đặt.
        case denied
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Địa chỉ vừa tra được. View lắng nghe giá trị này rồi đổ vào ô nhập.
    /// KHÔNG tự ghi thẳng vào ô nhập từ đây: `ScanAddressView` sở hữu ô đó và có `onChange` riêng
    /// (xoá căn đang chọn) — để hai nơi cùng ghi là mất dấu ai ghi đè ai.
    @Published var resolvedAddress: String?
    /// Toạ độ đã sinh ra `resolvedAddress` ngay trước đó. Bản đồ xác nhận ghim THẲNG vào đây thay
    /// vì gõ lại địa chỉ vừa tra vào `AddressGeocoder` — chuyến đi vòng đó vừa tốn thêm một lượt
    /// gọi mạng vừa có thể trả về MỘT CHỖ KHÁC (geocode xuôi của một chuỗi rút gọn không hứa quay
    /// lại đúng điểm đã reverse-geocode ra nó).
    ///
    /// ✗ dọn về nil sau khi dùng như `resolvedAddress`: đây là dữ liệu ĐI KÈM, view đọc nó ngay
    /// trong `onChange` của `resolvedAddress` nên vòng đời do chuỗi kia quyết định.
    @Published private(set) var lastCoordinate: CLLocationCoordinate2D?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    /// Đang chờ KẾT QUẢ HỎI QUYỀN của đúng lần bấm này. Không có cờ, callback đổi quyền của hệ
    /// thống (chạy cả lúc app vừa mở) sẽ tự đi lấy vị trí mà khách chưa bấm gì.
    private var waitingForPermission = false
    /// Van thời gian cho trạng thái `.working`.
    ///
    /// 🔴 BẮT BUỘC phải có: CoreLocation KHÔNG hứa luôn gọi lại. Ca thật đã biết — Location
    /// Services bị TẮT CẢ MÁY: iOS hiện hộp "Turn On Location Services", `authorizationStatus`
    /// đứng nguyên `.notDetermined`, và nếu khách bấm "Cancel" thì KHÔNG callback nào chạy. Không
    /// có van này thì `state` kẹt `.working` vĩnh viễn: spinner quay mãi, và chính nó khoá nút
    /// (`.disabled(state == .working)`) nên khách không bấm lại được — lối thoát duy nhất là đóng
    /// cả màn hình. GPS trong nhà bê tông cũng ra đúng cảnh đó, chỉ khác là chờ lâu hơn.
    private var watchdog: Task<Void, Never>?
    private static let timeoutSeconds: UInt64 = 15

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func requestAddress() {
        resolvedAddress = nil
        switch manager.authorizationStatus {
        case .notDetermined:
            waitingForPermission = true
            // 🔴 CHƯA bật van thời gian ở nhánh này. Van chỉ được đếm quãng CHỜ GPS, không đếm
            // quãng khách ĐỌC HỘP THOẠI QUYỀN. Bản vá đầu bật van ngay đây và tự đẻ lỗi mới:
            // hộp thoại quyền lần-đầu-đời có một câu tiếng Anh dài, khách đọc quá 15 giây là
            // chuyện thường; van bắn, xoá `waitingForPermission`, rồi khách bấm "Allow" thì
            // callback bị `guard waitingForPermission` chặn → `requestLocation()` KHÔNG BAO GIỜ
            // chạy, màn hình vẫn nói "chưa tìm được vị trí". Bấm "Don't Allow" cũng hỏng đối
            // xứng: state kẹt `.failed` nên khối `.denied` kèm nút "Mở Cài đặt" không hiện.
            // Van được bật trong `locationManagerDidChangeAuthorization`, SAU khi có quyền.
            state = .working
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            beginWorking()
            manager.requestLocation()
        case .denied, .restricted:
            state = .denied
        @unknown default:
            state = .denied
        }
    }

    private func beginWorking() {
        state = .working
        watchdog?.cancel()
        // `Task {}` dựng từ ngữ cảnh @MainActor nên THÂN NÓ CŨNG @MainActor (@_inheritActorContext)
        // — đọc/ghi `state` thẳng ở đây là hợp lệ, không cần `MainActor.run` lồng thêm.
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.timeoutSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.state == .working else { return }
            // KHÔNG đụng `waitingForPermission` ở đây — van này chỉ được bật khi đã qua cửa xin
            // quyền, và xoá cờ đó là cắt đứt callback quyền còn đang chờ (xem chú thích ở nhánh
            // `.notDetermined`).
            self.state = .failed(L.t(
                "Still looking… no luck. Type the address instead.",
                "Chưa tìm được vị trí. Bạn nhập địa chỉ bằng tay nhé."
            ))
        }
    }

    /// Kết thúc một lượt: tắt van thời gian. Gọi ở MỌI đường ra của `.working`.
    private func finishWorking() {
        watchdog?.cancel()
        watchdog = nil
    }

    /// Gộp placemark thành một dòng địa chỉ đọc được. Bỏ phần rỗng thay vì để lại dấu phẩy treo.
    ///
    /// KHÔNG dùng `CNPostalAddressFormatter`: nó xuống dòng theo kiểu phong bì thư, mà chỗ này cần
    /// đúng MỘT dòng để vừa ô nhập và vừa tên dự án.
    nonisolated static func format(_ placemark: CLPlacemark) -> String {
        let street = [placemark.subThoroughfare, placemark.thoroughfare]
            .compactMap { $0 }
            .joined(separator: " ")
        let parts = [
            street,
            placemark.locality ?? "",
            [placemark.administrativeArea ?? "", placemark.postalCode ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: " "),
        ]
        return parts
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

extension LocationLookup: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            let authorized = status == .authorizedWhenInUse || status == .authorizedAlways
            // Khách vừa vào Cài đặt BẬT quyền rồi quay lại app: dọn thông báo lỗi cũ đi, không thì
            // màn hình cứ nói app không có quyền trong khi quyền đã có — khách vừa làm đúng điều
            // app dặn mà app không phản hồi gì, và sẽ kết luận là nút hỏng.
            // Dọn CẢ `.failed` chứ không riêng `.denied`: van thời gian để lại `.failed`, và một
            // dòng "chưa tìm được vị trí" nằm lì sau khi quyền đã bật cũng sai y như vậy.
            // CHỈ dọn thông báo, KHÔNG tự đi lấy vị trí: nguyên tắc "chỉ chạy khi khách bấm".
            if authorized, self.state != .working {
                self.state = .idle
            }
            // Chỉ phản ứng với đúng lần khách vừa bấm nút. Callback này còn chạy lúc app khởi
            // động và mỗi lần khách đổi quyền trong Cài đặt rồi quay lại.
            guard self.waitingForPermission else { return }
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                self.waitingForPermission = false
                // GIỜ mới bật van: từ đây trở đi là quãng chờ GPS thật, không còn hộp thoại nào
                // che màn hình nữa.
                self.beginWorking()
                self.manager.requestLocation()
            case .denied, .restricted:
                self.waitingForPermission = false
                self.finishWorking()
                self.state = .denied
            case .notDetermined:
                break // hộp thoại còn đang hiện — cứ chờ (van thời gian vẫn đang đếm)
            @unknown default:
                self.waitingForPermission = false
                self.finishWorking()
                self.state = .denied
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        // Rút TOẠ ĐỘ (struct) ra trước rồi mới vào Task, không mang `CLLocation` (class, không
        // Sendable) qua ranh giới actor — đó là kiểu cảnh báo/lỗi concurrency dễ dính nhất.
        Task { @MainActor in
            await self.reverseGeocode(
                CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            )
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Quyền vừa bị từ chối cũng rơi vào đây trên vài phiên bản iOS — ưu tiên nói đúng chuyện.
        let isDenied = (error as? CLError)?.code == .denied
        Task { @MainActor in
            self.finishWorking()
            if isDenied {
                self.state = .denied
            } else {
                self.state = .failed(L.t(
                    "Could not get your location. Type the address instead.",
                    "Không lấy được vị trí. Bạn nhập địa chỉ bằng tay nhé."
                ))
            }
        }
    }

    private func reverseGeocode(_ location: CLLocation) async {
        // KHÔNG tắt van thời gian ở đây mà tắt ở từng ĐƯỜNG RA bên dưới: bước geocode cũng cần
        // mạng và cũng có thể treo. Van tự kiểm `state == .working` trước khi bắn nên nếu geocode
        // về kịp thì nó là no-op — tắt sớm chỉ mở lại đúng cái cửa vừa bịt.
        do {
            let places = try await geocoder.reverseGeocodeLocation(location)
            let text = places.first.map(Self.format) ?? ""
            finishWorking()
            // Ghi toạ độ TRƯỚC `resolvedAddress`: view đọc `lastCoordinate` bên trong `onChange`
            // của `resolvedAddress`, nên thứ tự ngược lại là view đọc trúng toạ độ của lần trước.
            lastCoordinate = location.coordinate
            if text.isEmpty {
                state = .failed(L.t(
                    "No street address found here. Type it instead.",
                    "Không tra được địa chỉ ở đây. Bạn nhập bằng tay nhé."
                ))
            } else {
                resolvedAddress = text
                state = .idle
            }
        } catch {
            finishWorking()
            // Reverse geocode cần MẠNG. Trong nhà bê tông có GPS mà không có sóng là chuyện thường.
            state = .failed(L.t(
                "Could not look up the address (no connection?). Type it instead.",
                "Không tra được địa chỉ (mất mạng?). Bạn nhập bằng tay nhé."
            ))
        }
    }
}

// MARK: - Gợi ý địa chỉ khi gõ

/// Một dòng gợi ý. `id` dựng từ chính nội dung — `MKLocalSearchCompletion` không Identifiable.
struct AddressSuggestion: Identifiable, Hashable {
    let title: String
    let subtitle: String
    var id: String { title + "|" + subtitle }

    /// Chuỗi đổ vào ô nhập. Bỏ phần đuôi trùng lặp ("123 Main St" + "123 Main St, Dallas").
    var full: String {
        if subtitle.isEmpty { return title }
        if subtitle.contains(title) { return subtitle }
        return title + ", " + subtitle
    }
}

/// Bao nhiêu dòng gợi ý hiện tối đa. Nhiều hơn là nuốt mất phần "căn đã quét" ngay dưới nó.
/// Hằng số ĐỂ NGOÀI class: nó bị đọc từ callback `nonisolated` của MapKit, mà `static` của một
/// class `@MainActor` thì thuộc về actor đó.
private let addressSuggestionRowLimit = 4

@MainActor
final class AddressCompleter: NSObject, ObservableObject {
    @Published private(set) var suggestions: [AddressSuggestion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        // Chỉ địa chỉ — không gợi ý quán cà phê, cây xăng. Khách đang khai một CĂN NHÀ.
        completer.resultTypes = .address
    }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Dưới 3 ký tự thì gợi ý toàn rác, mà mỗi lần đổi `queryFragment` là một lượt gọi mạng.
        guard trimmed.count >= 3 else {
            suggestions = []
            completer.queryFragment = ""
            return
        }
        completer.queryFragment = trimmed
    }

    func clear() {
        suggestions = []
        completer.queryFragment = ""
    }
}

// MARK: - Địa chỉ → toạ độ (ghim lên bản đồ xác nhận)

/// Trạng thái của cái ghim — bản đồ đọc để biết in câu gì lên dải chú thích.
///
/// Khai Ở NGOÀI `AddressGeocoder` chứ không lồng bên trong: class kia là `@MainActor`, mà một kiểu
/// lồng trong nó có nguy cơ được suy ra là cùng isolation — lúc đó `==` do Swift tự sinh cũng thành
/// `@MainActor` và mọi chỗ so sánh nằm ngoài main actor (các computed property phụ của một View —
/// chỉ `body` mới là `@MainActor`) đều đẻ cảnh báo concurrency. Máy dev không compile được nên thứ
/// duy nhất bắt được nó là CI; rẻ hơn thì đừng tạo ra nó.
enum AddressPinState: Equatable {
    /// Chưa đủ chữ để tra (mở màn, hoặc khách mới gõ vài ký tự).
    case idle
    case searching
    case found
    /// Tra xong mà không ra chỗ nào (hoặc mất mạng). ✗ coi là lỗi: ô địa chỉ nhận CHỮ TỰ DO, tên
    /// kiểu "Nhà chị Lan" vốn không phải địa chỉ nào trên bản đồ mà vẫn là dữ liệu hợp lệ.
    case notFound
}

/// Chiều ngược của `LocationLookup`: chữ trong ô địa chỉ → một toạ độ để ghim lên bản đồ ở đầu
/// màn `ScanAddressView` (chủ app chốt 2026-08-13: khách phải NHÌN THẤY chỗ mình sắp quét).
///
/// 🔴 TOẠ ĐỘ Ở ĐÂY CHỈ ĐỂ NHÌN. Thứ đi tới đội vẽ vẫn là CHỮ trong ô nhập (`ScanAddressView.start`
/// tạo dự án bằng chuỗi đó) — không có lat/long nào rời máy đi tới server của Cedar247. Đây là
/// điều kiện để privacy manifest tiếp tục KHÔNG khai `Location`: đọc chú thích số 2 ở đầu
/// `PrivacyInfo.xcprivacy` trước khi ai đó định gửi kèm toạ độ lên đơn hàng.
///
/// Vì sao `MKLocalSearch` chứ không phải `CLGeocoder.geocodeAddressString`: `CLGeocoder` bị Apple
/// bóp lưu lượng rất gắt (gọi dồn là trả lỗi `.network` cho CẢ những lượt sau), mà ô này bắn theo
/// từng phím gõ. `MKLocalSearch` là cùng dịch vụ đang chạy cho danh sách gợi ý ngay bên dưới ô.
@MainActor
final class AddressGeocoder: ObservableObject {
    @Published private(set) var state: AddressPinState = .idle
    @Published private(set) var coordinate: CLLocationCoordinate2D?

    private var task: Task<Void, Never>?
    /// Chuỗi ứng với `coordinate` đang giữ. Có nó thì `update` gọi lại bằng đúng chuỗi cũ là no-op
    /// — cần thiết vì nút "Dùng vị trí hiện tại" ghim toạ độ THẬT trước, rồi mới đổ chữ vào ô và
    /// làm `onChange` bắn `update`; thiếu mốc này thì cái ghim chính xác đó bị một lượt tra chữ
    /// vòng vo đè lên.
    private var pinnedKey = ""

    /// Chờ ngần này rồi mới bắn — người gõ địa chỉ tay sinh ~10 phím/giây, không debounce là mỗi
    /// địa chỉ tốn cả chục lượt gọi mạng cho đúng một cái ghim.
    private static let debounceNanoseconds: UInt64 = 800_000_000
    /// Dưới ngần này ký tự thì mọi kết quả đều là rác — và ô này còn nhận cả tên gọi, không riêng
    /// địa chỉ.
    private static let minimumQueryLength = 5

    /// Ghim thẳng một toạ độ đã biết chắc (nút "Dùng vị trí hiện tại"), khỏi tra lại.
    func pin(_ coordinate: CLLocationCoordinate2D, for address: String) {
        task?.cancel()
        task = nil
        pinnedKey = Self.key(address)
        self.coordinate = coordinate
        state = .found
    }

    func update(address: String) {
        let key = Self.key(address)
        guard key != pinnedKey else { return } // đúng chuỗi đang ghim — giữ nguyên ghim
        task?.cancel()
        task = nil
        pinnedKey = ""
        // XOÁ ghim cũ NGAY khi chữ đổi, đừng chờ kết quả mới về. Giữ lại cái ghim của địa chỉ
        // TRƯỚC trong lúc khách đã gõ sang địa chỉ KHÁC là bản đồ nói dối đúng chỗ nó sinh ra để
        // nói thật — mà màn này tồn tại để khách XÁC NHẬN vị trí.
        coordinate = nil
        guard key.count >= Self.minimumQueryLength else {
            state = .idle
            return
        }
        state = .searching
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.search(address, key: key)
        }
    }

    // ✗ thêm `clear()` cho "đối xứng" với `AddressCompleter.clear()`: KHÔNG có đường nào cần nó.
    // Ô địa chỉ về rỗng thì chính `update("")` đã trả về `.idle` và bỏ ghim; còn lúc khách chạm một
    // căn đã quét thì chữ trong ô ĐỨNG NGUYÊN (cố ý — xem `matchingRows`) nên cái ghim cũng phải
    // đứng nguyên. Một hàm dọn không ai gọi là thứ phiên sau sẽ gọi nhầm chỗ.

    private func search(_ address: String, key: String) async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = address
        request.resultTypes = .address // ✗ quán xá/cửa hàng — khách đang khai một CĂN NHÀ
        do {
            let response = try await MKLocalSearch(request: request).start()
            // Lượt tra CŨ về muộn hơn lượt mới: `update` đã cancel task này rồi, bỏ kết quả đi.
            guard !Task.isCancelled else { return }
            if let place = response.mapItems.first {
                coordinate = place.placemark.coordinate
                pinnedKey = key
                state = .found
            } else {
                state = .notFound
            }
        } catch {
            // Mất mạng / không có kết quả (`MKError.placemarkNotFound`) → KHÔNG báo lỗi đỏ ở đâu
            // cả, chỉ là không có ghim. Bản đồ là phần phụ; nút "Bắt đầu quét" không đụng tới nó.
            guard !Task.isCancelled else { return }
            state = .notFound
        }
    }

    /// So chuỗi "có phải vẫn là địa chỉ đó không" — CỐ Ý KHÔNG dùng `TextMatch.key`: hàm kia bóc
    /// dấu tiếng Việt và dấu câu để so TÊN CĂN NHÀ với nhau, còn ở đây chỉ cần biết chữ trong ô có
    /// đổi hay không.
    private static func key(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension AddressCompleter: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let rows = completer.results.prefix(addressSuggestionRowLimit).map {
            AddressSuggestion(title: $0.title, subtitle: $0.subtitle)
        }
        Task { @MainActor in
            self.suggestions = rows
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        // Mất mạng / MapKit từ chối → KHÔNG báo lỗi gì cả. Gợi ý là tiện ích phụ; một banner đỏ ở
        // đây chỉ làm khách tưởng mình không quét được, trong khi gõ tay vẫn đi tiếp bình thường.
        Task { @MainActor in
            self.suggestions = []
        }
    }
}
