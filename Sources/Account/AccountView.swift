import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var account: AccountStore
    @State private var showDeleteAccount = false
    @AppStorage("scanCoachHaptics") private var scanCoachHaptics = true
    @AppStorage("scanCoachVoice") private var scanCoachVoice = false

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
                            // 🔴 Câu này TỪNG ghi "(PDF/PNG/DWG)" và sai theo hướng TỐN TIỀN CHỦ APP:
                            // nó gộp DWG vào như thể đã bao gồm, trong khi DWG là ADD-ON TÍNH TIỀN
                            // riêng (`id: "dwg"`, "CAD file (DWG)" trong catalog server). Khách đọc
                            // xong tưởng có sẵn, tới lúc nhận hàng không thấy → hoặc khiếu nại, hoặc
                            // chủ app phải làm không công. Nó cũng bỏ sót JPG (mặc định) và kể PNG
                            // như mặc định (thật ra chỉ có khi khách yêu cầu).
                            //
                            // Chính sách chủ app chốt 2026-07-20: mặc định PDF + JPG · yêu cầu thì
                            // thêm được SVG/PNG · DWG là add-on. Đừng liệt kê định dạng ở chỗ nào
                            // khác nữa — đây là chỗ DUY NHẤT trong app nói về định dạng file giao,
                            // giữ một nguồn sự thật thì sau này đổi chính sách chỉ phải sửa một chỗ.
                            Text(L.t(
                                "Scan your space with LiDAR, send it to Cedar247, and our team will produce professional 2D floor plans. Delivered as PDF + JPG (SVG/PNG on request). DWG is a paid add-on.",
                                "Quét không gian bằng LiDAR, gửi cho Cedar247 — đội ngũ của chúng tôi sẽ làm bản vẽ mặt bằng chuyên nghiệp. Giao PDF + JPG (cần SVG/PNG thì báo). DWG là dịch vụ thêm, tính tiền riêng."
                            ))
                        }
                        Section {
                            Toggle(isOn: $scanCoachHaptics) {
                                Label(L.t("Vibration alerts", "Rung cảnh báo"), systemImage: "iphone.radiowaves.left.and.right")
                            }
                            Toggle(isOn: $scanCoachVoice) {
                                Label(L.t("Voice coaching", "Nhắc bằng giọng nói"), systemImage: "speaker.wave.2")
                            }
                        } header: {
                            Text(L.t("Scan coaching", "Trợ giúp khi quét"))
                        } footer: {
                            Text(L.t(
                                "Alerts while scanning when you move too fast, light is low, or you pass through a doorway.",
                                "Cảnh báo trong lúc quét khi đi nhanh quá, thiếu sáng hoặc đi qua cửa."
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
