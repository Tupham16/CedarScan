import SwiftUI

/// Cổng đăng nhập / xác minh email mở NGAY TRÊN màn đang đứng, thay vì đá khách sang tab Tài khoản.
///
/// Lý do tồn tại (chủ app chốt 2026-07-20): khách vừa đi bộ 10–30 phút quét xong, bấm "Đặt hàng
/// ngay", và — nếu chưa đăng nhập — nhận đúng MỘT DÒNG CHỮ XÁM cỡ `.caption` bảo họ tự đi tìm
/// "mục Tài khoản". Không nút, không chuyển tab được (`TabView` ở `CedarScanApp` không có
/// `selection:`). Đó là chỗ rơi khách rõ nhất của luồng đặt hàng.
///
/// 🔴 VÌ SAO SHEET CHỨ KHÔNG PHẢI CHUYỂN TAB — đừng "sửa cho đúng kiến trúc" thành `TabView(selection:)`:
/// chuyển tab chỉ trả lời được "đi đâu", còn bỏ ngỏ "quay lại thế nào". `AuthView`/`VerifyEmailView`
/// là view INLINE trong `Group` của `AccountView` (không phải sheet) nên chúng KHÔNG có gì để
/// `dismiss` — đăng nhập xong khách đứng lại ở tab Tài khoản, phải tự bấm về tab Bản quét rồi tự
/// mở lại đúng bản quét vừa nãy. Sheet thì đóng lại là khách đứng nguyên chỗ cũ. Đổi lại còn
/// KHÔNG phải đụng `CedarScanApp` — nơi đang gắn `purgeDeliveredScans` (xoá dữ liệu khách không
/// hoàn tác).
struct AccountGateSheet: View {
    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss

    /// Đủ điều kiện đặt hàng. Tách thành biến riêng chứ không viết thẳng vào modifier: CI của repo
    /// này nhạy "Swift type-check timeout", và biểu thức ghép trong modifier là chỗ đầu tiên nó gãy.
    private var canOrder: Bool { account.isSignedIn && !account.needsVerification }

    var body: some View {
        NavigationStack {
            ScrollView {
                // 🔴 BA nhánh, không phải hai — nhánh `canOrder` đứng ĐẦU và cố ý KHÔNG dựng form nào.
                //
                // Bản đầu chỉ có `if needsVerification { VerifyEmailView } else { AuthView }`, tức
                // trạng thái "đã xong" của sheet CHÍNH LÀ form đăng nhập. Hai cách hỏng, cả hai
                // đều do review đối kháng bắt được chứ không phải compile:
                //
                //  1. Khách gõ ĐÚNG mã 6 số → `markVerified()` lật cờ → SwiftUI dựng lại body
                //     TRƯỚC khi `dismiss()` kịp chạy → suốt ~0.3s animation trượt xuống, người vừa
                //     làm đúng lại nhìn thấy tiêu đề đổi thành "Đăng nhập" và hai ô email/mật khẩu
                //     TRỐNG. Đọc thành "sai rồi, nó đá mình ra đăng nhập lại" — đúng vào giây phút
                //     cần trấn an nhất.
                //  2. `canOrder` đã `true` ngay lúc sheet dựng lần đầu → `.onChange` KHÔNG bắn (nó
                //     chỉ bắt THAY ĐỔI, không xét giá trị ban đầu) → sheet đứng im hiện form đăng
                //     nhập cho người ĐANG đăng nhập, thoát được mỗi bằng "Hủy". Tệ hơn: khách
                //     tưởng mình bị đăng xuất, bấm "Chưa có tài khoản? Đăng ký" và tạo tài khoản
                //     THỨ HAI — `apply()` ghi đè token trong Keychain, phiên gốc mất luôn.
                //
                // `AccountView` không dính vì nó có nhánh thứ ba (List thông tin tài khoản).
                // Sheet này lúc đầu bỏ mất đúng nhánh giữa đó.
                if canOrder {
                    ProgressView()
                        .padding(.top, 40)
                } else if account.needsVerification {
                    VerifyEmailView()
                } else {
                    AuthView()
                }
            }
            // CỐ Ý không có `.navigationTitle`: `AuthView` và `VerifyEmailView` đều tự vẽ tiêu đề
            // lớn của mình (`AuthView.swift:20`, `VerifyEmailView.swift:19`), thêm tiêu đề nav là
            // hai tầng chữ chồng nhau. Tệ hơn, tiêu đề nav KHÔNG thấy được state `isRegistering`
            // nằm bên trong `AuthView`, nên khách bấm "Chưa có tài khoản? Đăng ký" là thân sheet
            // đổi thành "Tạo tài khoản" trong khi thanh nav vẫn đứng nguyên chữ "Đăng nhập".
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("Cancel", "Hủy")) { dismiss() }
                }
            }
        }
        // Cặp đôi BẮT BUỘC với `.onChange` bên dưới, đừng bỏ cái nào: `.onChange` bỏ qua giá trị
        // BAN ĐẦU, nên nếu trạng thái đã đủ điều kiện ngay lúc sheet hiện ra thì đây là thứ DUY
        // NHẤT đóng nó lại.
        .task {
            if canOrder { dismiss() }
        }
        // Tự đóng khi khách đã đủ điều kiện đặt hàng, không bắt họ tự bấm "Hủy" — bấm Hủy sau khi
        // vừa đăng nhập xong đọc như huỷ luôn việc đăng nhập.
        //
        // Gộp HAI điều kiện vào MỘT `Bool` là có chủ đích: khách mới toanh đi qua hai chặng
        // (đăng nhập → nhập mã xác minh) trong CÙNG một sheet. Nếu đóng ngay khi `isSignedIn` bật
        // lên thì sheet biến mất giữa chừng và khách rơi về màn cũ với dòng chữ mới "Xác minh
        // email" — tức bị đá ra rồi phải bấm vào lại, đúng cái vòng bản vá này sinh ra để cắt.
        .onChange(of: canOrder) { _, ready in
            if ready { dismiss() }
        }
    }
}
