import Foundation

/// Ngôn ngữ UI đang chạy — thay cho `L` (song ngữ Anh–Việt tự chế, đã bỏ khi chuyển sang
/// String Catalog 8 ngôn ngữ ở bản 2.34). Chuỗi hiển thị nay đi qua `String(localized:)` /
/// literal trong `Text(...)`; file này chỉ còn lo phần KHÔNG nằm trong catalog: chọn giọng đọc.
enum AppLanguage {
    /// "en" / "vi" / "fr" / "de" / "cs" / "sk" / "es" / "nl" — ngôn ngữ bundle ĐÃ resolve
    /// (khác `Locale.preferredLanguages`: nếu máy đặt thứ tiếng app không có, đây trả về "en").
    static var code: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    /// Mã giọng cho `AVSpeechSynthesisVoice` khớp ngôn ngữ app, ưu tiên biến thể vùng của máy
    /// (Québec → fr-CA, Bỉ → nl-BE, châu Mỹ → es-MX). Máy thiếu giọng thì
    /// `AVSpeechSynthesisVoice(language:)` trả nil và utterance tự rơi về giọng mặc định.
    static var speechVoice: String {
        let region = Locale.current.region?.identifier
        switch code {
        case "vi": return "vi-VN"
        case "fr": return region == "CA" ? "fr-CA" : "fr-FR"
        case "de": return "de-DE"
        case "cs": return "cs-CZ"
        case "sk": return "sk-SK"
        case "es": return ["MX", "US", "AR", "CO", "CL", "PE", "EC", "GT", "DO", "UY", "PY", "BO", "CR", "PA", "SV", "HN", "NI", "VE"].contains(region ?? "")
            ? "es-MX" : "es-ES"
        case "nl": return region == "BE" ? "nl-BE" : "nl-NL"
        default: return "en-US"
        }
    }
}
