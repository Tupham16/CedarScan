import Foundation
import StripePaymentSheet
import UIKit

/// Trạng thái đăng nhập của khách (token trong Keychain, thông tin trong UserDefaults).
@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var customer: CustomerDTO?
    @Published private(set) var emailVerified = false

    private static let tokenKey = "app-token"
    private static let customerKey = "app-customer"
    private static let emailVerifiedKey = "app-email-verified"
    /// N8 (2.79): set on the first launch of an install. Keychain items outlive an uninstall,
    /// UserDefaults does not — see `init`.
    private static let installedKey = "app-installed.v1"

    var isSignedIn: Bool { customer != nil }

    /// The signed-in customer's id for code outside the view tree (`PaymentFlow` files its markers
    /// under it). Same record `init()` restores; `signOut()` removes it.
    static var savedCustomerId: String? { savedCustomer?.id }
    /// Same record, for the pay sheet's default billing details (Link).
    static var savedCustomer: CustomerDTO? {
        guard let data = UserDefaults.standard.data(forKey: customerKey) else { return nil }
        return try? JSONDecoder().decode(CustomerDTO.self, from: data)
    }
    /// Server says the Account tab may show "Payment methods" (`GET me` → `paymentMethods`).
    /// Not stored: false until this launch's `refresh()` answers.
    @Published private(set) var paymentMethodsAvailable = false
    /// F9: the server has My brand (`GET me` → `myBrand`) — the Account row shows only then, so a
    /// 2.79 build on a server without it shows no broken screen. Same lifetime as the flag above.
    @Published private(set) var myBrandAvailable = false
    /// F10b: the team this account is on (`GET me` → `team`): the Account "Team" row, the order
    /// form's team-card line, who may cancel a teammate's order. Same lifetime as the flags above.
    @Published private(set) var team: TeamSummaryDTO?
    var needsVerification: Bool { customer != nil && !emailVerified }

    init() {
        // N8 (2.79): the token sits in the Keychain, which iOS keeps after the app is deleted — a
        // reinstall (or the next owner of a phone sold without being erased) came back signed in
        // to the old account. No flag = first launch of this install ⇒ the old token goes before
        // it is read. An update from a build without the flag still holds `customerKey` while
        // signed in (UserDefaults survives updates, not uninstalls): that session stays.
        // Only while protected data is readable: before the first unlock after a reboot
        // UserDefaults reads back empty (`ScanStore.loadProjects` has the same case) and every
        // signed-in phone would look like a fresh install.
        if UIApplication.shared.isProtectedDataAvailable,
           !UserDefaults.standard.bool(forKey: Self.installedKey) {
            if UserDefaults.standard.data(forKey: Self.customerKey) == nil {
                Keychain.delete(Self.tokenKey)
            } else {
                // The session kept across the update: a token saved before 2.31 still has the
                // access class that moves with backups — moved once, in place, to today's
                // this-device-only class.
                Keychain.makeThisDeviceOnly(Self.tokenKey)
            }
            UserDefaults.standard.set(true, forKey: Self.installedKey)
        }
        if let token = Keychain.read(Self.tokenKey) {
            APIClient.shared.token = token
            if let data = UserDefaults.standard.data(forKey: Self.customerKey),
               let saved = try? JSONDecoder().decode(CustomerDTO.self, from: data) {
                customer = saved
            }
            // 🔴 PHẢI khôi phục cờ xác minh cùng lúc với `customer`. Trước 2026-07-20 dòng này
            // KHÔNG tồn tại: `emailVerified` khởi tạo `false` và không ai đọc nó lên, nên sau MỌI
            // lần khởi động app thì `needsVerification == true` với MỌI khách — kể cả người đã
            // xác minh từ lâu — cho tới khi `refresh()` bên dưới trả về. Mà `refresh()` nuốt lỗi
            // mạng (`catch` rỗng), nên khách mở app lúc mất sóng thì cờ sai NẰM NGUYÊN CẢ PHIÊN:
            // họ thấy "Xác minh email để đặt hàng" thay cho nút đặt hàng, và bị đẩy vào màn đòi
            // mã 6 số chưa từng được gửi.
            emailVerified = UserDefaults.standard.bool(forKey: Self.emailVerifiedKey)
            // Làm mới thông tin nền; token hỏng/hết hạn thì tự đăng xuất
            Task { await refresh() }
        }
    }

    func refresh() async {
        guard APIClient.shared.token != nil else { return }
        do {
            let me = try await APIClient.shared.me()
            setCustomer(me.customer)
            // `if let` chứ KHÔNG phải `?? false`: `MeResponse.emailVerified` khai là `Bool?`, tức
            // server ĐƯỢC PHÉP không trả field này. Với `?? false` thì một lần server im lặng là
            // hạ cấp khách đã xác minh xuống chưa-xác-minh — bất đối xứng đúng theo hướng nguy
            // hiểm. Không biết thì GIỮ NGUYÊN giá trị đang có, đừng đoán xấu.
            if let verified = me.emailVerified {
                setEmailVerified(verified)
            }
            paymentMethodsAvailable = me.paymentMethods == true
            myBrandAvailable = me.myBrand == true
            team = me.team
        } catch let error as APIError where error.statusCode == 401 {
            signOut()
        } catch {
            // Lỗi mạng: giữ phiên hiện tại
        }
    }

    func register(email: String, password: String, name: String) async throws {
        let result = try await APIClient.shared.register(email: email, password: password, name: name)
        apply(result)
    }

    func login(email: String, password: String) async throws {
        let result = try await APIClient.shared.login(email: email, password: password)
        apply(result)
    }

    /// The server refused saved payment methods (`in_app_disabled`): hide the row until next refresh.
    func paymentMethodsWentAway() {
        paymentMethodsAvailable = false
    }

    func markVerified() {
        setEmailVerified(true)
    }

    /// N14 (2.79): the server's answer NOW — nil when there is none (offline, an error, no field,
    /// another account signed in meanwhile). Updates the flag like `refresh()`, so a "no" opens
    /// `AccountGateSheet` on the code screen (a stale `true` would close it at once). Callers stop
    /// only on `false`, the server's own word: the cached flag alone never blocks anybody (trap #17).
    func serverEmailVerified() async -> Bool? {
        guard let asked = customer?.id, APIClient.shared.token != nil,
              let me = try? await APIClient.shared.me(),
              customer?.id == asked, me.customer.id == asked,
              let verified = me.emailVerified else { return nil }
        setEmailVerified(verified)
        return verified
    }

    /// Every sign-out passes here (Account tab, verify screen, account deletion, a 401 in `refresh`).
    func signOut() {
        // Before the session goes (plan: unregister first); this phone stops getting its pushes.
        PushNotifications.shared.signingOut()
        // N8 (2.79): scan files still going up in the background (an order cancelled mid-upload
        // keeps transferring, trap #50) stop here, and their journal goes — ✗ a scan of the
        // account that left reaching our storage afterwards.
        BackgroundUploads.shared.cancelAll()
        APIClient.shared.token = nil
        Keychain.delete(Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.customerKey)
        // Dọn cả cờ xác minh: từ khi nó được LƯU XUỐNG ĐĨA, để sót lại `true` nghĩa là tài khoản
        // đăng nhập sau trên cùng máy thừa hưởng trạng thái đã-xác-minh của người trước.
        UserDefaults.standard.removeObject(forKey: Self.emailVerifiedKey)
        customer = nil
        emailVerified = false
        paymentMethodsAvailable = false
        myBrandAvailable = false
        team = nil
        // Link remembers the customer on this phone; the next account must not inherit it.
        PaymentSheet.resetCustomer()
        // Which team messages were shown / left open, per order.
        OrderMessageMemory.clear()
    }

    private func apply(_ auth: AuthResponse) {
        APIClient.shared.token = auth.token
        Keychain.save(auth.token, for: Self.tokenKey)
        setCustomer(auth.customer)
        // Ở đây `?? false` là ĐÚNG (khác với `refresh()`): đăng ký/đăng nhập mới thì server nói
        // thẳng trạng thái, và tài khoản vừa tạo thì chưa xác minh thật.
        setEmailVerified(auth.emailVerified ?? false)
    }

    private func setEmailVerified(_ value: Bool) {
        emailVerified = value
        UserDefaults.standard.set(value, forKey: Self.emailVerifiedKey)
    }

    private func setCustomer(_ c: CustomerDTO) {
        customer = c
        if let data = try? JSONEncoder().encode(c) {
            UserDefaults.standard.set(data, forKey: Self.customerKey)
        }
    }
}
