import SwiftUI
import UIKit
import XCTest
@testable import CedarScan

/// THROWAWAY (branch claude/fog6-shots, never main): does `WrappedText` ever draw below the
/// height it reports? (iOS 26 cuts wrapped German SwiftUI Text, trap #44.) Hosted in the app,
/// one run per app language (`xcodebuild -testLanguage`).
///
/// Per (text, style, size, width): the production `WrappedTextView` code measures the text, the
/// text view is laid out 40pt TALLER than reported and rendered; ink below the reported height,
/// or a TextKit used rect taller than it, is a hit (the app would clip that line).
/// Controls: plain SwiftUI Text is still cut (the iOS bug is present in this run), and the
/// detector sees a 10pt-short height.
@MainActor
final class WrappedTextSweep: XCTestCase {
    static let styles: [(String, UIFont.TextStyle)] = [
        ("body", .body), ("subheadline", .subheadline), ("footnote", .footnote), ("caption", .caption1),
    ]
    static let sizes: [(String, DynamicTypeSize)] = [("default", .large), ("xxxLarge", .xxxLarge)]

    var env: [String: String] { ProcessInfo.processInfo.environment }
    var lang: String { Bundle.main.preferredLocalizations.first ?? "en" }
    var lines: [String] = []
    /// One text view for every check (a new one per check grew memory until the runner died).
    lazy var probe = WrappedTextView.makeTextView()

    func testSweep() throws {
        let t0 = Date()
        let minW = CGFloat(Double(env["SWEEP_MIN"] ?? "250") ?? 250)
        let maxW = CGFloat(Double(env["SWEEP_MAX"] ?? "410") ?? 410)
        let budget = Double(env["SWEEP_BUDGET"] ?? "7000") ?? 7000
        let widths = Array(stride(from: minW, through: maxW, by: 1))
        let shard = (env["SWEEP_SHARD"] ?? "0/1").split(separator: "/").compactMap { Int($0) }
        let (part, parts) = shard.count == 2 ? (shard[0], max(shard[1], 1)) : (0, 1)
        log("WRAP START lang=\(lang) widths=\(minW)...\(maxW) shard=\(part)/\(parts)")

        if lang == "de", part == 0 {
            let note = "Glas und Fenster bleiben immer rot — einfach überspringen. Treppen und mehrere Etagen sind kein Problem."
            log("WRAP CONTROL swiftui-text-cut-at-326=\(swiftUICut(note, .caption, 326))")
            log("WRAP CONTROL wrapped-hit-at-326=\(wrappedHit(note, .caption1, .large, 326, short: 0) != nil)")
            let tip = "Halten Sie das iPhone auf Brusthöhe, leicht nach unten geneigt."
            for w in [CGFloat(302), 314] {
                log("WRAP CONTROL guide-tip xxxLarge w=\(Int(w)) swiftui-cut=\(swiftUICut(tip, .subheadline, w, .xxxLarge)) wrapped-hit=\(wrappedHit(tip, .subheadline, .xxxLarge, w, short: 0) != nil)")
            }
        }
        log("WRAP CONTROL detector-10pt-short=\(wrappedHit("Point the camera at every wall, corner, door and window, then walk on.", .subheadline, .large, 200, short: 10) != nil)")

        var items = localizedStrings().filter { $0.count >= 16 }
        if env["SWEEP_SKIP_LEGAL"] == nil { items += legalTexts() }
        log("WRAP items=\(items.count)")
        var checks = 0
        var hits = 0
        outer: for (i, text) in items.enumerated() where i % parts == part {
            for (sname, style) in Self.styles {
                for (zname, size) in Self.sizes {
                    let one = oneLineWidth(text, style, size)
                    for w in widths where w < one {
                        checks += 1
                        let why: String? = autoreleasepool { wrappedHit(text, style, size, w, short: 0) }
                        if let why {
                            hits += 1
                            let t = text.replacingOccurrences(of: "\n", with: "\\n").prefix(100)
                            log("WRAP HIT|\(lang)|\(i)|\(sname)|\(zname)|\(Int(w))|\(why)|\(t)")
                        }
                    }
                }
            }
            if i % 25 == 0 {
                log("WRAP progress \(i)/\(items.count) checks=\(checks) hits=\(hits) t=\(Int(Date().timeIntervalSince(t0)))s")
            }
            if Date().timeIntervalSince(t0) > budget {
                log("WRAP BUDGET STOP at \(i)/\(items.count)")
                break outer
            }
        }
        log("WRAP END lang=\(lang) checks=\(checks) hits=\(hits) t=\(Int(Date().timeIntervalSince(t0)))s")
        let a = XCTAttachment(string: lines.joined(separator: "\n"))
        a.name = "wrap-\(lang)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func log(_ s: String) {
        print(s)
        lines.append(s)
    }

