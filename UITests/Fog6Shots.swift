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
        // 6b round 2: Order placed (scrolls when too tall) + Place order label padding.
        for args in [en, de, de + xxxl] {
            capture("placed", args)
        }
        capture("placed-free", en)
        capture("placed-coupon", de)
        capture("placed-badcoupon", en)
        capture("placed-badcoupon", de + xxxl)
        capture("placed-tall", de + xxxl, end: true)
        capture("order-busy", en, end: true)
        capture("order-error", de, end: true)
        capture("order", de + xxxl, end: true)
        capture("order-paid", en, end: true)
        if ProcessInfo.processInfo.environment["SHOTS_ONLY"] != "all" {
            return
        }
        if ProcessInfo.processInfo.environment["SHOTS_ONLY"] == "naming" {
            let xxl = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXL"]
            let small = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryS"]
            for extra in [[], small, xxl, xxxl] {
                capture("naming", en + extra)
                capture("naming-typing", en + extra)
                capture("naming", de + extra)
            }
            return
        }
        for screen in ["detail", "detail-ordered", "detail-extra", "detail-low", "detail-nomodel", "detail-signedout", "detail-verify"] {
            capture(screen, en)
        }
        capture("detail", de)
        capture("detail-low", de)
        capture("viewer", en)
        capture("saved", en) { app in
            self.tapSegment(app, 1)
            self.shot("saved-3d-en")
        }
        capture("saved-extra", en)
        capture("saved-novideo", de)
        capture("address", en) { app in
            let field = app.textFields.firstMatch
            guard field.waitForExistence(timeout: 5) else { return }
            field.tap()
            app.typeText("7 Maple")
            sleep(3)
            self.shot("address-typing-en")
            app.typeText(" Court\n")
            sleep(4)
            self.shot("address-filled-en")
        }
        capture("address", de)
        capture("naming", en)
        capture("naming", de)
        capture("naming", de + xxxl)
        capture("guide", en, pages: true)
        capture("guide", de, pages: true)
        capture("guide", de + xxxl, pages: true)
        capture("learn", en) { app in
            self.openGuide(app)
            self.pages(app, "learn-guide-en")
        }
        capture("learn", de + xxxl) { app in
            self.openGuide(app)
            self.pages(app, "learn-guide-de-xxxl")
        }
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
        let size = args.contains("UICTContentSizeCategoryXXXL") ? "-xxxl"
            : args.contains("UICTContentSizeCategoryXXL") ? "-xxl"
            : args.contains("UICTContentSizeCategoryS") ? "-s" : ""
        let tag = screen + "-" + (args.contains("(de)") ? "de" : "en") + size
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
