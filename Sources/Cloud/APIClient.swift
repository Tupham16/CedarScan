import Foundation

// MARK: - DTO (khớp với API app.cedar247.com/api/app/v1)

struct CustomerDTO: Codable {
    let id: String
    let email: String
    let name: String
}

struct AuthResponse: Decodable {
    let token: String
    let customer: CustomerDTO
    let emailVerified: Bool?
}

struct MeResponse: Decodable {
    let customer: CustomerDTO
    let emailVerified: Bool?
}

struct OKResponse: Decodable {
    let ok: Bool
}

struct UploadSlot: Decodable {
    let kind: String
    let putUrl: String
    let contentType: String
    let publicUrl: String
}

struct CreateScanResponse: Decodable {
    let scanId: String
    let uploads: [UploadSlot]
}

struct CompleteScanResponse: Decodable {
    let scanId: String
    let status: String
}

struct OrderScanResponse: Decodable {
    let orderId: String
    let orderNumber: String
    let status: String
    let total: Int?
    let currency: String?
    let paymentUrl: String?
    let discount: Double?
    let couponApplied: Bool?
    let free: Bool?
    let hasTour: Bool? // đơn có add-on Virtual Tour → mời khách thêm ảnh phòng ngay
}

// MARK: Bảng giá dịch vụ

struct CatalogPackage: Decodable, Identifiable {
    let id: String
    let name: String
    let price: Int
    let isDefault: Bool
}

struct CatalogAddon: Decodable, Identifiable {
    let id: String
    let name: String
    let price: Int
}

struct CatalogSurcharge: Decodable {
    let overSqFt: Double
    let fee: Int
}

struct OrderDefaults: Decodable {
    let packageId: String?
    let addonIds: [String]?
    let unitSystem: String?
    let language: String?
    let floorNaming: String?
}

struct CatalogResponse: Decodable {
    let currency: String
    let packages: [CatalogPackage]
    let addons: [CatalogAddon]
    let areaSurcharges: [CatalogSurcharge]
    let freeFirstOrders: Int?
    let freeOrdersRemaining: Int?
    let defaults: OrderDefaults?
    let scanQuality: ScanQualityConfig? // ngưỡng Accuracy Suite — server tinh chỉnh từ xa
}

struct DeliveryFileDTO: Decodable, Hashable {
    let fileName: String
    let url: String
    let sizeLabel: String?
}

struct OrderDTO: Decodable, Identifiable {
    let orderId: String
    let orderNumber: String
    let scanId: String?
    /// MỌI bản quét thuộc đơn (đơn nhiều tầng). Server đã trả sẵn (orders/route.ts:67) nhưng
    /// app trước đây chỉ decode `scanId` số ít — tức chỉ thấy TẦNG ĐẦU TIÊN.
    /// Optional để bản server cũ không làm hỏng decode cả danh sách đơn.
    let scanIds: [String]?
    let scanName: String?
    let status: String
    let placedAt: String
    let deliveredAt: String?
    let deliveredUrl: String?
    let deliveryFiles: [DeliveryFileDTO]
    let total: Int?
    let currency: String?
    let paid: Bool?
    let paymentUrl: String?
    // Virtual Tour add-on
    let hasTour: Bool?
    let tourPhotoCount: Int?
    let tourUrl: String? // chỉ có sau khi đơn được giao (tour đã publish)

    var id: String { orderId }

    /// Mọi bản quét thuộc đơn. `scanIds` là nguồn ĐÚNG; `scanId` chỉ là tầng đầu tiên
    /// (orders/route.ts:65 lấy `orderScans[0]`), giữ làm phao cho server cũ.
    var allScanIds: [String] {
        if let ids = scanIds, !ids.isEmpty { return ids }
        return [scanId].compactMap { $0 }
    }

    /// Khách ĐÃ CẦM ĐƯỢC thành phẩm NẰM TRÊN HẠ TẦNG CỦA CHỦ APP — điều kiện cho phép xoá dữ
    /// liệu quét trên máy họ.
    ///
    /// ĐÒI `deliveryFiles` KHÔNG RỖNG, và CỐ Ý KHÔNG chấp nhận `deliveredUrl` một mình:
    /// `deliveredUrl` có thể là link nhân viên gõ tay (`board-actions.ts` `buildDeliveryTarget`
    /// trả thẳng `order.deliveryLink` nếu ô đó có chữ) — tức có thể là Dropbox/WeTransfer của
    /// bên thứ ba, hết hạn lúc nào không biết. Tiền đề của cả tính năng này là "dữ liệu vẫn nằm
    /// trên R2 của chủ app"; một cái link ngoài KHÔNG chứng minh được điều đó.
    ///
    /// `deliveredAt` một mình cũng không đủ: nó là cột DB trả thô, không gate theo stage.
    /// ĐÒI `deliveredAt` PHẢI SAU `placedAt` một khoảng có nghĩa: `woo-sync.ts:116` gieo
    /// `deliveredAt = placedAt` cho đơn Woo về ở trạng thái "completed" (auto-complete là mặc
    /// định rất phổ biến với sản phẩm số). Khi đó mốc "đã giao" thực chất là mốc ĐẶT HÀNG, và
    /// cửa sổ 14 ngày đã tiêu hết trước khi khách nhận được bất cứ thứ gì — nhân viên vừa tải
    /// file giao lên là bản quét bị xoá ngay lần khách mở app kế tiếp.
    var isDeliveredToCustomer: Bool {
        guard !deliveryFiles.isEmpty,
              let delivered = Self.isoDate(deliveredAt ?? ""),
              let placed = Self.isoDate(placedAt) else { return false }
        return delivered.timeIntervalSince(placed) > 60
    }

