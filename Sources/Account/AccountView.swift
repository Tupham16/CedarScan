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
                    // Mục pháp lý đi KÈM cả hai màn chưa-vào-được-tài-khoản: App Store review mở
                    // app lần đầu là rơi đúng vào đây, và Privacy Policy phải với tới được ngay
                    // lúc đó chứ không phải sau khi đăng nhập.
                    ScrollView {
                        VerifyEmailView()
                        legalBlock
                    }
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
                            // riêng (`id: "dwg"`, nhãn "CAD File" trong catalog server — đổi từ
                            // "CAD file (DWG)" ngày 13/08). Khách đọc
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
                                "Alerts while scanning when you move or turn too fast, light is low, or you get too close.",
                                "Cảnh báo trong lúc quét khi đi/xoay nhanh quá, thiếu sáng hoặc dí quá sát."
                            ))
                        }
                        Section {
                            LegalLinks()
                        } header: {
                            Text("Legal & Privacy")
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
                            // 🔴 CÂU NÀY PHẢI KHỚP `LegalView` mục "Deleting your account" VÀ khớp
                            // `account/delete/route.ts` trên server. Bản cũ ("your account and
                            // scans") mơ hồ giữa MÁY và SERVER: trên máy `submit()` chỉ gọi API rồi
                            // đăng xuất, thư mục `Documents/Scans` KHÔNG bị đụng.
                            Text(L.t(
                                "Deletes your account and the scans we hold in the cloud. Scans on this iPhone are not affected. This cannot be undone.",
                                "Xóa tài khoản và các bản quét đang nằm trên máy chủ. Bản quét trong máy này không bị ảnh hưởng. Không thể hoàn tác."
                            ))
                        }
                    }
                } else {
                    ScrollView {
                        AuthView()
                        legalBlock
                    }
                }
            }
            .navigationTitle(L.t("Account", "Tài khoản"))
            .sheet(isPresented: $showDeleteAccount) {
                DeleteAccountView()
            }
        }
    }

    /// Mục Legal & Privacy cho hai màn KHÔNG phải `List` (chưa đăng nhập / chờ xác minh).
    /// `LegalLinks` chỉ là mấy `NavigationLink` nên đặt trong `VStack` cũng chạy — chỉ cần tự vẽ
    /// tiêu đề và đường kẻ vì ở đây không có `Section` của List lo hộ.
    private var legalBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Legal & Privacy")
                .font(.footnote)
                .foregroundStyle(.secondary)
            // Khoảng cách do `spacing` của VStack lo, KHÔNG dùng `.padding` gắn lên `LegalLinks()`:
            // đó là một `ForEach`, và modifier gắn lên ForEach phân phối xuống từng dòng hay không
            // là chuyện dễ đoán sai — spacing thì luôn đúng.
            LegalLinks()
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 12)
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
                        // 🔴 BA CHỖ SAI CỦA BẢN CŨ, SỬA 13/08 — ✗ viết lại kiểu cũ:
                        // (1) "uploaded files" HỨA QUÁ: prefix `order-files/` KHÔNG có đường xoá
                        //     nào trong toàn repo server. Chính câu này đã bị review đối kháng bắt
                        //     23/07 và ĐÃ sửa trong `LegalView`, nhưng màn hình khách THỰC SỰ BẤM
                        //     thì bị bỏ sót — chỗ tệ nhất để nói sai.
                        // (2) "Orders already delivered" nói NHẸ ĐI: `deleteAppAccount` không đụng
                        //     bảng Order, nên MỌI đơn ở lại, giao hay chưa. Khách có đơn đang vẽ dở
                        //     đọc câu cũ sẽ tưởng đơn biến mất theo tài khoản.
                        // (3) Không nói rõ bản quét TRONG MÁY không bị đụng (chỉ server bị xoá).
                        Text(L.t(
                            "This permanently deletes your account and the scans we hold in the cloud. Your orders stay in our records, and so do the files attached to them. Scans on this iPhone are not affected. This CANNOT be undone.",
                            "Thao tác này xóa vĩnh viễn tài khoản và các bản quét đang nằm trên máy chủ. Đơn hàng vẫn lưu trong sổ sách, kèm các file đính kèm của đơn. Bản quét trong máy này không bị ảnh hưởng. KHÔNG thể hoàn tác."
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
