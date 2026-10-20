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
    /// Account → "Payment methods" row. Absent on older servers = no row.
    let paymentMethods: Bool?
    /// F9: Account → "My brand" row (the server has the brand routes). Absent = no row.
    let myBrand: Bool?
    /// F10: the team this account is on. nil = none, or a server without teams.
    let team: TeamSummaryDTO?
}

/// F10 (team accounts, app half F10b): read-only here; the team is managed on app.cedar247.com.
/// `GET me` → `team` and `GET team` → `team` (the latter without `role`).
struct TeamSummaryDTO: Decodable, Equatable {
    let id: String
    let name: String
    /// "admin" | "member" (`GET me` only).
    let role: String?
    /// The card that pays the team's orders; nil = none.
    let card: TeamCardDTO?

    var isAdmin: Bool { role == "admin" }
}

struct TeamCardDTO: Decodable, Equatable {
    /// Stripe's brand id: "visa", "mastercard", "amex"…
    let brand: String?
    let last4: String?

    /// "Visa •••• 4242", as the web shows it (Stripe's brand id, first letter upper-cased). No
    /// "Card" fallback word: a key that short collides with Stripe's own (trap #42).
    var label: String {
        let raw = brand ?? ""
        let name = raw.prefix(1).uppercased() + raw.dropFirst()
        return (name.isEmpty ? "" : name + " ") + "•••• " + (last4 ?? "")
    }
}

/// `GET team`: `team` nil = on no team. `invites` only for admins.
struct TeamResponse: Decodable {
    let team: TeamSummaryDTO?
    let members: [TeamMemberDTO]?
    let invites: [TeamInviteDTO]?
}

struct TeamMemberDTO: Decodable, Identifiable {
    let memberId: String
    let name: String
    let role: String?
    let isYou: Bool?

    var id: String { memberId }
}

struct TeamInviteDTO: Decodable, Identifiable {
    let id: String
    let email: String
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

/// Slot upload 1 file đính kèm đơn (logo / file thêm) — xin TRƯỚC khi đặt hàng.
struct OrderFileSlot: Decodable {
    let fileId: String
    let name: String
    let putUrl: String
    let contentType: String
    let maxBytes: Int
    let publicUrl: String
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
    /// Server hint: this order can be paid in the app (Stripe PaymentSheet) — see `PaymentFlow`.
    /// nil/false (older server, switch off) = open `paymentUrl` in the browser as before.
    let payInApp: Bool?
    /// Orders v2 B (the app sends `payFirst: true`): `status` is `"awaiting_payment"` = NOT placed
    /// until paid, or `"received"` = placed at once (free / 100% coupon). `payBy` = when an unpaid
    /// order cancels itself; nil when there is nothing to pay, and for test accounts (never expire).
    let payBy: String?
    /// F1 (2.79): same as `OrderDTO.dueAt`, for the "Order placed!" screen. nil = no line (not
    /// paid yet, or a server that does not send it here).
    let dueAt: String?
    /// F10: "team_card" = the team's card paid it at once (`free` is then true too: nothing to pay).
    let paidWith: String?

    var paidWithTeamCard: Bool { paidWith == "team_card" }
}

/// Kết quả "gửi bổ sung bản quét" (`POST orders/{id}/supplement-scan`).
///
/// 🔴 `scanIds` gồm CẢ bản vừa nối LẪN bản đã nối từ lượt trước (nhánh idempotent khi khách gửi
/// lại sau lỗi mạng) — app phải đóng dấu `setOrderNumber` cho **toàn bộ** danh sách này. Đóng dấu
/// thiếu là khách thấy bản quét vẫn "chưa đặt", bấm đặt lần nữa và **TRẢ TIỀN HAI LẦN**.
///
/// Mọi trường ngoài `ok`/`orderNumber` để Optional: server có thể bổ sung/đổi field, mà
/// `JSONDecoder` ném lỗi cho CẢ response nếu thiếu một field non-optional.
struct SupplementScanResponse: Decodable {
    let ok: Bool
    let orderId: String?
    let orderNumber: String
    let status: String?
    /// Mọi bản quét lượt này gửi (đã nối vào đơn, dù nối lần này hay lần trước).
    let scanIds: [String]?
    let attachedScanIds: [String]?
    let alreadyAttachedScanIds: [String]?
    let supplementCount: Int?
    let fileCount: Int?
    /// Đơn ĐÃ GIAO lúc khách bấm gửi. Server nhận nó từ 19/08 (chủ app chốt "đã đặt hay đã giao
    /// đều không tính phí") — trước đó ca này luôn là lỗi `order_delivered`, ✗ bao giờ thành công.
    let wasDelivered: Bool?
    /// Thẻ Kanban đã tự kéo `done → fix` chưa. `false` khi đơn đã giao nhưng thẻ đang ở "hold" —
    /// lúc đó việc phải xử lý tay, và câu báo cho khách ✗ được hứa chắc là đã vào hàng sản xuất.
    /// 🔴 CẢ HAI PHẢI Optional: server CŨ không trả chúng, mà `JSONDecoder` ném lỗi cho CẢ
    /// response nếu thiếu một field non-optional → một lượt gửi ĐÃ THÀNH CÔNG hiện thành "lỗi",
    /// và khách gửi lại. Cùng bẫy đã ghi ở `OrderDTO.texturedScans`.
    let movedToFix: Bool?
}

// MARK: Bảng giá dịch vụ

struct CatalogPackage: Decodable, Identifiable {
    let id: String
    let name: String
    let price: Int
    let isDefault: Bool
}

/// Mẫu cho addon có picker (color / siteplan). imageUrl có thể rỗng (placeholder) → app hiện ô màu + tên.
struct CatalogTemplate: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let imageUrl: String?
    /// Agency styles only (F9): the phone regions that list it (`BrandStyles.listed`).
    let regions: [String]?
}

