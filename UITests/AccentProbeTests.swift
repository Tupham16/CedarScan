import UIKit
import XCTest

/// THROWAWAY (branch claude/accent-probe, never main): accent colour probe, light or dark per run.
/// Prints `PROBE <screen> <what> <value>` lines and attaches them + the screenshots.
final class AccentProbeTests: XCTestCase {
    private var n = 0
    private var out: [String] = []

    func testAccent() {
        continueAfterFailure = true
        run("accent", [])
        run("accent", ["-accentWindowTint"])
        run("accent-sheet", [])
        run("accent-alert", [])
        run("accent-alert", ["-accentRootTint"])
        run("accent-alert", ["-accentWindowTint"])
        run("learn", [])
        run("learn", ["-accentWindowTint"])
        run("learn", ["-accentRootTint"])
        run("order", [], end: true)
        run("order", ["-accentWindowTint"], end: true)
        let a = XCTAttachment(string: out.joined(separator: "\n"))
        a.name = "probe-results"
        a.lifetime = .keepAlways
        add(a)
    }

    private func run(_ screen: String, _ extra: [String], end: Bool = false) {
        let app = XCUIApplication()
        app.launchArguments = ["-fog6shot", screen, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        app.launch()
        sleep(5)
        let tag = screen + extra.joined()
        report(app, tag)
        if end {
            for _ in 0..<8 {
                let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                from.press(forDuration: 0.05, thenDragTo: to, withVelocity: 3000, thenHoldForDuration: 0.05)
            }
            sleep(2)
            report(app, tag + "-end")
        }
        app.terminate()
    }

    private func log(_ line: String) {
        print("PROBE " + line)
        out.append(line)
    }

    private func report(_ app: XCUIApplication, _ tag: String) {
        let shot = XCUIScreen.main.screenshot()
        n += 1
        let a = XCTAttachment(screenshot: shot)
        a.name = String(format: "%03d-%@", n, tag)
        a.lifetime = .keepAlways
        add(a)
        guard let px = Pixels(shot, pointWidth: app.frame.width) else {
            log("\(tag) pixels unavailable")
            return
        }
        log("\(tag) image \(px.w)x\(px.h) scale \(px.scale) space \(px.space)")
        let info = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'probe-'")).allElementsBoundByIndex
        for e in info {
            log("\(tag) \(e.identifier) \(e.label)")
        }
        let swatches = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'sw-'")).allElementsBoundByIndex
        for e in swatches {
            log("\(tag) \(e.identifier) \(px.dominant(e.frame))")
        }
        guard swatches.isEmpty else { return }
        // Real screens: every small labelled element with a coloured pixel.
        let screen = app.frame
        let kinds: [(String, XCUIElement.ElementType)] = [
            ("button", .button), ("text", .staticText), ("image", .image), ("switch", .switch), ("link", .link),
        ]
        for (kind, type) in kinds {
            for e in app.descendants(matching: type).allElementsBoundByIndex {
                let f = e.frame
                guard !f.isEmpty, f.width * f.height < screen.width * screen.height * 0.2,
                      f.intersects(screen) else { continue }
                let d = px.dominant(f)
                guard d != "grey" else { continue }
                let label = e.label.replacingOccurrences(of: "\n", with: " ").prefix(40)
                log("\(tag) \(kind) '\(label)' \(Int(f.minX)),\(Int(f.minY)) \(d)")
            }
        }
    }
}

/// Screenshot pixels as sRGB RGBA8.
private struct Pixels {
    let buf: [UInt8]
    let w: Int
    let h: Int
    let scale: CGFloat
    let space: String

    init?(_ shot: XCUIScreenshot, pointWidth: CGFloat) {
        guard let cg = shot.image.cgImage, pointWidth > 0 else { return nil }
        w = cg.width
        h = cg.height
        scale = CGFloat(cg.width) / pointWidth
        space = (cg.colorSpace?.name as String?) ?? "nil"
        var b = [UInt8](repeating: 0, count: w * h * 4)
        let width = w, height = h
        let ok: Bool = b.withUnsafeMutableBytes { p in
            guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: p.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: srgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        buf = b
    }

    /// Most frequent saturated colour in the rect (points): "#RRGGBB count/saturated/total [2nd]".
    func dominant(_ r: CGRect) -> String {
        let x0 = max(0, Int(r.minX * scale)), x1 = min(w, Int(r.maxX * scale))
        let y0 = max(0, Int(r.minY * scale)), y1 = min(h, Int(r.maxY * scale))
        guard x1 > x0, y1 > y0 else { return "grey" }
        var counts: [Int: Int] = [:]
        var sat = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * w + x) * 4
                let cr = Int(buf[i]), cg = Int(buf[i + 1]), cb = Int(buf[i + 2])
                if max(cr, cg, cb) - min(cr, cg, cb) < 40 { continue }
                sat += 1
                counts[(cr << 16) | (cg << 8) | cb, default: 0] += 1
            }
        }
        let top = counts.sorted { $0.value > $1.value }
        guard let first = top.first, first.value >= 4 else { return "grey" }
        let total = (x1 - x0) * (y1 - y0)
        var s = String(format: "#%06X %d/%d/%d", first.key, first.value, sat, total)
        if top.count > 1 {
            s += String(format: " 2nd #%06X %d", top[1].key, top[1].value)
        }
        return s
    }
}
