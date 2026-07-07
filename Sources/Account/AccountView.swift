import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var account: AccountStore
    @State private var showDeleteAccount = false

    var body: some View {
        NavigationStack {
            Group {
                if account.needsVerification {
                    ScrollView { VerifyEmailView() }
                } else if let customer = account.customer {
                    List {
                        Section {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(customer.name)
                                    .font(.headline)
                                Text(customer.email)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        Section {
                            Link(destination: URL(string: "https://cedar247.com")!) {
                                Label("cedar247.com", systemImage: "globe")
                            }
                        } header: {
                            Text(L.t("About", "Giới thiệu"))
                        } footer: {
                            Text(L.t(
                                "Scan your space with LiDAR, send it to Cedar247, and our team will produce professional 2D floor plans (PDF/PNG/DWG) for you.",
                                "Quét không gian bằng LiDAR, gửi cho Cedar247 — đội ngũ của chúng tôi sẽ làm bản vẽ mặt bằng chuyên nghiệp (PDF/PNG/DWG) cho bạn."
                            ))
                        }
                        Section {
                            Button(role: .destructive) {
                                account.signOut()
                            } label: {
                                Label(L.t("Sign out", "Đăng xuất"), systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        }
                        Section {
                            Button(role: .destructive) {
                                showDeleteAccount = true
                            } label: {
                                Label(L.t("Delete account", "Xóa tài khoản"), systemImage: "trash")
                            }
                        } footer: {
                            Text(L.t(
                                "Permanently deletes your account and scans. This cannot be undone.",
                                "Xóa vĩnh viễn tài khoản và các bản quét. Không thể hoàn tác."
                            ))
                        }
                    }
                } else {
                    ScrollView {
                        AuthView()
                    }
                }
            }
            .navigationTitle(L.t("Account", "Tài khoản"))
            .sheet(isPresented: $showDeleteAccount) {
                DeleteAccountView()
            }
        }
    }
}

/// Xóa tài khoản (yêu cầu App Store): xác nhận bằng mật khẩu.
struct DeleteAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var account: AccountStore

    @State private var password = ""
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text(L.t(
                            "This permanently deletes your account, scans and uploaded files. Orders already delivered stay in our records. This CANNOT be undone.",
                            "Thao tác này xóa vĩnh viễn tài khoản, bản quét và file đã tải lên. Đơn đã giao vẫn lưu trong sổ sách. KHÔNG thể hoàn tác."
                        ))
                        .font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    SecureField(L.t("Enter your password to confirm", "Nhập mật khẩu để xác nhận"), text: $password)
                        .textContentType(.password)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button(role: .destructive) {
                        submit()
                    } label: {
                        HStack {
                            if isBusy {
                                ProgressView()
                            } else {
                                Text(L.t("Delete my account forever", "Xóa vĩnh viễn tài khoản của tôi"))
                                    .font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(isBusy || password.isEmpty)
                }
            }
            .navigationTitle(L.t("Delete account", "Xóa tài khoản"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("Cancel", "Hủy")) { dismiss() }
                }
            }
        }
    }

    private func submit() {
        isBusy = true
        errorMessage = nil
        Task {
            do {
                _ = try await APIClient.shared.deleteAccount(password: password)
                dismiss()
                account.signOut()
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }
}
