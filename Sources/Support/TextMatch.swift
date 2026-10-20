import Foundation

/// So khớp chữ theo kiểu người Việt gõ: bỏ hoa/thường, bỏ dấu, bỏ khoảng trắng thừa hai đầu.
///
/// Dùng chung cho: ô tìm kiếm ở màn hình chính, ô tìm kiếm tab Đơn hàng, và việc so tên căn nhà ở
/// `ScanAddressView` (nơi nó ra đời). Gom về một chỗ vì cả ba PHẢI cư xử giống nhau — người dùng
/// gõ "duong le loi" ở màn này ra kết quả mà màn kia không ra là lỗi khó tin nhất để gỡ.
///
/// 🔴 ĐỔI `đ`/`Đ` BẰNG TAY TRƯỚC: `.diacriticInsensitive` KHÔNG fold được chúng — U+0111 là một
/// chữ cái CƠ SỞ riêng trong Unicode, không có canonical decomposition thành d + dấu, nên bước bỏ
/// dấu của Foundation không chạm tới (khác ă/â/ê/ô/ơ/ư đều fold được). Bỏ sót chỗ này là hỏng đúng
/// chữ hay gặp nhất trong địa chỉ Việt Nam: "Đường Lê Lợi" sẽ KHÔNG khớp "Duong Le Loi", tức lỗi
/// tách-nhầm/tìm-không-thấy vẫn sống nguyên ở đúng nhóm địa chỉ phổ biến nhất.
enum TextMatch {
    static func key(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "Đ", with: "D")
            .folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "vi_VN"))
            .lowercased()
    }

    /// `haystack` có chứa `needle` không (đã chuẩn hoá cả hai). Chuỗi tìm rỗng → luôn đúng, để
    /// người gọi không phải tự viết `guard` ở mọi chỗ.
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        let n = key(needle)
        guard !n.isEmpty else { return true }
        return key(haystack).contains(n)
    }
}

/// N10 (2.79): text the server keeps to `limit` UTF-16 units (`str(…, n)` in order-webapp's
/// `app-api.ts`) — the order note, floor naming, property name, coupon, a revision request. The
/// longest prefix of WHOLE characters within the limit, never half an emoji (the server's
/// `cutText` rule). Shorter text comes back as it is.
enum TextLimit {
    static func cut(_ text: String, _ limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        var kept = ""
        var used = 0
        for character in text {
            let size = character.utf16.count
            if used + size > limit { break }
            kept.append(character)
            used += size
        }
        return kept
    }
}
