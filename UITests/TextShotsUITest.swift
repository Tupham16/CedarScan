import UIKit
import XCTest

/// THROWAWAY (never main): screenshots of screens with long content, every page of scrollable ones.
/// Screens / languages / sizes come from the SHOTS_* environment (TEST_RUNNER_ prefix in CI).
final class TextShotsUITest: XCTestCase {
    private var n = 0
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    func testShots() {
        continueAfterFailure = true
        let langs = (env["SHOTS_LANGS"] ?? "de,fr").split(separator: ",").map(String.init)
        let screens = (env["SHOTS_SCREENS"] ?? "legal-privacy").split(separator: ",").map(String.init)
        let sizes = (env["SHOTS_SIZES"] ?? "default,xxxl").split(separator: ",").map(String.init)
        let region = ["de": "DE", "fr": "FR", "es": "ES", "nl": "NL", "cs": "CZ", "sk": "SK", "vi": "VN", "en": "US"]
        for screen in screens {
            for lang in langs {
                // Legal texts exist in EN and FR only: other languages show EN; de stands for them.
                if screen.hasPrefix("legal"), lang != "de", lang != "fr" { continue }
                for size in sizes {
                    var args = ["-textshot", screen, "-AppleLanguages", "(\(lang))", "-AppleLocale", "\(lang)_\(region[lang] ?? "US")"]
                    if size == "xxxl" {
                        args += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]
                    }
                    capture(args, "\(screen)-\(lang)-\(size)")
                }
            }
        }
    }

    private func capture(_ args: [String], _ name: String) {
        let app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        sleep(3)
        var last: Data?
        for page in 0..<40 {
            let s = XCUIScreen.main.screenshot()
            // Compare below the status bar (its clock changes between shots).
            let png: Data? = {
                let img = s.image
                let cut = img.size.height / 12
                let f = UIGraphicsImageRendererFormat()
                f.scale = 1
                let r = UIGraphicsImageRenderer(size: CGSize(width: img.size.width, height: img.size.height - cut), format: f)
                return r.pngData { _ in img.draw(at: CGPoint(x: 0, y: -cut)) }
            }()
            if png != nil, png == last { break }
            last = png
            n += 1
            let a = XCTAttachment(screenshot: s)
            a.name = String(format: "%03d-%@-p%02d", n, name, page)
            a.lifetime = .keepAlways
            add(a)
            // Scroll ~70% of the screen, slowly (no fling).
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            bottom.press(forDuration: 0.05, thenDragTo: top, withVelocity: 600, thenHoldForDuration: 0.3)
            sleep(1)
        }
        app.terminate()
    }
}
