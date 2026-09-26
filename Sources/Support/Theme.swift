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

    /// Home property card: 5pt left edge (orders take their badge's `edge`, 2.52).
    static let homeEdge = hex(0x6E9FD8, 0x4F86C9)

    static let thumbBg = hex(0xF1F3F5, 0x1D222B)
    static let thumbLine = hex(0x4A5568, 0xB8C2D1)

    /// Badge palette: background + text, and `edge` = the 5pt left edge of an order card in that
    /// state (2.52, owner-approved mockup 48).
    struct Badge {
        let bg: Color
        let fg: Color
        let edge: Color

        /// New, Processing, selected chip.
        static let soft = Badge(bg: hex(0xE0F2FE, 0x0F2E45), fg: hex(0x0369A1, 0x7CC4F5), edge: hex(0x4FA8E0, 0x3E92CF))
        /// Ready (delivered), Paid.
        static let ok = Badge(bg: hex(0xDCFCE7, 0x12301F), fg: hex(0x15803D, 0x6EDC9A), edge: hex(0x43B96F, 0x3AA866))
        /// Ordered, Order #.
        static let neutral = Badge(bg: hex(0xE9EDF2, 0x242B36), fg: hex(0x475569, 0xB6C0CF), edge: hex(0xB8C2CF, 0x4A5467))
        /// On hold.
        static let warn = Badge(bg: hex(0xFEF3C7, 0x3A2A0C), fg: hex(0xB45309, 0xF5C76B), edge: hex(0xF0B429, 0xD99E2B))
        /// Refunded.
        static let danger = Badge(bg: hex(0xFEE2E2, 0x3B1517), fg: hex(0xB91C1C, 0xF19999), edge: hex(0xE5484D, 0xD0464B))
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
/// `busy`: disabled while it works (spinner label) = the solid colour at 62%, not grey.
struct FogPrimary: ButtonStyle {
    var radius: CGFloat = 14
    var busy = false

    func makeBody(configuration: Configuration) -> some View {
        FogButtonBody(configuration: configuration, kind: .primary, radius: radius, busy: busy)
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
    var busy = false
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
            .opacity(busy ? 0.62 : configuration.isPressed ? 0.7 : 1)
    }

    /// Grey only when disabled and not busy.
    private var colored: Bool { isEnabled || busy }

    private var foreground: Color {
        guard colored else { return Theme.inactive }
        switch kind {
        case .primary: return .white
        case .tint: return Theme.accentText
        case .ghost: return .primary
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: return colored ? Theme.accentFill : Theme.Badge.neutral.bg
        case .tint: return colored ? Theme.accentTint : Theme.Badge.neutral.bg
        case .ghost: return .clear
        }
    }
}

/// Card behind a list row: radius 16 + hairline border; `edge` = a 5pt coloured left edge
/// following the corner curve (Home / Orders cards, 2.52).
private struct FogCardBackground: View {
    var edge: Color?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return shape
            .fill(Theme.card)
            .overlay(alignment: .leading) {
                if let edge {
                    Rectangle().fill(edge).frame(width: 5)
                }
            }
            .clipShape(shape)
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
    func fogCardRow(trailing: CGFloat = 20, edge: Color? = nil) -> some View {
        self
            .listRowBackground(FogCardBackground(edge: edge))
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

/// Wrapped text a customer must read whole (instructions, notes). iOS 26 can measure a SwiftUI
/// `Text` or `UILabel` in fewer lines than it draws and cut the last line (German, trap #44).
/// Here one TextKit layout measures and draws, at the full proposed width. VoiceOver reads it
/// as a plain `Text`. Primary colour; font = `style` at the environment's Dynamic Type size.
struct WrappedText: View {
    let text: String
    let style: UIFont.TextStyle
    /// `.center` for a centred screen (the placed screen); line breaks do not depend on it.
    let alignment: NSTextAlignment

    init(_ text: String, style: UIFont.TextStyle = .body, alignment: NSTextAlignment = .natural) {
        self.text = text
        self.style = style
        self.alignment = alignment
    }

    var body: some View {
        WrappedTextView(text: text, style: style, alignment: alignment)
            .accessibilityRepresentation { Text(text) }
    }
}

/// UIKit side of `WrappedText` (internal so a test can measure it the same way).
struct WrappedTextView: UIViewRepresentable {
    let text: String
    let style: UIFont.TextStyle
    var alignment: NSTextAlignment = .natural

    func makeUIView(context: Context) -> UITextView {
        Self.makeTextView()
    }

    func updateUIView(_ view: UITextView, context: Context) {
        Self.configure(view, text: text, font: Self.font(style, context.environment), alignment: alignment)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        Self.configure(view, text: text, font: Self.font(style, context.environment), alignment: alignment)
        return Self.fittingSize(view, width: proposal.width, scale: context.environment.displayScale)
    }

    /// TextKit 1: `sizeThatFits` and drawing use the same NSLayoutManager, so the measured
    /// height is the drawn height. Top-aligned, no insets, not interactive.
    static func makeTextView() -> UITextView {
        let view = UITextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = false
        view.isScrollEnabled = false
        // Leave the status-bar tap to the screen's own scroll view.
        view.scrollsToTop = false
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.backgroundColor = .clear
        // A scroll view near the screen edge would otherwise add safe-area insets to the text.
        view.contentInsetAdjustmentBehavior = .never
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.widthTracksTextView = true
        view.textContainer.heightTracksTextView = false
        return view
    }

    static func font(_ style: UIFont.TextStyle, _ environment: EnvironmentValues) -> UIFont {
        var traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(environment.dynamicTypeSize))
        if environment.legibilityWeight == .bold {
            traits = traits.modifyingTraits { $0.legibilityWeight = .bold }
        }
        return UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
    }

    static func configure(_ view: UITextView, text: String, font: UIFont, alignment: NSTextAlignment = .natural) {
        guard view.attributedText?.string != text || view.font != font || view.textAlignment != alignment else { return }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.label,
        ]
        // Only when asked: the default (.natural) keeps the exact attributes the German sweep measured.
        if alignment != .natural {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            attributes[.paragraphStyle] = paragraph
        }
        view.attributedText = NSAttributedString(string: text, attributes: attributes)
        if view.textAlignment != alignment { view.textAlignment = alignment }
    }

    /// Wrapped: the full proposed width, measured at that width floored to the pixel grid (the
    /// frame SwiftUI places is pixel-rounded and never narrower than that). One line: natural + 1.
    static func fittingSize(_ view: UITextView, width: CGFloat?, scale: CGFloat = 3) -> CGSize {
        let unbounded: CGFloat = 10_000_000
        let line = view.sizeThatFits(CGSize(width: unbounded, height: unbounded))
        let lineWidth = ceil(line.width) + 1
        guard let width, width < unbounded, lineWidth > width else {
            return CGSize(width: lineWidth, height: ceil(line.height))
        }
        let pixel = max(scale, 1)
        let measured = max(floor(width * pixel) / pixel, 1)
        let wrapped = view.sizeThatFits(CGSize(width: measured, height: unbounded))
        return CGSize(width: width, height: ceil(wrapped.height))
    }
}

/// Home / Orders card body (2.52, mockup 48): the first subview at the top, the last one at the
/// bottom, at least `minHeight` tall (content grows past it). A Layout, ✗ a Spacer in a VStack
/// under `.frame(minHeight:)`: a List row sizes its content with no height proposal, so a Spacer
/// would not stretch and the bottom line would float up under the title. Two subviews.
struct FogCardStack: Layout {
    /// Content height; the visible card adds the row insets (17 + 18) minus the 6 + 6 margins.
    var minHeight: CGFloat = 95
    var gap: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        let content = sizes.reduce(0) { $0 + $1.height } + gap * CGFloat(max(subviews.count - 1, 0))
        let width = proposal.width ?? sizes.reduce(0) { max($0, $1.width) }
        return CGSize(width: width, height: max(minHeight, content))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let top = subviews.first, let bottom = subviews.last else { return }
        let proposed = ProposedViewSize(width: bounds.width, height: nil)
        top.place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading, proposal: proposed)
        if subviews.count > 1 {
            bottom.place(at: CGPoint(x: bounds.minX, y: bounds.maxY), anchor: .bottomLeading, proposal: proposed)
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
