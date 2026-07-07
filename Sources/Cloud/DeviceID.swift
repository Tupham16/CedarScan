import Foundation
import UIKit

/// Mã định danh thiết bị (ổn định trên cùng máy, cùng nhà cung cấp) — dùng để giới hạn khuyến mãi.
/// identifierForVendor giữ nguyên khi cài lại app cùng vendor; reset nếu gỡ hẳn — đủ dùng cho chống lạm dụng nhẹ.
enum DeviceID {
    static let current: String = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
}
