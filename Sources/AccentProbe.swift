import SwiftUI
import UIKit

/// THROWAWAY (branch claude/accent-probe, never main): what the accent colour resolves to.
/// `-fog6shot accent|accent-sheet|accent-alert`; `-accentWindowTint` sets every window's tintColor
/// to the asset colour on appear; `-accentRootTint` puts `.tint(candidate)` on the harness root.
enum AccentProbe {
    static let args = ProcessInfo.processInfo.arguments
    static let windowTint = args.contains("-accentWindowTint")
    static let rootTint = args.contains("-accentRootTint")
    /// Skip `Fog6.seed()` (runs in `App.init`, before UIApplication adopts the accent).
    static let noSeed = args.contains("-accentNoSeed")
    /// Real app path (RootView): info lines + base swatches on top.
    static let rootInfo = args.contains("-accentProbeInfo")
    static let light = UITraitCollection(userInterfaceStyle: .light)
    static let dark = UITraitCollection(userInterfaceStyle: .dark)

    /// The fix candidate: AccentColor.colorset values as a hex token.
    static let candidate = Color(uiColor: UIColor {
        $0.userInterfaceStyle == .dark
            ? UIColor(red: 0x6A / 255.0, green: 0xA9 / 255.0, blue: 1, alpha: 1)
            : UIColor(red: 0, green: 0x56 / 255.0, blue: 0xB3 / 255.0, alpha: 1)
    })

    static func byte(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }

    static func hex(_ c: UIColor?) -> String {
        guard let c else { return "nil" }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard c.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "n/a" }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b)) + (a < 1 ? String(format: "@%.2f", a) : "")
    }

    static func pair(_ c: UIColor?) -> String {
        guard let c else { return "nil" }
        return "L " + hex(c.resolvedColor(with: light)) + " D " + hex(c.resolvedColor(with: dark))
    }

    static func hex(_ r: Color.Resolved) -> String {
        String(format: "#%02X%02X%02X", byte(CGFloat(r.red)), byte(CGFloat(r.green)), byte(CGFloat(r.blue)))
    }

    static func pair(_ c: Color, _ env: EnvironmentValues) -> String {
        var l = env
        l.colorScheme = .light
        var d = env
        d.colorScheme = .dark
        return "L " + hex(c.resolve(in: l)) + " D " + hex(c.resolve(in: d))
    }

    @MainActor static var windows: [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    }

    @MainActor static func applyWindowTint() {
        guard windowTint, let c = UIColor(named: "AccentColor") else { return }
        for w in windows { w.tintColor = c }
    }

    @MainActor static func info(_ env: EnvironmentValues, _ scheme: ColorScheme) -> [String] {
        let plist = Bundle.main.object(forInfoDictionaryKey: "NSAccentColorName") as? String ?? "nil"
        let w = windows.first
        return [
            "os \(UIDevice.current.systemVersion) plist \(plist) windows \(windows.count) scheme \(scheme == .dark ? "dark" : "light") wflag \(windowTint) rflag \(rootTint)",
            "assetUIColor \(pair(UIColor(named: "AccentColor")))",
            "windowTint \(pair(w?.tintColor))",
            "rootViewTint \(pair(w?.rootViewController?.view.tintColor))",
            "detachedUIView \(pair(UIView().tintColor))",
            "UIColor.tintColor \(pair(UIColor.tintColor))",
            "systemBlue \(pair(UIColor.systemBlue)) link \(pair(UIColor.link))",
            "Color.accentColor \(pair(Color.accentColor, env))",
            "UIColor(accentColor) \(pair(UIColor(Color.accentColor)))",
            "Color(AccentColor) \(pair(Color("AccentColor"), env))",
            "Theme.accentText \(pair(Theme.accentText, env))",
            "desc \(Color.accentColor.resolve(in: env))",
        ]
    }
}

/// Harness root hooks for the probe flags (no-ops without them).
struct AccentProbeHooks: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if AccentProbe.rootTint {
            content.tint(AccentProbe.candidate).onAppear { AccentProbe.applyWindowTint() }
        } else {
            content.onAppear { AccentProbe.applyWindowTint() }
        }
    }
}

/// Info lines + swatch rows: base, `.tint(candidate)`, `.accentColor(candidate)`.
struct AccentProbeView: View {
    var showInfo = true
    var compact = false
    @Environment(\.self) private var env
    @Environment(\.colorScheme) private var scheme
    @State private var lines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showInfo {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(verbatim: line)
                            .font(.system(size: 9, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .accessibilityIdentifier("probe-\(i)")
                    }
                }
            }
            AccentSwatches(tag: showInfo ? "base" : "sheet")
            if showInfo, !compact {
                AccentSwatches(tag: "tint").tint(AccentProbe.candidate)
                AccentSwatches(tag: "accentMod").accentColor(AccentProbe.candidate)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            lines = AccentProbe.info(env, scheme)
        }
    }
}

private struct AccentSwatches: View {
    let tag: String

    private func swatch<S: ShapeStyle>(_ style: S, _ id: String) -> some View {
        Rectangle().fill(style)
            .frame(width: 34, height: 24)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: id))
            .accessibilityIdentifier("sw-\(tag)-\(id)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: tag).font(.caption2.bold())
            HStack(spacing: 6) {
                swatch(Color.accentColor, "fillAccent")
                swatch(.tint, "fillTint")
                swatch(Color("AccentColor"), "fillNamed")
                swatch(Theme.accentFill, "fillToken")
                Text(verbatim: "Aa").font(.title2.bold()).foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("sw-\(tag)-textAccent")
                Text(verbatim: "Aa").font(.title2.bold()).foregroundStyle(.tint)
                    .accessibilityIdentifier("sw-\(tag)-textTint")
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.tint)
                    .accessibilityIdentifier("sw-\(tag)-symbolTint")
            }
            HStack(spacing: 12) {
                Button(action: {}) { Text(verbatim: "Button").font(.title3.bold()) }
                    .accessibilityIdentifier("sw-\(tag)-button")
                Link(destination: URL(string: "https://example.com")!) { Text(verbatim: "Link").font(.title3.bold()) }
                    .accessibilityIdentifier("sw-\(tag)-link")
                Toggle(isOn: .constant(true)) { Text(verbatim: "t") }
                    .labelsHidden()
                    .accessibilityIdentifier("sw-\(tag)-toggle")
                ProgressView()
                    .accessibilityIdentifier("sw-\(tag)-spinner")
                Button(action: {}) { Text(verbatim: "Solid") }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("sw-\(tag)-prominent")
            }
        }
    }
}
