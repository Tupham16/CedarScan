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
}

struct MeResponse: Decodable {
    let customer: CustomerDTO
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
    let defaults: OrderDefaults?
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

    var id: String { orderId }
}

struct OrdersResponse: Decodable {
    let orders: [OrderDTO]
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
        try await send("auth/register", method: "POST", json: ["email": email, "password": password, "name": name])
    }

    func login(email: String, password: String) async throws -> AuthResponse {
        try await send("auth/login", method: "POST", json: ["email": email, "password": password])
    }

    func me() async throws -> MeResponse {
        try await send("me")
    }

    // MARK: Scans & Orders

    func createScan(
        name: String,
        roomCount: Int,
        areaSqm: Double,
        kinds: [String],
        captureType: String
    ) async throws -> CreateScanResponse {
        try await send("scans", method: "POST", json: [
            "name": name,
            "roomCount": roomCount,
            "areaSqm": areaSqm,
            "files": kinds,
            "captureType": captureType,
        ])
    }

    func completeScan(scanId: String) async throws -> CompleteScanResponse {
        try await send("scans/\(scanId)/complete", method: "POST", json: [:])
    }

    func catalog() async throws -> CatalogResponse {
        try await send("catalog")
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
