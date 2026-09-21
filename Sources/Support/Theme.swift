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

/// Capsule badge, e.g. `FogBadge("1 new", .soft)`. `compact` = the small one next to a scan name.
struct FogBadge: View {
    let text: String
    let kind: Theme.Badge
    let compact: Bool

    init(_ text: String, _ kind: Theme.Badge, compact: Bool = false) {
        self.text = text
        self.kind = kind
        self.compact = compact
    }

    var body: some View {
        Text(text)
            .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(kind.fg)
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 2 : 4)
            .background(Capsule().fill(kind.bg))
            .fixedSize()
    }
}

/// Solid button (`accentFill`, white label). The label sets its own font, frame and padding.
struct FogPrimary: ButtonStyle {
    var radius: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        FogButtonBody(configuration: configuration, kind: .primary, radius: radius)
    }
}

/// Light button (`accentTint`, `accentText` label).
struct FogTint: ButtonStyle {
    var radius: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        FogButtonBody(configuration: configuration, kind: .tint, radius: radius)
    }
}

/// Outline button (`ghostBorder`, primary label).
struct FogGhost: ButtonStyle {
    var radius: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        FogButtonBody(configuration: configuration, kind: .ghost, radius: radius)
    }
}

private enum FogButtonKind {
    case primary, tint, ghost
}

/// A view, not the style itself, so it can read `isEnabled`: a disabled button is grey.
private struct FogButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: FogButtonKind
    let radius: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return configuration.label
            .foregroundStyle(foreground)
            .background(shape.fill(fill))
            .overlay {
                if kind == .ghost {
                    shape.strokeBorder(Theme.ghostBorder, lineWidth: 1)
                }
            }
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }

    private var foreground: Color {
        guard isEnabled else { return Theme.inactive }
        switch kind {
        case .primary: return .white
        case .tint: return Theme.accentText
        case .ghost: return .primary
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: return isEnabled ? Theme.accentFill : Theme.Badge.neutral.bg
        case .tint: return isEnabled ? Theme.accentTint : Theme.Badge.neutral.bg
        case .ghost: return .clear
        }
    }
}

/// Card behind a list row: radius 16 + hairline border.
private struct FogCardBackground: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return shape
            .fill(Theme.card)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }
}

extension View {
    /// Fog screen background; only the background ignores the safe area.
    func fogScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
    }

    /// Plain-list row drawn as a card (16pt screen margin, 12pt gap between cards).
    /// `trailing` 20 suits Home's 44pt trash button; 32 = 16pt inside the card.
    func fogCardRow(trailing: CGFloat = 20) -> some View {
        self
            .listRowBackground(FogCardBackground())
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 17, leading: 32, bottom: 18, trailing: trailing))
    }

    /// Dark glass behind controls over the camera (scan screen), dark in light mode too:
    /// blur + black 30% + 1pt white 16% border. Measured on simulator renders: ≈ the mockup's
    /// tone over a room, and white text stays ≥ 7:1 over a white wall (thin material alone: 4.4:1).
    func fogGlass<S: InsettableShape>(_ shape: S) -> some View {
        background {
            shape.fill(.thinMaterial)
                .overlay(shape.fill(Color.black.opacity(0.3)))
                .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                .environment(\.colorScheme, .dark)
        }
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
