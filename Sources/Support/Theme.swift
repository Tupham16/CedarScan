import SwiftUI
import UIKit

/// "Apple Fog" color tokens, light / dark.
enum Theme {
    static let bg = hex(0xF4F5F7, 0x0E1116)
    static let card = hex(0xFFFFFF, 0x171B22)
    /// 1px card border (used instead of drop shadows).
    static let hairline = dyn(UIColor(white: 0, alpha: 0.06), UIColor(white: 1, alpha: 0.08))
    /// Outline button border.
    static let ghostBorder = dyn(UIColor(white: 0, alpha: 0.10), UIColor(white: 1, alpha: 0.14))

    /// Solid buttons, Scan disc.
    static let accentFill = hex(0x0056B3, 0x2473DB)
    /// Selected tab, links, tinted icons. Values live in AccentColor.colorset.
    static let accentText = Color.accentColor
    /// Secondary button background (label = `accentText`).
    static let accentTint = hex(0xE8F0FA, 0x14294A)

    /// Unselected tab items, trash icon.
    static let inactive = hex(0x8E9AAF, 0x6B778C)
    static let scanLabel = hex(0x334155, 0xCBD5E1)
    static let scanShadow = dyn(rgb(0x0056B3, alpha: 0.24), UIColor(white: 0, alpha: 0.5))

    static let thumbBg = hex(0xF1F3F5, 0x1D222B)
    static let thumbLine = hex(0x4A5568, 0xB8C2D1)

    /// Badge palette: background + text.
    struct Badge {
        let bg: Color
        let fg: Color

        /// New, Processing, selected chip.
        static let soft = Badge(bg: hex(0xE0F2FE, 0x0F2E45), fg: hex(0x0369A1, 0x7CC4F5))
        /// Delivered, Paid.
        static let ok = Badge(bg: hex(0xDCFCE7, 0x12301F), fg: hex(0x15803D, 0x6EDC9A))
        /// Ordered, Order #.
        static let neutral = Badge(bg: hex(0xE9EDF2, 0x242B36), fg: hex(0x475569, 0xB6C0CF))
        /// On hold.
        static let warn = Badge(bg: hex(0xFEF3C7, 0x3A2A0C), fg: hex(0xB45309, 0xF5C76B))
        /// Refunded.
        static let danger = Badge(bg: hex(0xFEE2E2, 0x3B1517), fg: hex(0xB91C1C, 0xF19999))
    }
}

private func rgb(_ value: UInt32, alpha: CGFloat = 1) -> UIColor {
    let r = CGFloat((value >> 16) & 0xFF) / 255
    let g = CGFloat((value >> 8) & 0xFF) / 255
    let b = CGFloat(value & 0xFF) / 255
    return UIColor(red: r, green: g, blue: b, alpha: alpha)
}

private func dyn(_ light: UIColor, _ dark: UIColor) -> Color {
    Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
}

private func hex(_ light: UInt32, _ dark: UInt32) -> Color {
    dyn(rgb(light), rgb(dark))
}
