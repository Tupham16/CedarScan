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
    @State private var showForgotPassword = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "house.and.flag")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text(isRegistering
                 ? String(localized: "Create your account")
                 : String(localized: "Sign in to Cedar247"))
                .font(.title2.weight(.bold))
            Text(String(localized: "Send your scans to our team and get professional floor plans back — right in this app."))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                if isRegistering {
                    TextField(String(localized: "Your name"), text: $name)
                        .textContentType(.name)
                        .textFieldStyle(.roundedBorder)
                }
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                SecureField(String(localized: "Password (min 8 characters)"), text: $password)
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
                             ? String(localized: "Create account")
                             : String(localized: "Sign in"))
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
                     ? String(localized: "Already have an account? Sign in")
                     : String(localized: "New here? Create an account"))
                    .font(.subheadline)
            }

            if !isRegistering {
                Button {
                    showForgotPassword = true
                } label: {
                    Text(String(localized: "Forgot password?"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .sheet(isPresented: $showForgotPassword) {
            ForgotPasswordView()
        }
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