    /// Đã giao được ÍT NHẤT `days` ngày chưa.
    ///
    /// Vì sao cần độ trễ: **giao hàng CÓ THỂ BỊ ĐẢO NGƯỢC.** Khách bấm "Yêu cầu sửa" thì
    /// `revision/route.ts` đẩy `stage` về `"fix"`, và `orders/route.ts` tính
    /// `delivered = stage === "done"` nên lập tức trả `deliveryFiles: []`. Nếu app đã xoá sạch
    /// dữ liệu gốc ngay lúc giao, khách rơi vào cảnh TRẮNG TAY suốt vòng sửa: không còn file
    /// thành phẩm (server đã thu về), cũng không còn bản quét (máy đã dọn).
    /// Giữ thêm vài ngày là đủ để vòng sửa kịp xảy ra.
    ///
    /// Parse hỏng → trả `false` (không xoá). Không chắc thì đừng đụng vào dữ liệu của khách.
    func wasDeliveredAtLeast(daysAgo days: Int, now: Date = Date()) -> Bool {
        guard let raw = deliveredAt, let date = Self.isoDate(raw) else { return false }
        return now.timeIntervalSince(date) >= Double(days) * 86_400
    }

    /// Server dùng `Date.toISOString()` — LUÔN có mili-giây. Nhưng thử cả hai dạng: một thay đổi
    /// nhỏ phía server mà parse hỏng thì `wasDeliveredAtLeast` trả false mãi và app không bao
    /// giờ dọn nữa — hỏng thầm lặng, không ai biết.
    private static func isoDate(_ raw: String) -> Date? {
        let withMs = ISO8601DateFormatter()
        withMs.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withMs.date(from: raw) { return d }
        return ISO8601DateFormatter().date(from: raw)
    }
}

struct OrdersResponse: Decodable {
    let orders: [OrderDTO]
}

// MARK: Virtual Tour (khách upload ảnh listing theo phòng)

struct TourScanDTO: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
}

struct TourPhotoDTO: Decodable, Identifiable, Hashable {
    let id: String
    let roomLabel: String
    let scanId: String?
    let url: String
    let status: String // "pending" | "ready"
    let sizeLabel: String?
}

struct OrderTourResponse: Decodable {
    let hasTour: Bool
    let status: String? // "draft" | "published"
    let title: String?
    let tourUrl: String?
    let maxPerRoom: Int?
    let maxTotal: Int?
    let scans: [TourScanDTO]?
    let photos: [TourPhotoDTO]?
}

struct TourPhotoSlotResponse: Decodable {
    let photoId: String
    let roomLabel: String
    let scanId: String?
    let putUrl: String
    let contentType: String
    let maxBytes: Int
    let publicUrl: String
}

struct TourPhotoCompleteResponse: Decodable {
    let photoId: String
    let status: String
    let url: String
}

struct APIError: LocalizedError {
    let message: String
    let statusCode: Int
    var errorDescription: String? { message }
}

// MARK: - Client

final class APIClient {
    static let shared = APIClient()

    let baseURL = URL(string: "https://app.cedar247.com/api/app/v1")!
    var token: String?

    private struct ServerError: Decodable { let error: String }