struct CatalogAddon: Decodable, Identifiable {
    let id: String
    let name: String
    let price: Int
    /// Chỉ addon có picker mẫu (color, siteplan) mới có. Server cũ / addon thường → nil.
    let templates: [CatalogTemplate]?
    /// F9: the colour add-on's AU / NZ agency styles this account may see (server: those with a
    /// sample image; all of them for a test account). nil from servers before F9.
    let agencyTemplates: [CatalogTemplate]?
}

/// F9 "My brand" (server `lib/brand.ts`): the saved logo, whether every order gets it, and the
/// default colour style (`agencyStyleId` wins over `styleId`). In `GET catalog`, `GET extras` and
/// every `account/brand` answer.
struct BrandSettings: Decodable, Equatable {
    let logo: BrandLogo?
    let addLogo: Bool
    let styleId: String?
    let agencyStyleId: String?

    static let empty = BrandSettings(logo: nil, addLogo: false, styleId: nil, agencyStyleId: nil)
}

struct BrandLogo: Decodable, Equatable {
    let url: String
    let name: String
    /// Sniffed by the server: image/png · image/jpeg · image/svg+xml · application/pdf.
    let contentType: String
    let bytes: Int
}

struct BrandResponse: Decodable {
    let brand: BrandSettings
}

struct CatalogSurcharge: Decodable {
    let overSqFt: Double
    let fee: Int
}

struct OrderDefaults: Decodable {
    let packageId: String? // app cũ: gói đơn. Giữ để tương thích ngược khi đọc default cũ.
    let packageIds: [String]? // app mới: đa gói
    let addonIds: [String]?
    let templates: [String: String]? // addonId → templateId đã chọn lần trước
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
    /// F9 My brand. nil from servers before F9 (the form then works as before).
    let brand: BrandSettings?
}

struct DeliveryFileDTO: Decodable, Hashable {
    let fileName: String
    let url: String
    let sizeLabel: String?
}

/// Server/staff-supplied link strings (paymentUrl, tourUrl, deliveredUrl, delivery files) may be
/// hand-typed (`board-actions.ts` passes `order.deliveryLink` through verbatim). Only https may
/// leave the app via Link/openURL/ShareLink — anything else (http, tel:, itms-services:, custom
/// schemes) renders nothing.
func httpsURL(_ string: String?) -> URL? {
    guard let string, let url = URL(string: string), url.scheme?.lowercased() == "https" else { return nil }
    return url
}

/// Mô hình CÓ TEXTURE do MÁY TRẠM bake (USDZ trên R2) — app tải về xem bằng QuickLook.
/// Chỉ những bản quét đã bake xong mới có mặt trong `OrderDTO.texturedScans`.
struct TexturedScanDTO: Decodable, Hashable {
    let scanId: String
    let name: String
    let url: String
}

/// A message from the team about an order (PLAN-THONG-BAO-DAY.md §5). Decoding never throws: one
/// odd entry (a field of another type, not an object) must not fail the whole order list (the
/// `texturedScans` rule) — it decodes empty (`id` "") and `OrderMessagesCard` skips it.
struct OrderMessageDTO: Decodable, Identifiable, Hashable {
    let id: String
    let text: String?
    let attachments: [OrderMessageAttachmentDTO]?
    let sentAt: String?

    private enum CodingKeys: String, CodingKey {
        case id, text, attachments, sentAt
    }

    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        id = (try? c?.decodeIfPresent(String.self, forKey: .id)) ?? ""
        text = try? c?.decodeIfPresent(String.self, forKey: .text)
        attachments = try? c?.decodeIfPresent([OrderMessageAttachmentDTO].self, forKey: .attachments)
        sentAt = try? c?.decodeIfPresent(String.self, forKey: .sentAt)
    }
}

