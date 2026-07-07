import SwiftUI

/// Màn nhập mã 6 số xác minh email (hiện khi tài khoản chưa xác minh).
struct VerifyEmailView: View {
    @EnvironmentObject private var account: AccountStore

    @State private var code = ""
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var resendCooldown = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text(L.t("Verify your email", "Xác minh email"))
                .font(.title2.weight(.bold))
            Text(L.t(
                "We sent a 6-digit code to \(account.customer?.email ?? "your email"). Enter it below to activate your account.",
                "Chúng tôi đã gửi mã 6 số tới \(account.customer?.email ?? "email của bạn"). Nhập mã bên dưới để kích hoạt tài khoản."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            TextField("000000", text: $code)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 30, weight: .bold, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .onChange(of: code) { _, newValue in
                    code = String(newValue.filter(\.isNumber).prefix(6))
                }

            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }
            if let infoMessage {
                Text(infoMessage).font(.footnote).foregroundStyle(.green)
            }

            Button {
                submit()
            } label: {
                Group {
                    if isBusy { ProgressView().tint(.white) }
                    else { Text(L.t("Verify", "Xác minh")) }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy || code.count != 6)

            Button {
                resend()
            } label: {
                Text(resendCooldown > 0
                     ? L.t("Resend code (\(resendCooldown)s)", "Gửi lại mã (\(resendCooldown)s)")
                     : L.t("Resend code", "Gửi lại mã"))
                    .font(.subheadline)
            }
            .disabled(resendCooldown > 0 || isBusy)

            Button(role: .destructive) {
                account.signOut()
            } label: {
                Text(L.t("Sign out", "Đăng xuất"))
                    .font(.footnote)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .onDisappear { timer?.invalidate() }
    }

    private func submit() {
        isBusy = true
        errorMessage = nil
        infoMessage = nil
        Task {
            do {
                _ = try await APIClient.shared.verifyEmail(code: code)
                account.markVerified()
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func resend() {
        errorMessage = nil
        infoMessage = nil
        Task {
            do {
                _ = try await APIClient.shared.resendCode()
                infoMessage = L.t("A new code has been sent.", "Đã gửi mã mới.")
                startCooldown()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startCooldown() {
        resendCooldown = 60
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            Task { @MainActor in
                if resendCooldown > 0 { resendCooldown -= 1 } else { t.invalidate() }
            }
        }
    }
}
