import Foundation

/// Song ngữ đơn giản: máy đặt tiếng Việt → tiếng Việt, còn lại → tiếng Anh.
/// Dùng: L.t("New scan", "Quét mới")
enum L {
    static let isVietnamese: Bool =
        Locale.preferredLanguages.first?.lowercased().hasPrefix("vi") ?? false

    static func t(_ english: String, _ vietnamese: String) -> String {
        isVietnamese ? vietnamese : english
    }
}