struct OrderMessageAttachmentDTO: Decodable, Hashable {
    let name: String?
    let url: String?
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
    /// House the order was placed under. Optional: an older server omits it, and so do orders
    /// placed without one.
    let projectName: String?
    /// What was ordered, as display names ("2D Floor Plan", "Color floor plan · Classic"), for the
    /// order detail. Optional: an older server omits it.
    let items: [String]?
    let status: String
    let placedAt: String
    let deliveredAt: String?
    let deliveredUrl: String?
    /// Optional per the same rule as `texturedScans` below: one server response omitting the key
    /// must not kill decoding of the whole order list. Read via `files`.
    let deliveryFiles: [DeliveryFileDTO]?
    let total: Int?
    let currency: String?
    let paid: Bool?
    let paymentUrl: String?
    /// Same hint as `OrderScanResponse.payInApp`. Optional: an older server does not send it.
    let payInApp: Bool?
    // Virtual Tour add-on
    let hasTour: Bool?
    let tourPhotoCount: Int?
    let tourUrl: String? // chỉ có sau khi đơn được giao (tour đã publish)
    /// Mô hình có texture đã bake xong (rỗng/nil = chưa có gì để xem).
    /// 🔴 PHẢI Optional: bản server CŨ không trả field này, mà `JSONDecoder` ném lỗi cho CẢ
    /// response nếu thiếu một field non-optional → mất sạch danh sách đơn VÀ tắt luôn
    /// purgeDeliveredScans (nó nuốt lỗi bằng `try?`).
    let texturedScans: [TexturedScanDTO]?
    /// Orders v2 B ("unpaid = not placed", PLAN-DON-HANG-V2.md §4a). `status` may be
    /// `"awaiting_payment"` (not placed until paid) or `"cancelled"` (cancelled unpaid: by the
    /// customer, after 7 days, or at account deletion). `payBy` = when an awaiting order cancels
    /// itself (nil for test accounts: they never expire). A cancelled order carries in `scanIds`
    /// the scans RELEASED at the cancel (see `ScanStore.syncOrders`). Optional: older servers.
    let payBy: String?
    let cancelledAt: String?
    let cancelReason: String?
    /// Orders v2 C ("Add to this order", PLAN-DON-HANG-V2.md §5): what the customer bought for this
    /// order later, oldest first. Each is its OWN order on the server (number "<this>_A<n>", its own
    /// status, payment and files) and never appears in the list on its own. Optional: older servers.
    let extras: [OrderDTO]?
    /// The server allows "Add to this order" now (paid, not refunded / closed, nothing awaiting
    /// payment, something left to add). `orders/{id}/extras` decides again.
    let canAddItems: Bool?
    /// Messages from the team ("Nhắn khách", also emailed), newest first — this order's and its
    /// extras' (root orders only). Optional: older servers. `lib/order-messages.ts`.
    let messages: [OrderMessageDTO]?
    /// F1 (2.79): the deadline on the staff board, ISO 8601 UTC. nil while it does not apply
    /// (unpaid, cancelled, delivered, on hold, refunded, test accounts, none set — server
    /// `orders/route.ts`). Staff can move it, and it can be in the past. Read via `readyBy`.
    /// Optional: older servers.
    let dueAt: String?
    /// F10 (team accounts): the teammate who placed it (their account's name). nil = you, a personal
    /// order, or a teammate whose account is gone. Optional: older servers.
    let placedBy: String?
    /// "team_card" once the team's card paid it. Optional: older servers.
    let paidWith: String?

    var id: String { orderId }

    var paidWithTeamCard: Bool { paidWith == "team_card" }

    /// F1: when the order should be ready, or nil. A deadline already past is hidden (owner
    /// 20/10: the customer is not shown a late order; the status badge stays).
    var readyBy: Date? { Self.readyByDate(dueAt) }

    static func readyByDate(_ raw: String?, now: Date = Date()) -> Date? {
        guard let raw, let date = isoDate(raw), date > now else { return nil }
        return date
    }

    /// Not placed until paid: Pay or Cancel in the order detail.
    var isAwaitingPayment: Bool { status == "awaiting_payment" }

    /// Cancelled unpaid. `cancelledAt` too: a cancelled order paid late and refunded reads
    /// "refunded", and its released scans still need their stamps cleared.
    var isCancelled: Bool { status == "cancelled" || cancelledAt != nil }

    var files: [DeliveryFileDTO] { deliveryFiles ?? [] }

    /// Mọi bản quét thuộc đơn. `scanIds` là nguồn ĐÚNG; `scanId` chỉ là tầng đầu tiên
    /// (orders/route.ts:65 lấy `orderScans[0]`), giữ làm phao cho server cũ.
    var allScanIds: [String] {
        if let ids = scanIds, !ids.isEmpty { return ids }
        return [scanId].compactMap { $0 }
    }

    /// Khách ĐÃ CẦM ĐƯỢC thành phẩm NẰM TRÊN HẠ TẦNG CỦA CHỦ APP — điều kiện cho phép xoá dữ
    /// liệu quét trên máy họ.
    ///
    /// ⚠ Từ bản 1.8 thuộc tính này (và `wasDeliveredAtLeast`) KHÔNG còn người đọc lúc chạy: việc
    /// dọn tự động đã tắt ở `RootView.autoPurgeAfterDelivery`. Giữ nguyên cả hai + lời khai dưới
    /// đây, vì bật lại là một dòng còn dựng lại các chốt này thì không.
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
        guard !files.isEmpty,
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
    /// Also used for the date on each Orders row.
    static func isoDate(_ raw: String) -> Date? {
        let withMs = ISO8601DateFormatter()
        withMs.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withMs.date(from: raw) { return d }
        return ISO8601DateFormatter().date(from: raw)
    }
}

struct OrdersResponse: Decodable {
    let orders: [OrderDTO]
}

/// Orders v2 C: one catalog item in "Add to this order". `included` = the order has it already.
struct ExtrasOfferItem: Decodable, Identifiable {
    let id: String
    let name: String
    let price: Int
    let included: Bool
    let templates: [CatalogTemplate]?
    /// F9, as `CatalogAddon.agencyTemplates`.
    let agencyTemplates: [CatalogTemplate]?
}

/// `GET orders/{id}/extras`: what may be added to this order, at what price. `code` says why not
/// when `canAdd` is false: `not_paid` · `refunded` · `closed` · `not_eligible` · `extra_awaiting`
/// (pay or cancel `awaitingOrderId` first) · `nothing_to_add`.
struct ExtrasOffer: Decodable {
    let orderId: String
    let orderNumber: String
    let canAdd: Bool
    let code: String?
    let awaitingOrderId: String?
    let packages: [ExtrasOfferItem]
    let addons: [ExtrasOfferItem]
    /// F9: the saved style, pre-selected when "Color" is switched on. nil from servers before F9.
    let brand: BrandSettings?
}

