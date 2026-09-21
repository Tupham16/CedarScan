import SwiftUI
import UIKit
import XCTest
@testable import CedarScan

/// THROWAWAY (branch claude/textcut-audit, never main): find wrapped texts that iOS 26 measures
/// shorter than it draws (last line cut with "…"). Runs inside the app process (hosted unit test),
/// once per app language (`xcodebuild -testLanguage`).
///
/// Detector, per (text, font, text size, width):
///  - SwiftUI: render `Text` at its own measured size (fixedSize vertical, frame width W) twice,
///    with truncation mode .tail and .head. Not truncated => both images identical.
///  - UILabel: frame = sizeThatFits(W) height; render with .byTruncatingTail and .byClipping.
/// Positive control: the German scan note at 326pt caption (cut on 21/09).
@MainActor
final class TextCutSweep: XCTestCase {
    struct Style {
        let name: String
        let style: UIFont.TextStyle
        let weight: UIFont.Weight?
        var swiftUI: Font {
            let f = Font.system(Self.fontTextStyle(style))
            return weight == .semibold ? f.weight(.semibold) : f
        }

        static func fontTextStyle(_ s: UIFont.TextStyle) -> Font.TextStyle {
            switch s {
            case .body: return .body
            case .callout: return .callout
            case .subheadline: return .subheadline
            case .footnote: return .footnote
            case .caption1: return .caption
            case .headline: return .headline
            default: return .body
            }
        }

