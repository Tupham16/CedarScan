import SwiftUI

/// Đăng nhập / tạo tài khoản Cedar247 ngay trong app.
struct AuthView: View {
    @EnvironmentObject private var account: AccountStore

    @State private var isRegistering = false
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    /// F8: a friend's invite code — sent only when creating an account (the only moment one can be
    /// entered; server `auth/register`).
    @State private var inviteCode = ""
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var showForgotPassword = false
    @FocusState private var focused: Field?

    private enum Field { case name, email, password, invite }

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
                        .fogField($focused, .name)
                }
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .fogField($focused, .email)
                SecureField(String(localized: "Password (min 8 characters)"), text: $password)
                    .textContentType(isRegistering ? .newPassword : .password)
                    .fogField($focused, .password)
                if isRegistering {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField(String(localized: "Invite code"), text: $inviteCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .fogField($focused, .invite)
                        Text(String(localized: "Invite code (optional) — it can only be added now."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                }
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
                .padding(.vertical, 14)
            }
            .buttonStyle(FogPrimary(busy: isBusy))
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

    /// A refused invite code (F8) comes with a `code` and creates nothing: the customer fixes the
    /// code or empties the field. The server's English sentence is the same text as these keys.
    private static func message(for error: Error) -> String {
        switch (error as? APIError)?.code ?? "" {
        case "invite_invalid":
            return String(localized: "This invite code isn't valid. Check it, or leave the field empty.")
        case "invite_not_eligible":
            return String(localized: "This invite code can't be used here: invite codes are only for new customers on an iPhone that hasn't used free orders yet. Leave the field empty to create your account.")
        case "invite_closed":
            return String(localized: "Invite codes can't be used at the moment. Leave the field empty to create your account.")
        default:
            return error.localizedDescription
        }
    }

    private func submit() {
        isBusy = true
        errorMessage = nil
        Task {
            do {
                if isRegistering {
                    try await account.register(email: email, password: password, name: name,
                                               inviteCode: inviteCode.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    try await account.login(email: email, password: password)
                }
            } catch {
                errorMessage = Self.message(for: error)
            }
            isBusy = false
        }
    }
}