/// `POST orders/{id}/extras` (200): the NEW order that holds the items. `status` `awaiting_payment`
/// (pay it like any order: `PayNowButton` on `orderId`) or `received` (free by a coupon: placed).
/// `amountCents` = the exact amount the payment page / card sheet charge (a customer coupon may take
/// cents off); nil when the server could not ask WordPress. Optional fields: a decode failure after
/// a purchase that DID happen would read as a failure.
struct AddExtrasResponse: Decodable {
    let orderId: String
    let orderNumber: String
    let status: String
    let total: Int?
    let amountCents: Int?
    let items: [String]?
    let discount: Double?
    let free: Bool?
    let paymentUrl: String?
    let payInApp: Bool?
    let payBy: String?
    /// F10: "team_card" = the team's card paid it at once (`free` true too, as on Place order).
    let paidWith: String?

    var paidWithTeamCard: Bool { paidWith == "team_card" }
}

/// `POST orders/{id}/cancel` (200). `scanIds` = the scans released back to the customer: the app
/// clears its local stamp on exactly those (`ScanStore.releaseCancelledOrder`). Optional fields:
/// a decode failure after a cancel that DID happen would read as a failure.
struct CancelOrderResponse: Decodable {
    let ok: Bool?
    let orderId: String?
    let orderNumber: String?
    let status: String?
    let scanIds: [String]?
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

// MARK: In-app payment (Stripe PaymentSheet)

/// `POST orders/{id}/payment-sheet`: what Stripe's PaymentSheet needs for ONE unpaid order. The
/// server decides the amount and sends the publishable key (test accounts get Stripe TEST keys on
/// prod) — ✗ never hard-code a key in the app. Fields the app does not use are left undecoded.
struct PaymentSheetParams: Decodable {
    /// The PaymentIntent's client secret. ✗ log, ✗ store.
    let paymentIntent: String
    let customer: String
    let ephemeralKey: String
    let publishableKey: String
    let merchantDisplayName: String?
}

/// `POST payment-methods`: Stripe customer + ephemeral key for the CustomerSheet. ✗ log, ✗ store.
struct PaymentMethodsParams: Decodable {
    let customer: String
    let ephemeralKey: String
    let publishableKey: String
    let merchantDisplayName: String?
}

struct SetupIntentParams: Decodable {
    /// The SetupIntent's client secret. ✗ log, ✗ store.
    let setupIntent: String
}

/// `POST orders/{id}/payment-confirm`: the server asks Stripe itself and settles the order.
/// `processing` = the charge is still in flight, ask again later.
struct PaymentConfirmResponse: Decodable {
    let paid: Bool
    let processing: Bool?
}

struct APIError: LocalizedError {
    let message: String
    let statusCode: Int
    /// Mã lỗi MÁY ĐỌC ĐƯỢC do server gửi kèm (khoá `code` trong body), e.g. `order_closed`
    /// (extra-scan send: tell the customer to contact support), `already_paid`, `extra_awaiting`.
    /// Read this, ✗ match the English message.
    ///
    /// 🔴 PHẢI là `var` có giá trị mặc định, ✗ `let`: `let code: String? = nil` thì Swift LOẠI
    /// nó khỏi memberwise init (thành hằng nil vĩnh viễn) — im lặng, CI vẫn xanh, và mọi mã lỗi
    /// rơi về nhánh lỗi thô. Với `var` thì các call site cũ
    /// `APIError(message:statusCode:)` vẫn compile nguyên.
    var code: String? = nil
    /// The order a 409 "This scan has already been ordered." names (`scans/{id}/order`):
    /// `OrderSheet.adoptExistingOrder` stamps from it instead of showing the raw error. `var` with a
    /// default for the reason given at `code`.
    var orderId: String? = nil
    var orderNumber: String? = nil
    /// That order's customer status (`awaiting_payment`, `received`…), ✗ the HTTP `statusCode`.
    var orderStatus: String? = nil
    var errorDescription: String? { message }
}

/// N13 (2.79): a 2xx answer the app could not decode — shown as the generic message. Its own type,
/// ✗ `APIError`: see `APIClient.send`.
struct UnreadableResponse: LocalizedError {
    var errorDescription: String? { String(localized: "Something went wrong. Please try again.") }
}

// MARK: - Client

final class APIClient {
    static let shared = APIClient()

    let baseURL = URL(string: "https://app.cedar247.com/api/app/v1")!
    var token: String?

    private struct ServerError: Decodable {
        let error: String
        /// Optional: chỉ vài endpoint gửi kèm. Thiếu nó KHÔNG được làm hỏng việc đọc `error`.
        let code: String?
        /// Only the Place order 409 sends these (see `APIError.orderId`).
        let orderId: String?
        let orderNumber: String?
        let status: String?

        private enum CodingKeys: String, CodingKey {
            case error, code, orderId, orderNumber, status
        }

        /// Every field but `error` read with `try?`: one of another type in some error body must
        /// not lose the message.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            error = try c.decode(String.self, forKey: .error)
            code = try? c.decodeIfPresent(String.self, forKey: .code)
            orderId = try? c.decodeIfPresent(String.self, forKey: .orderId)
            orderNumber = try? c.decodeIfPresent(String.self, forKey: .orderNumber)
            status = try? c.decodeIfPresent(String.self, forKey: .status)
        }
    }