        func uiFont(_ c: UIContentSizeCategory) -> UIFont {
            let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: c))
            guard let weight else { return base }
            return UIFont.systemFont(ofSize: base.pointSize, weight: weight)
        }
    }

    static let body = Style(name: "body", style: .body, weight: nil)
    static let sub = Style(name: "subheadline", style: .subheadline, weight: nil)
    static let subSemi = Style(name: "subheadline-semibold", style: .subheadline, weight: .semibold)
    static let foot = Style(name: "footnote", style: .footnote, weight: nil)
    static let cap = Style(name: "caption", style: .caption1, weight: nil)
    static let head = Style(name: "headline", style: .headline, weight: nil)

    struct Size {
        let name: String
        let category: UIContentSizeCategory
        let dts: DynamicTypeSize
    }

    static let sizes = [
        Size(name: "default", category: .large, dts: .large),
        Size(name: "xxxLarge", category: .extraExtraExtraLarge, dts: .xxxLarge),
    ]

    var env: [String: String] { ProcessInfo.processInfo.environment }
    var lang: String { Bundle.main.preferredLocalizations.first ?? "en" }
    var lines: [String] = []
    var checks = 0

    func testSweep() throws {
        let t0 = Date()
        let step = CGFloat(Double(env["TEXTCUT_STEP"] ?? "1") ?? 1)
        let minW = CGFloat(Double(env["TEXTCUT_MIN"] ?? "250") ?? 250)
        let maxW = CGFloat(Double(env["TEXTCUT_MAX"] ?? "410") ?? 410)
        let widths = Array(stride(from: minW, through: maxW, by: step))
        let budget = Double(env["TEXTCUT_BUDGET"] ?? "3000") ?? 3000
        log("TEXTCUT START lang=\(lang) widths=\(minW)...\(maxW) step \(step)")

        // Positive control (German only: the sentence exists only in German on branch 2.46).
        if lang == "de" {
            let note = "Glas und Fenster bleiben immer rot — einfach überspringen. Treppen und mehrere Etagen sind kein Problem."
            for w in [CGFloat(326), 325, 327] {
                let s = cutSwiftUI(note, Self.cap, Self.sizes[0], w)
                let u = cutUILabel(note, Self.cap, Self.sizes[0], w)
                log("TEXTCUT CONTROL w=\(w) swiftui=\(s) uilabel=\(u)")
            }
        }

        // Legal texts: English in every language except French (the app shows EN), French in fr.
        let isFR = lang == "fr"
        let legal: [(String, [(String, String)])] = isFR
            ? [("privacy", LegalDoc.privacySectionsFR), ("terms", LegalDoc.termsSectionsFR), ("eula", LegalDoc.eulaSectionsFR)]
            : [("privacy", LegalDoc.privacySections), ("terms", LegalDoc.termsSections), ("eula", LegalDoc.eulaSections)]
        var items: [(String, String, [Style])] = []
        if env["TEXTCUT_SKIP_LEGAL"] == nil {
            for (doc, secs) in legal {
                for (h, t) in secs {
                    items.append(("legal-\(doc)", t, [Self.sub]))
                    items.append(("legal-\(doc)-heading", h, [Self.head]))
                }
            }
        }
        // Every Localizable string of this language (placeholders filled with sample values).
        let minLen = Int(env["TEXTCUT_MINLEN"] ?? "16") ?? 16
        let styles = [Self.body, Self.sub, Self.subSemi, Self.foot, Self.cap]
        for s in localizedStrings() where s.count >= minLen {
            items.append(("string", s, styles))
        }
        log("TEXTCUT items=\(items.count)")

        var hits = 0
        outer: for (i, item) in items.enumerated() {
            for style in item.2 {
                for size in Self.sizes {
                    // Skip widths where the text is one line (nothing to cut).
                    let oneLine = oneLineWidth(item.1, style, size)
                    for w in widths where w < oneLine {
                        checks += 1
                        let s = cutSwiftUI(item.1, style, size, w)
                        let u = cutUILabel(item.1, style, size, w)
                        if s || u {
                            hits += 1
                            let text = item.1.replacingOccurrences(of: "\n", with: "\\n")
                            log("TEXTCUT HIT|\(lang)|\(item.0)|\(style.name)|\(size.name)|\(Int(w))|swiftui=\(s)|uilabel=\(u)|\(text)")
                        }
                    }
                }
            }
            if i % 20 == 0 {
                log("TEXTCUT progress \(i)/\(items.count) checks=\(checks) hits=\(hits) t=\(Int(Date().timeIntervalSince(t0)))s")
            }
            if Date().timeIntervalSince(t0) > budget {
                log("TEXTCUT BUDGET STOP at item \(i)/\(items.count)")
                break outer
            }
        }
        log("TEXTCUT END lang=\(lang) checks=\(checks) hits=\(hits) t=\(Int(Date().timeIntervalSince(t0)))s")
        let a = XCTAttachment(string: lines.joined(separator: "\n"))
        a.name = "textcut-\(lang)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func log(_ s: String) {
        print(s)
        lines.append(s)
    }

    private func oneLineWidth(_ text: String, _ style: Style, _ size: Size) -> CGFloat {
        let l = UILabel()
        l.numberOfLines = 1
        l.font = style.uiFont(size.category)
        l.text = text
        return ceil(l.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).width) + 2
    }

    private func localizedStrings() -> [String] {
        guard let path = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: lang),
              let dict = NSDictionary(contentsOfFile: path) as? [String: String] else {
            log("TEXTCUT no Localizable.strings for \(lang)")
            return []
        }
        let re = try! NSRegularExpression(pattern: "%(\\d+\\$)?(lld|ld|d|@|f|\\.\\d+f)")
        return dict.values.sorted().map { v in
            let r = NSRange(v.startIndex..., in: v)
            var out = v
            for m in re.matches(in: v, range: r).reversed() {
                let spec = (v as NSString).substring(with: m.range)
                let rep = spec.hasSuffix("@") ? "Maple Street 12" : "3"
                out = (out as NSString).replacingCharacters(in: m.range, with: rep)
            }
            return out.replacingOccurrences(of: "%%", with: "%")
        }
    }

    // MARK: detectors

    private func cutSwiftUI(_ text: String, _ style: Style, _ size: Size, _ w: CGFloat) -> Bool {
        func render(_ mode: Text.TruncationMode) -> Data? {
            let v = Text(verbatim: text)
                .font(style.swiftUI)
                .truncationMode(mode)
                .frame(width: w, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.dynamicTypeSize, size.dts)
            let r = ImageRenderer(content: v)
            r.scale = 3
            guard let cg = r.cgImage, let d = cg.dataProvider?.data else { return nil }
            return d as Data
        }
        return render(.tail) != render(.head)
    }

    private func cutUILabel(_ text: String, _ style: Style, _ size: Size, _ w: CGFloat) -> Bool {
        let probe = UILabel()
        probe.numberOfLines = 0
        probe.font = style.uiFont(size.category)
        probe.text = text
        let h = ceil(probe.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height)
        func render(_ mode: NSLineBreakMode) -> Data? {
            let l = UILabel()
            l.numberOfLines = 0
            l.font = style.uiFont(size.category)
            l.text = text
            l.lineBreakMode = mode
            l.frame = CGRect(x: 0, y: 0, width: w, height: h)
            let f = UIGraphicsImageRendererFormat()
            f.scale = 3
            let img = UIGraphicsImageRenderer(size: l.bounds.size, format: f).image { ctx in
                l.layer.render(in: ctx.cgContext)
            }
            guard let d = img.cgImage?.dataProvider?.data else { return nil }
            return d as Data
        }
        return render(.byTruncatingTail) != render(.byClipping)
    }
}
