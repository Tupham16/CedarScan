import SwiftUI

/// Quên mật khẩu: nhập email → nhận mã 6 số → đặt mật khẩu mới.
struct ForgotPasswordView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0 // 0 = nhập email, 1 = nhập mã + mật khẩu mới, 2 = xong
    @State private var email = ""
    @State private var code = ""
    @State private var newPassword = ""
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if step == 0 {
                    Section {
                        TextField("Email", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } footer: {
                        Text(String(localized: "We will email you a 6-digit code to reset your password."))
                    }
                } else if step == 1 {
                    Section {
                        TextField(String(localized: "6-digit code"), text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                        SecureField(String(localized: "New password (min 8 characters)"), text: $newPassword)
                            .textContentType(.newPassword)
                    } footer: {
                        Text(String(localized: "Check the inbox (and spam folder) of \(email). The code expires in 15 minutes."))
                    }
                } else {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.green)
                            Text(String(localized: "Password updated!"))
                                .font(.headline)
                            Text(String(localized: "Sign in with your new password. Other devices were signed out for safety."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if step < 2 {
                    Section {
                        Button {
                            submit()
                        } label: {
                            HStack {
                                if isBusy {
                                    ProgressView().tint(.white)
                                } else {
                                    Text(step == 0
                                         ? String(localized: "Send code")
                                         : String(localized: "Set new password"))
                                        .font(.headline)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .listRowInsets(EdgeInsets())
                        .disabled(isBusy || (step == 0 ? email.isEmpty : code.count < 6 || newPassword.count < 8))
                    }
                }
            }
            .navigationTitle(String(localized: "Reset password"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(step == 2 ? String(localized: "Close") : String(localized: "Cancel")) { dismiss() }
                }
            }
        }
    }

    private func submit() {
        isBusy = true
        errorMessage = nil
        Task {
            do {
                if step == 0 {
                    _ = try await APIClient.shared.forgotPassword(email: email)
                    step = 1
                } else {
                    _ = try await APIClient.shared.resetPassword(
                        email: email, code: code, newPassword: newPassword
                    )
                    step = 2
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }
}