    private func makeRequest(
        path: String,
        method: String,
        json: [String: Any]?,
        query: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) throws -> URLRequest {
        var url = baseURL.appendingPathComponent(path)
        // Query PHẢI dựng bằng URLComponents, đừng nối "path?a=b" vào `appendingPathComponent` —
        // hàm đó escape dấu "?" thành %3F nên server nhận nguyên chuỗi làm tên path và trả 404.
        if let query, !query.isEmpty,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            if let built = components.url { url = built }
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return request
    }

    private func send<T: Decodable>(
        _ path: String,
        method: String = "GET",
        json: [String: Any]? = nil,
        query: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) async throws -> T {
        let request = try makeRequest(path: path, method: method, json: json, query: query, timeout: timeout)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200...299).contains(status) {
            let body = try? JSONDecoder().decode(ServerError.self, from: data)
            throw APIError(
                message: body.map { Self.customerWording($0.error, status: status, code: $0.code) }
                    ?? String(localized: "Something went wrong. Please try again."),
                statusCode: status,
                code: body?.code,
                orderId: body?.orderId,
                orderNumber: body?.orderNumber,
                orderStatus: body?.status
            )
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch is DecodingError {
            // N13: Foundation's "The data couldn't be read because it isn't in the correct format."
            // means nothing to a customer. ✗ an `APIError`: callers read `is APIError` as "the
            // server refused" (`OrderDetailView.cancelOrder`: a lost cancel answer vs a refusal) —
            // a 2xx it could not read is neither, as the `DecodingError` it replaces.
            throw UnreadableResponse()
        }
    }

    /// N13 (2.79): the server writes every error in English (`app-api.ts`), and the app showed it
    /// as it came — in an 8-language app. The ones customers meet (sign-in, sign-up, the code
    /// screens, account deletion, Place order, rate limits) are shown in the app's language; any
    /// other keeps the server's words, as before. Matched on the exact sentence: these routes send
    /// no `code`. Wording only — decisions read `statusCode` / `code`, ✗ this text. A sentence the
    /// server rewords falls back to its own text (English), never to a wrong translation.
    static func customerWording(_ text: String, status: Int, code: String?) -> String {
        // 2.79 server (S3, N10): a body over the route's cap is refused with 413 + this code
        // instead of being read as an empty form.
        if code == "too_large" {
            return String(localized: "This request is too large. Please shorten your text and try again.")
        }
        switch text {
        // Every route: a body that is not a JSON object — never sent by this app; a bug, not
        // something the customer can fix.
        case "Invalid request body.":
            return String(localized: "Something went wrong. Please try again.")
        case "Incorrect email or password.":
            return String(localized: "Incorrect email or password.")
        case "An account with this email already exists. Please sign in.":
            return String(localized: "An account with this email already exists. Please sign in.")
        case "Please enter a valid email address.":
            return String(localized: "Please enter a valid email address.")
        case "Password must be at least 8 characters.":
            return String(localized: "Password must be at least 8 characters.")
        case "Please enter your name.":
            return String(localized: "Please enter your name.")
        case "Incorrect code. Please try again.":
            return String(localized: "Incorrect code. Please try again.")
        case "The code has expired. Please request a new one.":
            return String(localized: "The code has expired. Please request a new one.")
        case "Invalid or expired code.":
            return String(localized: "Invalid or expired code.")
        case "Too many attempts. Please request a new code.":
            return String(localized: "Too many attempts. Please request a new code.")
        case "Could not send the email right now. Please try again.":
            return String(localized: "Could not send the email right now. Please try again.")
        case "Incorrect password.":
            return String(localized: "Incorrect password.")
        case "Please sign in to continue.":
            return String(localized: "Please sign in to continue.")
        case "Please verify your email before placing an order.":
            return String(localized: "Please verify your email before placing an order.")
        case "One of the selected scans is already part of another order.":
            return String(localized: "One of the selected scans is already part of another order.")
        // F10 (team accounts): 409s of Place order / Send extra scan, sent without a `code`.
        case "Your team membership just changed. Please try again.":
            return String(localized: "Your team membership just changed. Please try again.")
        case "A teammate's scan can't be added to your personal order.":
            return String(localized: "A teammate's scan can't be added to your personal order.")
        default:
            break
        }
        if let minutes = number(in: text, #"^Too many failed attempts\. Please try again in (\d+) minute\(s\)\.$"#) {
            return String(localized: "Too many failed attempts. Please try again in \(minutes) minute(s).")
        }
        if let seconds = number(in: text, #"^Please wait (\d+)s before requesting another code\.$"#) {
            return String(localized: "Please wait \(seconds) s before requesting another code.")
        }
        // Rate limits, worded per route ("Too many requests. Please slow down.", "Too many
        // attempts. Please try again later." …). ✗ every 429: "Daily scan limit reached. Please
        // try again tomorrow." says something else and keeps its words.
        if status == 429, text.hasPrefix("Too many") {
            return String(localized: "Too many attempts. Please try again later.")
        }
        return text
    }

