import Foundation

/// Trạng thái đăng nhập của khách (token trong Keychain, thông tin trong UserDefaults).
@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var customer: CustomerDTO?

    private static let tokenKey = "app-token"
    private static let customerKey = "app-customer"

    var isSignedIn: Bool { customer != nil }

    init() {
        if let token = Keychain.read(Self.tokenKey) {
            APIClient.shared.token = token
            if let data = UserDefaults.standard.data(forKey: Self.customerKey),
               let saved = try? JSONDecoder().decode(CustomerDTO.self, from: data) {
                customer = saved
            }
            // Làm mới thông tin nền; token hỏng/hết hạn thì tự đăng xuất
            Task { await refresh() }
        }
    }

    func refresh() async {
        guard APIClient.shared.token != nil else { return }
        do {
            let me = try await APIClient.shared.me()
            setCustomer(me.customer)
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

    func signOut() {
        APIClient.shared.token = nil
        Keychain.delete(Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.customerKey)
        customer = nil
    }

    private func apply(_ auth: AuthResponse) {
        APIClient.shared.token = auth.token
        Keychain.save(auth.token, for: Self.tokenKey)
        setCustomer(auth.customer)
    }

    private func setCustomer(_ c: CustomerDTO) {
        customer = c
        if let data = try? JSONEncoder().encode(c) {
            UserDefaults.standard.set(data, forKey: Self.customerKey)
        }
    }
}
