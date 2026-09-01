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
                            Text(String(localized: "About"))
                        }
                        // 🔴 FOOTER CỦA MỤC "Giới thiệu" ĐÃ XOÁ 19/08 — CHỦ APP CHỐT
                        // (*"Tab tài khoản: xóa dòng quét không gian bằng lidar,... đi"*).
                        // Câu cũ: "Quét không gian bằng LiDAR, gửi cho Cedar247 … Giao PDF + JPG
                        // (cần SVG/PNG thì báo). DWG là dịch vụ thêm, tính tiền riêng."
                        //
                        // Câu đó nói về ĐỊNH DẠNG FILE GIAO nên **ĐÃ DỜI, ✗ VỨT**: nay nằm ở
                        // `OrderFAQContent` (tab Learn → "Hỏi đáp về đơn hàng", mục `id: "formats"`
                        // — ✗ trỏ theo câu hỏi, câu chữ đã đổi một lần). ✗ chép định dạng trở lại đây.
                        //
                        // 🔴 **VÀ SỬA LUÔN MỘT LỜI DẶN SAI ĐÃ NẰM Ở ĐÂY TỪ LÂU** (vòng soi đối kháng
                        // 19/08 bắt): chú thích cũ viết "đây là chỗ DUY NHẤT trong app nói về định
                        // dạng file giao". **KHÔNG ĐÚNG** — `LegalDoc.terms` mục "The service" đã
                        // liệt kê đủ y hệt (PDF+JPG mặc định · SVG/PNG khi yêu cầu · DWG add-on),
                        // và đó mới là bản có HIỆU LỰC PHÁP LÝ, còn được sinh ra ba trang web công
                        // khai. ⇒ Đổi chính sách định dạng thì phải sửa **BA** chỗ: `OrderFAQContent`
                        // · `LegalDoc.terms` · **`HUONG-DAN.md` mục "Bạn nhận được định dạng nào"**
                        // (sổ tay chủ app gửi KHÁCH — vòng soi thứ hai mới lôi ra chỗ này). Tin lời
                        // dặn cũ mà sửa một chỗ là để ba văn bản của cùng một app nói khác nhau.
                        //
                        // Vì sao câu cũ phải cẩn thận đến thế (giữ lại để người sau khỏi viết lại
                        // cái sai đã trả giá): đời trước nó ghi "(PDF/PNG/DWG)" — gộp DWG vào như
                        // thể đã bao gồm, trong khi DWG là ADD-ON TÍNH TIỀN riêng (`id: "dwg"`,
                        // nhãn "CAD File" trong catalog server từ 13/08). Khách đọc xong tưởng có
                        // sẵn, tới lúc nhận hàng không thấy → hoặc khiếu nại, hoặc chủ app phải làm
                        // không công. Chính sách chủ app chốt 2026-07-20 và vẫn đúng: mặc định
                        // PDF + JPG · yêu cầu thì thêm được SVG/PNG · DWG là add-on.
                        Section {
                            Toggle(isOn: $scanCoachHaptics) {
                                Label(String(localized: "Vibration alerts"), systemImage: "iphone.radiowaves.left.and.right")
                            }
                            Toggle(isOn: $scanCoachVoice) {
                                Label(String(localized: "Voice coaching"), systemImage: "speaker.wave.2")
                            }
                        } header: {
                            Text(String(localized: "Scan coaching"))
                        } footer: {
                            Text(String(localized: "Alerts while scanning when you move or turn too fast, light is low, or you get too close."))
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
                                Label(String(localized: "Sign out"), systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        }
                        Section {
                            Button(role: .destructive) {
                                showDeleteAccount = true
                            } label: {
                                Label(String(localized: "Delete account"), systemImage: "trash")
                            }
                        } footer: {
                            // 🔴 CÂU NÀY PHẢI KHỚP `LegalView` mục "Deleting your account" VÀ khớp
                            // `account/delete/route.ts` trên server. Bản cũ ("your account and
                            // scans") mơ hồ giữa MÁY và SERVER: trên máy `submit()` chỉ gọi API rồi
                            // đăng xuất, thư mục `Documents/Scans` KHÔNG bị đụng.
                            Text(String(localized: "Deletes your account and the scans we hold in the cloud. Scans on this iPhone are not affected. This cannot be undone."))
                        }
                    }
                } else {
                    ScrollView {
                        AuthView()
                        legalBlock
                    }
                }
            }
            .navigationTitle(String(localized: "Account"))
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
                        Text(String(localized: "This permanently deletes your account and the scans we hold in the cloud. Your orders stay in our records, and so do the files attached to them. Scans on this iPhone are not affected. This CANNOT be undone."))
                        .font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    SecureField(String(localized: "Enter your password to confirm"), text: $password)
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
                                Text(String(localized: "Delete my account forever"))
                                    .font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(isBusy || password.isEmpty)
                }
            }
            .navigationTitle(String(localized: "Delete account"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "Cancel")) { dismiss() }
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