    /// The one number `pattern` captures in `text`, or nil when the sentence is not that one.
    private static func number(in text: String, _ pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges == 2,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
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

    /// F10b: the Team screen (read-only).
    func team() async throws -> TeamResponse {
        try await send("team")
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

    /// Orders v2 B: the server first cancels every order still awaiting payment (WordPress, up to
    /// ~20 s each, or ~45 s behind a cancel already running) — ✗ the default 30 s timeout, which
    /// would report a failure for a deletion that goes through.
    func deleteAccount(password: String) async throws -> OkResponse {
        try await send("account/delete", method: "POST", json: ["password": password], timeout: 120)
    }

    func verifyEmail(code: String) async throws -> OKResponse {
        try await send("auth/verify", method: "POST", json: ["code": code])
    }

    func resendCode() async throws -> OKResponse {
        try await send("auth/resend-code", method: "POST", json: [:])
    }

    // MARK: Delivery emails — callers: `DeliveryEmailsView` only

    /// F6 (2.79): other addresses that also get the download links of every delivered order
    /// (server `lib/delivery-copies.ts`). `max` absent = 5.
    struct DeliveryEmailsResponse: Decodable {
        let emails: [String]
        let max: Int?
    }

    func deliveryEmails() async throws -> DeliveryEmailsResponse {
        try await send("account/delivery-emails")
    }

    /// Replaces the whole list; the answer is the list as stored (lowercased, deduped). Refused =
    /// 400 with `code` invalid_email / own_email / too_many, nothing stored.
    func setDeliveryEmails(_ emails: [String]) async throws -> DeliveryEmailsResponse {
        try await send("account/delivery-emails", method: "PUT", json: ["emails": emails])
    }

    // MARK: Push notifications — callers: `PushNotifications` only

    /// This phone gets the signed-in account's pushes (moves the token from any other account).
    /// 400 bad token · 401 stale session · 429.
    @discardableResult
    func registerPushToken(_ token: String, environment: String) async throws -> OKResponse {
        try await send("push/register", method: "POST", json: ["token": token, "environment": environment])
    }

    /// No auth needed (sign-out retries after the session is gone). 400 = bad token.
    @discardableResult
    func unregisterPushToken(_ token: String) async throws -> OKResponse {
        try await send("push/unregister", method: "POST", json: ["token": token])
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

    /// Fresh PUT URLs (1 h TTL) for a scan created earlier — resume / retry of background uploads
    /// (`ScanUploader`). Server `scans/[id]/uploads`, live 26/09 (`beeabd7`). 404 = not this
    /// account's scan; 409 `code` `scan_ordered` = already ordered, never overwrite its files.
    func presignScanUploads(scanId: String, kinds: [String]) async throws -> CreateScanResponse {
        try await send("scans/\(scanId)/uploads", method: "POST", json: ["files": kinds])
    }

    func completeScan(scanId: String) async throws -> CompleteScanResponse {
        try await send("scans/\(scanId)/complete", method: "POST", json: [:])
    }

    func catalog() async throws -> CatalogResponse {
        // 🔴 PHẢI gửi kèm deviceId. Suất khuyến mãi được tính bằng MIN(tài khoản, THIẾT BỊ) — xem
        // `catalog/route.ts:18-23`, server đã được viết sẵn để đọc `?deviceId=` và comment ở đó mô
        // tả đúng lỗi này: thiếu nó thì server rơi về `signupDeviceId` (thiết bị lúc ĐĂNG KÝ).
        //
        // Hậu quả khi thiếu: tài khoản đăng ký ở máy KHÁC mở app trên máy này → catalog báo còn
        // suất → form in "Đơn này MIỄN PHÍ!" và nút ghi "MIỄN PHÍ 🎁" → nhưng `orderScan` CÓ gửi
        // deviceId (:373) nên lúc đặt server thấy máy hết suất và THU ĐỦ TIỀN. Khách bấm một nút
        // ghi MIỄN PHÍ rồi nhận link thanh toán.
        let response: CatalogResponse = try await send("catalog", query: ["deviceId": DeviceID.current])
        await storeScanQuality(response.scanQuality)
        return response
    }

    /// N8 (2.79): the launch / sign-in / foreground fetch of the remote scan settings
    /// (`RootView.refreshScanQualityConfig`) — the same GET WITHOUT `deviceId`. The Privacy Policy
    /// ("Device identifier") names three moments: account creation, viewing prices, placing an
    /// order; this one is none of them. The server reads `deviceId` only for the free-order count
    /// (`catalog/route.ts`), which nothing reads from this answer.
    func scanSettings() async throws {
        let response: CatalogResponse = try await send("catalog")
        await storeScanQuality(response.scanQuality)
    }

    /// Server có thể tinh chỉnh ngưỡng Accuracy Suite — cache lại cho lần quét sau.
    /// Server KHÔNG có override (null) → về mặc định, để xóa AppSetting là hồi phục được.
    /// Written on MAIN (2.73): scan start reads `current` on main, and since 2.73 this also
    /// runs at launch / foreground (RootView), i.e. possibly while a scan is starting.
    private func storeScanQuality(_ scanQuality: ScanQualityConfig?) async {
        let quality = scanQuality ?? .defaults
        await MainActor.run { ScanQualityConfig.current = quality }
    }

    /// Xin presigned URL upload 1 file đính kèm đơn (logo / file thêm). App PUT file lên `putUrl`
    /// rồi gửi `publicUrl` kèm khi đặt hàng.
    func presignOrderFile(fileName: String, contentType: String) async throws -> OrderFileSlot {
        try await send("order-files", method: "POST", json: [
            "fileName": fileName,
            "contentType": contentType,
        ])
    }

    /// 60 s, ✗ the default 30: the route runs a DB transaction, R2 HEADs and a WordPress call (up to
    /// ~15 s) before it answers, and a timeout there is an order placed with its answer lost. A 409
    /// naming the order (a retry after a lost answer) → `OrderSheet.adoptExistingOrder`.
    func orderScan(
        scanId: String,
        extraScanIds: [String],
        packageIds: [String],
        addonIds: [String],
        templates: [String: String],
        orderFiles: [[String: String]],
        notes: String,
        unitSystem: String,
        language: String,
        floorNaming: String,
        projectName: String,
        coupon: String,
        addLogo: Bool? = nil
    ) async throws -> OrderScanResponse {
        let body = Self.orderBody(
            extraScanIds: extraScanIds, packageIds: packageIds, addonIds: addonIds,
            templates: templates, orderFiles: orderFiles, notes: notes, unitSystem: unitSystem,
            language: language, floorNaming: floorNaming, projectName: projectName, coupon: coupon,
            addLogo: addLogo
        )
        // N10 (2.79): the backstop of `OrderSheet.submit`'s check before its uploads.
        if Self.isTooLarge(body) {
            throw APIError(
                message: String(localized: "This request is too large. Please shorten your text and try again."),
                statusCode: 413,
                code: "too_large"
            )
        }
        return try await send("scans/\(scanId)/order", method: "POST", json: body, timeout: 60)
    }

    /// The Place order body (the primary scan id goes in the path). Also measured by
    /// `OrderSheet.submit` BEFORE its uploads (`isTooLarge`).
    static func orderBody(
        extraScanIds: [String],
        packageIds: [String],
        addonIds: [String],
        templates: [String: String],
        orderFiles: [[String: String]],
        notes: String,
        unitSystem: String,
        language: String,
        floorNaming: String,
        projectName: String,
        coupon: String,
        addLogo: Bool? = nil
    ) -> [String: Any] {
        var body: [String: Any] = [
            "packageIds": packageIds, // đa gói (server cũng nhận `packageId` đơn, nhưng app mới gửi mảng)
            "addons": addonIds,
            "templates": templates, // addonId → templateId (color / siteplan)
            "orderFiles": orderFiles, // [{name, url}] logo / file thêm khách tự gửi
            "extraScanIds": extraScanIds,
            "notes": notes,
            "unitSystem": unitSystem,
            "language": language,
            "floorNaming": floorNaming,
            "projectName": projectName,
            "coupon": coupon,
            "deviceId": DeviceID.current,
            // Orders v2 B: this build knows "unpaid = not placed" (server `lib/pay-first.ts`). A
            // paid order then waits as "Awaiting payment" (hidden from the team, Pay or Cancel,
            // cancelled by itself after 7 days) instead of being worked on before payment.
            // 🔴 ALWAYS sent: the Cancel button, the placed screen and the stamp release all assume it.
            "payFirst": true,
        ]
        // F9: the form's logo choice (2.79; OrderSheet always sends it). Absent = the saved setting
        // decides (server `lib/brand.ts`) — what apps before 2.79 get.
        if let addLogo { body["addLogo"] = addLogo }
        return body
    }

    /// N10 (2.79): the order route's cap = the server's `MAX_TEXT_JSON_BYTES` (S3, live 20/10
    /// `c9fc3cb`: over it 413 `too_large`; before that server a body over 16 KB was read as an
    /// EMPTY form = a default 2D order). Checked in `OrderSheet.submit` BEFORE the uploads, so a
    /// too-long body is refused before 40–200 MB go up; the fields are capped anyway (a full
    /// note + 10 long file names measured 17.5 KB). Same `JSONSerialization` call as
    /// `makeRequest` = the exact bytes. Change it with the server, ✗ alone.
    static let maxOrderBodyBytes = 64 * 1024

    static func isTooLarge(_ body: [String: Any]) -> Bool {
        guard let encoded = try? JSONSerialization.data(withJSONObject: body) else { return false }
        return encoded.count > maxOrderBodyBytes
    }

    /// `include=cancelled`: orders cancelled unpaid are listed too (status `cancelled`, `scanIds` =
    /// the released scans) so the app can clear its stamps (`ScanStore.syncOrders`). Every caller
    /// of this function gets them — read `OrderDTO.isCancelled` before acting on an order.
    func listOrders() async throws -> OrdersResponse {
        try await send("orders", query: ["include": "cancelled"])
    }

    /// Cancel an order still AWAITING PAYMENT (Orders v2 B). The server first shuts every channel
    /// that could still take money (the card sheet, the Woo pay page) and can take ~45 s when
    /// WordPress is slow; a second call waits for the first. Refusals: 409 `code` `already_paid` /
    /// `payment_processing` / `not_cancellable` / `try_again`, 502 `try_again`, 404, 429.
    func cancelOrder(orderId: String) async throws -> CancelOrderResponse {
        try await send("orders/\(orderId)/cancel", method: "POST", json: [:], timeout: 90)
    }

    /// Orders v2 C: what may be added to this (paid) order.
    func extrasOffer(orderId: String) async throws -> ExtrasOffer {
        try await send("orders/\(orderId)/extras")
    }

    /// Orders v2 C: buy these items for the order. The server decides the price and refuses
    /// (`price_changed`) when it is not `expectedTotal`, the total the button showed. Not idempotent,
    /// but safe to retry: a purchase that went through while its answer was lost comes back as
    /// `extra_awaiting` (one unpaid purchase per order). WordPress can take ~15 s.
    func addExtras(
        orderId: String,
        packageIds: [String],
        addonIds: [String],
        templates: [String: String],
        expectedTotal: Int
    ) async throws -> AddExtrasResponse {
        try await send("orders/\(orderId)/extras", method: "POST", json: [
            "packageIds": packageIds,
            "addons": addonIds,
            "templates": templates,
            "expectedTotal": expectedTotal,
        ], timeout: 60)
    }

    // MARK: My brand (F9) — callers: `MyBrandView`

    /// Any of `addLogo` (Bool), `styleId` / `agencyStyleId` (String, or NSNull() to clear).
    /// 400 `code` `unknown_style` = that style is gone from the catalog.
    func saveBrand(_ fields: [String: Any]) async throws -> BrandSettings {
        let response: BrandResponse = try await send("account/brand", method: "PUT", json: fields)
        return response.brand
    }

    /// The logo file itself (≤ 5 MB; the server sniffs PNG / JPEG / SVG / PDF). 413 `too_large`,
    /// 400 `unsupported_type`. The first logo switches "Add my logo" on.
    func uploadBrandLogo(_ data: Data, fileName: String, contentType: String) async throws -> BrandSettings {
        var request = try makeRequest(path: "account/brand/logo", method: "POST", json: nil, query: ["name": fileName], timeout: 120)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (body, response) = try await URLSession.shared.upload(for: request, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            // As `send` (N13): the customer's wording for the answers it knows.
            let error = try? JSONDecoder().decode(ServerError.self, from: body)
            throw APIError(
                message: error.map { Self.customerWording($0.error, status: status, code: $0.code) }
                    ?? String(localized: "Upload failed. Please try again."),
                statusCode: status,
                code: error?.code
            )
        }
        do {
            return try JSONDecoder().decode(BrandResponse.self, from: body).brand
        } catch is DecodingError {
            throw UnreadableResponse()
        }
    }

    /// My brand's styles + saved settings: the catalog WITHOUT `deviceId` (N8: the Privacy Policy
    /// names three moments for it — sign-up, viewing prices, ordering; this screen shows no price).
    func brandCatalog() async throws -> CatalogResponse {
        try await send("catalog")
    }

    /// No logo, "Add my logo" off; the styles stay.
    func deleteBrandLogo() async throws -> BrandSettings {
        let response: BrandResponse = try await send("account/brand/logo", method: "DELETE")
        return response.brand
    }

    // MARK: In-app payment — callers: `PaymentFlow` only

    /// Any non-200 (`APIError.code` says why) means "pay in the browser", except `already_paid`.
    func paymentSheet(orderId: String) async throws -> PaymentSheetParams {
        try await send("orders/\(orderId)/payment-sheet", method: "POST", json: [:])
    }

    func paymentConfirm(orderId: String) async throws -> PaymentConfirmResponse {
        try await send("orders/\(orderId)/payment-confirm", method: "POST", json: [:])
    }

    // Account → Payment methods — caller: `PaymentMethodsFlow` only. 409 `in_app_disabled` = no row.
    func paymentMethods() async throws -> PaymentMethodsParams {
        try await send("payment-methods", method: "POST", json: [:])
    }

    func paymentMethodsSetupIntent() async throws -> SetupIntentParams {
        try await send("payment-methods/setup-intent", method: "POST", json: [:])
    }

    // MARK: Gửi bổ sung bản quét vào đơn ĐÃ ĐẶT

    /// Gửi thêm bản quét vào một đơn đã đặt — KHÔNG tạo đơn mới, KHÔNG thu tiền.
    /// Server: `order-webapp/HANDOFF.md` §7e (đã lên prod 11/08).
    ///
    /// 🔴 `orderId` là **cuid của đơn**, ✗ số đơn `#LS-…`: cột `Order.number` không unique nên
    /// server cố ý không nhận số đơn. App chỉ lưu `cloudOrderNumber` trong `meta.json` ⇒ phải
    /// ánh xạ qua `listOrders()` trước (xem `SupplementSheet.send()`). Không tốn thêm
    /// gì: muốn gửi bổ sung thì đằng nào cũng phải online để tải 40–200MB lên.
    ///
    /// 🔴 Lỗi 409 mang `code`: `"order_closed"` ⇒ bảo khách liên hệ support (or, cancelled
    /// unpaid, the Close message). Đọc `APIError.code`, ✗ so khớp câu chữ tiếng Anh. Delivered
    /// orders are accepted since 19/08 (`wasDelivered`/`movedToFix`); the server no longer sends
    /// `order_delivered`, and the app's `RevisionSheet` branch for it went in 2.78.
    func supplementScan(
        orderId: String,
        scanId: String,
        extraScanIds: [String] = []
    ) async throws -> SupplementScanResponse {
        try await send("orders/\(orderId)/supplement-scan", method: "POST", json: [
            "scanId": scanId,
            "extraScanIds": extraScanIds,
        ])
    }

    struct RevisionResponse: Decodable {
        let ok: Bool
    }

    /// `files`: [{name, url}] — file khách đã upload trước qua `presignOrderFile`. Server CHỈ nhận
    /// url nằm dưới prefix của chính khách, nên gửi url lạ chỉ bị bỏ qua chứ không gắn nhầm được.
    func requestRevision(
        orderId: String,
        message: String,
        files: [[String: String]] = []
    ) async throws -> RevisionResponse {
        try await send("orders/\(orderId)/revision", method: "POST", json: [
            "message": message,
            "files": files,
        ])
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
            throw APIError(message: String(localized: "Invalid upload URL"), statusCode: 0)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 300
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw APIError(
                message: String(localized: "Upload failed. Please try again."),
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
            throw APIError(message: String(localized: "Invalid upload URL"), statusCode: 0)
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
                        message: String(localized: "Upload failed. Please try again."),
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
