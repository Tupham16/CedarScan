import UIKit
import XCTest

/// THROWAWAY (branch claude/fog6-shots, never main): Fog step 6 screens, light or dark per run.
final class Fog6Shots: XCTestCase {
    private var n = 0

    private func lang(_ l: String, _ r: String) -> [String] { ["-AppleLanguages", "(\(l))", "-AppleLocale", "\(l)_\(r)"] }
    private let xxxl = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]

    func testShots() {
        continueAfterFailure = true
        let en = lang("en", "US")
        let de = lang("de", "DE")
        // Fog step 7 screens.
        for screen in ["account", "account-signedout", "account-verify", "forgot", "delete", "gate-signedout",
                       "revision", "supplement", "tour"] {
            capture(screen, en, end: true)
        }
        capture("faq", en) { app in self.expandFAQ(app); self.pages(app, "faq-open-en") }
        capture("legal", en, pages: true)
        capture("account", de + xxxl, pages: true)
        capture("account-signedout", de + xxxl, pages: true)
        capture("account-verify", de + xxxl)
        capture("faq", de) { app in self.expandFAQ(app); self.pages(app, "faq-open-de") }
        capture("faq", de + xxxl) { app in self.expandFAQ(app); self.pages(app, "faq-open-de-xxxl") }
        capture("legal", de + xxxl, pages: true)
        for screen in ["forgot", "delete", "revision", "supplement", "gate-signedout"] {
            capture(screen, de + xxxl, end: true)
        }
    }

    /// Opens the first questions of every group (answers are separate list rows).
    private func expandFAQ(_ app: XCUIApplication) {
        let cells = app.collectionViews.cells
        guard cells.firstMatch.waitForExistence(timeout: 5) else { return }
        for i in [0, 2, 4] where cells.count > i {
            cells.element(boundBy: i).tap()
            sleep(1)
        }
        sleep(1)
    }

    /// Fast drags up until the form's end is on screen.
    private func scrollToEnd(_ app: XCUIApplication) {
        for _ in 0..<8 {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: 3000, thenHoldForDuration: 0.05)
        }
        sleep(2)
    }

    private func capture(_ screen: String, _ args: [String], pages: Bool = false, end: Bool = false, then: ((XCUIApplication) -> Void)? = nil) {
        let app = XCUIApplication()
        app.launchArguments = ["-fog6shot", screen] + args
        app.launch()
        sleep(4)
        let size = args.contains("UICTContentSizeCategoryAccessibilityL") ? "-axl"
            : args.contains("UICTContentSizeCategoryXXXL") ? "-xxxl"
            : args.contains("UICTContentSizeCategoryXXL") ? "-xxl"
            : args.contains("UICTContentSizeCategoryS") ? "-s" : ""
        let langTag = args.first(where: { $0.hasPrefix("(") })?.trimmingCharacters(in: CharacterSet(charactersIn: "()")) ?? "en"
        let tag = screen + "-" + langTag + size
        if pages {
            self.pages(app, tag)
        } else if end {
            shot(tag)
            scrollToEnd(app)
            shot(tag + "-end")
        } else {
            shot(tag)
        }
        then?(app)
        app.terminate()
    }

    private func tapSegment(_ app: XCUIApplication, _ index: Int) {
        let seg = app.segmentedControls.firstMatch
        if seg.waitForExistence(timeout: 3) {
            seg.buttons.element(boundBy: index).tap()
            sleep(2)
        }
    }

    private func openGuide(_ app: XCUIApplication) {
        let cell = app.collectionViews.cells.firstMatch
        if cell.waitForExistence(timeout: 5) {
            cell.tap()
        }
        sleep(2)
    }

    /// Screenshot, scroll ~60% of the screen slowly, repeat until the picture stops changing.
    private func pages(_ app: XCUIApplication, _ tag: String) {
        var last: Data?
        for page in 0..<14 {
            let s = XCUIScreen.main.screenshot()
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
            shot("\(tag)-p\(page)", s)
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: 500, thenHoldForDuration: 0.3)
            sleep(1)
        }
    }

    private func shot(_ name: String, _ s: XCUIScreenshot? = nil) {
        n += 1
        let a = XCTAttachment(screenshot: s ?? XCUIScreen.main.screenshot())
        a.name = String(format: "%03d-%@", n, name)
        a.lifetime = .keepAlways
        add(a)
    }
}
