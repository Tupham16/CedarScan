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
                        Text(L.t(
                            "We will email you a 6-digit code to reset your password.",
                            "Chúng tôi sẽ gửi mã 6 số qua email để đặt lại mật khẩu."
                        ))
                    }
                } else if step == 1 {
                    Section {
                        TextField(L.t("6-digit code", "Mã 6 số"), text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                        SecureField(L.t("New password (min 8 characters)", "Mật khẩu mới (tối thiểu 8 ký tự)"), text: $newPassword)
                            .textContentType(.newPassword)
                    } footer: {
                        Text(L.t(
                            "Check the inbox (and spam folder) of \(email). The code expires in 15 minutes.",
                            "Kiểm tra hộp thư (cả mục spam) của \(email). Mã hết hạn sau 15 phút."
                        ))
                    }
                } else {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.green)
                            Text(L.t("Password updated!", "Đã đổi mật khẩu!"))
                                .font(.headline)
                            Text(L.t(
                                "Sign in with your new password. Other devices were signed out for safety.",
                                "Đăng nhập bằng mật khẩu mới. Các thiết bị khác đã bị đăng xuất để bảo mật."
                            ))
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
                                         ? L.t("Send code", "Gửi mã")
                                         : L.t("Set new password", "Đặt mật khẩu mới"))
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
            .navigationTitle(L.t("Reset password", "Đặt lại mật khẩu"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(step == 2 ? L.t("Close", "Đóng") : L.t("Cancel", "Hủy")) { dismiss() }
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
