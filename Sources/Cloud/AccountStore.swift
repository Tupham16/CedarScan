import Foundation

/// Trạng thái đăng nhập của khách (token trong Keychain, thông tin trong UserDefaults).
@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var customer: CustomerDTO?
    @Published private(set) var emailVerified = false

    private static let tokenKey = "app-token"
    private static let customerKey = "app-customer"
    private static let emailVerifiedKey = "app-email-verified"

    var isSignedIn: Bool { customer != nil }
    var needsVerification: Bool { customer != nil && !emailVerified }

    init() {
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

    func markVerified() {
        setEmailVerified(true)
    }

    func signOut() {
        APIClient.shared.token = nil
        Keychain.delete(Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.customerKey)
        // Dọn cả cờ xác minh: từ khi nó được LƯU XUỐNG ĐĨA, để sót lại `true` nghĩa là tài khoản
        // đăng nhập sau trên cùng máy thừa hưởng trạng thái đã-xác-minh của người trước.
        UserDefaults.standard.removeObject(forKey: Self.emailVerifiedKey)
        customer = nil
        emailVerified = false
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
