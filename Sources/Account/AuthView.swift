import SwiftUI

/// Đăng nhập / tạo tài khoản Cedar247 ngay trong app.
struct AuthView: View {
    @EnvironmentObject private var account: AccountStore

    @State private var isRegistering = false
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "house.and.flag")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text(isRegistering
                 ? L.t("Create your account", "Tạo tài khoản")
                 : L.t("Sign in to Cedar247", "Đăng nhập Cedar247"))
                .font(.title2.weight(.bold))
            Text(L.t(
                "Send your scans to our team and get professional floor plans back — right in this app.",
                "Gửi bản quét cho đội ngũ Cedar247 và nhận bản vẽ mặt bằng chuyên nghiệp ngay trong app."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                if isRegistering {
                    TextField(L.t("Your name", "Tên của bạn"), text: $name)
                        .textContentType(.name)
                        .textFieldStyle(.roundedBorder)
                }
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                SecureField(L.t("Password (min 8 characters)", "Mật khẩu (tối thiểu 8 ký tự)"), text: $password)
                    .textContentType(isRegistering ? .newPassword : .password)
                    .textFieldStyle(.roundedBorder)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                submit()
            } label: {
                Group {
                    if isBusy {
                        ProgressView().tint(.white)
                    } else {
                        Text(isRegistering
                             ? L.t("Create account", "Tạo tài khoản")
                             : L.t("Sign in", "Đăng nhập"))
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy || email.isEmpty || password.isEmpty || (isRegistering && name.isEmpty))

            Button {
                isRegistering.toggle()
                errorMessage = nil
            } label: {
                Text(isRegistering
                     ? L.t("Already have an account? Sign in", "Đã có tài khoản? Đăng nhập")
                     : L.t("New here? Create an account", "Chưa có tài khoản? Đăng ký"))
                    .font(.subheadline)
            }
        }
        .padding(24)
    }

    private func submit() {
        isBusy = true
        errorMessage = nil
        Task {
            do {
                if isRegistering {
                    try await account.register(email: email, password: password, name: name)
                } else {
                    try await account.login(email: email, password: password)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }
}
