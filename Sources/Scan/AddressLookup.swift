import CoreLocation
import Foundation
import MapKit

/// Hai thứ giúp khách điền địa chỉ nhanh ở `ScanAddressView`:
///  • `LocationLookup` — "Dùng vị trí hiện tại": xin quyền → lấy toạ độ MỘT LẦN → đổi ra địa chỉ.
///  • `AddressCompleter` — gõ tới đâu gợi ý tới đó (MapKit).
///
/// 🔴 CẢ HAI CHỈ LÀ ĐƯỜNG TẮT. Ô nhập chữ tự do vẫn là đường chính và PHẢI luôn đi tiếp được:
/// app này dùng ở công trường — trong nhà bê tông GPS mù, 4G chập chờn, và khách hoàn toàn có
/// quyền từ chối cấp quyền vị trí. Mọi lỗi ở đây đều chỉ dẫn tới "không có gợi ý", không bao giờ
/// chặn nút "Bắt đầu quét".

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