    private func environment(_ size: DynamicTypeSize) -> EnvironmentValues {
        var e = EnvironmentValues()
        e.dynamicTypeSize = size
        return e
    }

    private func oneLineWidth(_ text: String, _ style: UIFont.TextStyle, _ size: DynamicTypeSize) -> CGFloat {
        let view = probe
        WrappedTextView.configure(view, text: text, font: WrappedTextView.font(style, environment(size)))
        return WrappedTextView.fittingSize(view, width: nil).width + 1
    }

    /// nil = whole. Otherwise why it is cut: "ink" (pixels below the height) and/or "used" (TextKit).
    private func wrappedHit(_ text: String, _ style: UIFont.TextStyle, _ size: DynamicTypeSize, _ w: CGFloat, short: CGFloat) -> String? {
        let view = probe
        WrappedTextView.configure(view, text: text, font: WrappedTextView.font(style, environment(size)))
        let fit = WrappedTextView.fittingSize(view, width: w)
        let h = fit.height - short
        view.frame = CGRect(x: 0, y: 0, width: fit.width, height: h + 40)
        view.layoutIfNeeded()
        view.layoutManager.ensureLayout(for: view.textContainer)
        let used = view.layoutManager.usedRect(for: view.textContainer)
        let usedBottom = view.textContainerInset.top + used.maxY - view.contentOffset.y
        var why: [String] = []
        if usedBottom > h + 0.5 { why.append("used=\(Int(usedBottom))>\(Int(h))") }
        if inkBelow(view, height: h) { why.append("ink") }
        return why.isEmpty ? nil : why.joined(separator: ",")
    }

    private func inkBelow(_ view: UIView, height h: CGFloat) -> Bool {
        displayAll(view.layer)
        let scale: CGFloat = 2
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = false
        let img = UIGraphicsImageRenderer(size: view.bounds.size, format: fmt).image { ctx in
            view.layer.render(in: ctx.cgContext)
        }
        guard let cg = img.cgImage else { return false }
        let pw = cg.width, ph = cg.height
        var buf = [UInt8](repeating: 0, count: pw * ph * 4)
        let drew: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pw, height: ph))
            return true
        }
        guard drew else { return false }
        let first = min(ph, Int(ceil(h * scale)) + 1)
        for y in first..<ph {
            let row = y * pw * 4
            for x in 0..<pw where buf[row + x * 4 + 3] > 24 {
                return true
            }
        }
        return false
    }

    private func displayAll(_ layer: CALayer) {
        layer.setNeedsDisplay()
        layer.displayIfNeeded()
        layer.sublayers?.forEach { displayAll($0) }
    }

    /// The 22/09 audit detector: SwiftUI Text at its own size, tail vs head truncation differ = cut.
    private func swiftUICut(_ text: String, _ font: Font, _ w: CGFloat, _ size: DynamicTypeSize = .large) -> Bool {
        func render(_ mode: Text.TruncationMode) -> CGImage? {
            let v = Text(verbatim: text)
                .font(font)
                .truncationMode(mode)
                .frame(width: w, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.dynamicTypeSize, size)
            let r = ImageRenderer(content: v)
            r.scale = 3
            return r.cgImage
        }
        guard let t = render(.tail), let h = render(.head) else { return false }
        let dt = t.dataProvider?.data as Data?
        let dh = h.dataProvider?.data as Data?
        return !(t.width == h.width && t.height == h.height && dt == dh)
    }

    private func localizedStrings() -> [String] {
        guard let path = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: lang),
              let dict = NSDictionary(contentsOfFile: path) as? [String: String] else {
            log("WRAP no Localizable.strings for \(lang)")
            return []
        }
        let re = try! NSRegularExpression(pattern: "%(\\d+\\$)?(lld|ld|d|@|f|\\.\\d+f)")
        return dict.values.sorted().map { v in
            var out = v
            for m in re.matches(in: v, range: NSRange(v.startIndex..., in: v)).reversed() {
                let spec = (v as NSString).substring(with: m.range)
                out = (out as NSString).replacingCharacters(in: m.range, with: spec.hasSuffix("@") ? "Maple Street 12" : "3")
            }
            return out.replacingOccurrences(of: "%%", with: "%")
        }
    }

    private func legalTexts() -> [String] {
        let fr = lang == "fr"
        let docs = fr
            ? [LegalDoc.privacySectionsFR, LegalDoc.termsSectionsFR, LegalDoc.eulaSectionsFR]
            : [LegalDoc.privacySections, LegalDoc.termsSections, LegalDoc.eulaSections]
        return docs.flatMap { $0.map { $0.1 } }
    }
}