    private func makeRequest(path: String, method: String, json: [String: Any]?) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 30
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return request
    }

    private func send<T: Decodable>(_ path: String, method: String = "GET", json: [String: Any]? = nil) async throws -> T {
        let request = try makeRequest(path: path, method: method, json: json)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200...299).contains(status) {
            let message = (try? JSONDecoder().decode(ServerError.self, from: data))?.error
            throw APIError(
                message: message ?? L.t("Something went wrong. Please try again.", "Có lỗi xảy ra. Vui lòng thử lại."),
                statusCode: status
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Auth

    func register(email: String, password: String, name: String) async throws -> AuthResponse {
        try await send("auth/register", method: "POST", json: [
            "email": email, "password": password, "name": name, "deviceId": DeviceID.current,
        ])
    }

    func login(email: String, password: String) async throws -> AuthResponse {
        try await send("auth/login", method: "POST", json: ["email": email, "password": password])
    }

    func me() async throws -> MeResponse {
        try await send("me")
    }

    struct OkResponse: Decodable {
        let ok: Bool
    }

    func forgotPassword(email: String) async throws -> OkResponse {
        try await send("auth/forgot", method: "POST", json: ["email": email])
    }

    func resetPassword(email: String, code: String, newPassword: String) async throws -> OkResponse {
        try await send("auth/reset", method: "POST", json: [
            "email": email,
            "code": code,
            "newPassword": newPassword,
        ])
    }

    func deleteAccount(password: String) async throws -> OkResponse {
        try await send("account/delete", method: "POST", json: ["password": password])
    }

    func verifyEmail(code: String) async throws -> OKResponse {
        try await send("auth/verify", method: "POST", json: ["code": code])
    }

    func resendCode() async throws -> OKResponse {
        try await send("auth/resend-code", method: "POST", json: [:])
    }

    // MARK: Scans & Orders

    func createScan(
        name: String,
        roomCount: Int,
        areaSqm: Double,
        kinds: [String],
        captureType: String,
        quality: [String: Any]? = nil
    ) async throws -> CreateScanResponse {
        var body: [String: Any] = [
            "name": name,
            "roomCount": roomCount,
            "areaSqm": areaSqm,
            "files": kinds,
            "captureType": captureType,
        ]
        if let quality {
            body["quality"] = quality
        }
        return try await send("scans", method: "POST", json: body)
    }

    func completeScan(scanId: String) async throws -> CompleteScanResponse {
        try await send("scans/\(scanId)/complete", method: "POST", json: [:])
    }

    func catalog() async throws -> CatalogResponse {
        let response: CatalogResponse = try await send("catalog")
        // Server có thể tinh chỉnh ngưỡng Accuracy Suite — cache lại cho lần quét sau.
        // Server KHÔNG có override (null) → về mặc định, để xóa AppSetting là hồi phục được.
        ScanQualityConfig.current = response.scanQuality ?? .defaults
        return response
    }

    func orderScan(
        scanId: String,
        extraScanIds: [String],
        packageId: String,
        addonIds: [String],
        notes: String,
        unitSystem: String,
        language: String,
        floorNaming: String,
        projectName: String,
        coupon: String
    ) async throws -> OrderScanResponse {
        try await send("scans/\(scanId)/order", method: "POST", json: [
            "packageId": packageId,
            "addons": addonIds,
            "extraScanIds": extraScanIds,
            "notes": notes,
            "unitSystem": unitSystem,
            "language": language,
            "floorNaming": floorNaming,
            "projectName": projectName,
            "coupon": coupon,
            "deviceId": DeviceID.current,
        ])
    }

    func listOrders() async throws -> OrdersResponse {
        try await send("orders")
    }

    struct RevisionResponse: Decodable {
        let ok: Bool
    }

    func requestRevision(orderId: String, message: String) async throws -> RevisionResponse {
        try await send("orders/\(orderId)/revision", method: "POST", json: ["message": message])
    }

    // MARK: Virtual Tour

    func orderTour(orderId: String) async throws -> OrderTourResponse {
        try await send("orders/\(orderId)/tour")
    }

    /// Xin slot upload 1 ảnh phòng → PUT lên R2 → gọi completeTourPhoto.
    func createTourPhoto(orderId: String, roomLabel: String, scanId: String?) async throws -> TourPhotoSlotResponse {
        var body: [String: Any] = ["roomLabel": roomLabel]
        if let scanId { body["scanId"] = scanId }
        return try await send("orders/\(orderId)/tour/photos", method: "POST", json: body)
    }

    func completeTourPhoto(orderId: String, photoId: String) async throws -> TourPhotoCompleteResponse {
        try await send("orders/\(orderId)/tour/photos/\(photoId)", method: "POST", json: [:])
    }

    func deleteTourPhoto(orderId: String, photoId: String) async throws -> OKResponse {
        try await send("orders/\(orderId)/tour/photos/\(photoId)", method: "DELETE")
    }

    /// PUT dữ liệu ảnh (đã nén JPEG trong RAM) lên presigned URL.
    func uploadData(_ data: Data, to putUrl: String, contentType: String) async throws {
        guard let url = URL(string: putUrl) else {
            throw APIError(message: "Invalid upload URL", statusCode: 0)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 300
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw APIError(
                message: L.t("Upload failed. Please try again.", "Tải lên thất bại. Vui lòng thử lại."),
                statusCode: status
            )
        }
    }

    // MARK: File upload (PUT presigned URL, có báo tiến độ)

    func uploadFile(
        at fileURL: URL,
        to putUrl: String,
        contentType: String,
        progress: @escaping (Double) -> Void
    ) async throws {
        guard let url = URL(string: putUrl) else {
            throw APIError(message: "Invalid upload URL", statusCode: 0)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 3600
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var observation: NSKeyValueObservation?
            let task = URLSession.shared.uploadTask(with: request, fromFile: fileURL) { _, response, error in
                _ = observation // giữ observation sống tới khi xong
                observation = nil
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200...299).contains(status) {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: APIError(
                        message: L.t("Upload failed. Please try again.", "Tải lên thất bại. Vui lòng thử lại."),
                        statusCode: status
                    ))
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { p, _ in
                DispatchQueue.main.async { progress(p.fractionCompleted) }
            }
            task.resume()
        }
    }
}
