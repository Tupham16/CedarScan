import UIKit
import XCTest

/// THROWAWAY (branch claude/orders2c-shots, never main): Orders v2 C screens, light or dark per run.
final class Orders2cShots: XCTestCase {
    private var n = 0

    private func lang(_ l: String, _ r: String) -> [String] { ["-AppleLanguages", "(\(l))", "-AppleLocale", "\(l)_\(r)"] }
    private let xxxl = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]
    private let axl = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
    private let ax3 = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    func testShots() {
        continueAfterFailure = true
        let en = lang("en", "US")
        let de = lang("de", "DE")
        let vi = lang("vi", "VN")
        let fr = lang("fr", "FR")

        // Order detail: delivered order with a delivered purchase + "Add to this order".
        capture("orders-a7", en, end: true) { app in
            let add = app.buttons["Add to this order"].firstMatch
            guard add.waitForExistence(timeout: 3) else { return }
            add.tap()
            sleep(3)
            self.shot("orders-a7-sheet-en")
        }
        // A purchase awaiting payment: Pay Now + Cancel items (+ its confirm alert).
        capture("orders-a4", en, end: true) { app in
            let cancel = app.buttons["Cancel items"].firstMatch
            guard cancel.waitForExistence(timeout: 3) else { return }
            cancel.tap()
            sleep(2)
            self.shot("orders-a4-confirm-en")
        }
        capture("orders-a8", en, end: true)
        capture("orders", en)
        // The sheet: form (3D + site plan picked), coupon-adjusted amount, done, blocked, not delivered.
        capture("addon", en, end: true)
        capture("addon-coupon", en, end: true)
        capture("addon-done", en)
        capture("addon-done-notdelivered", en)
        capture("addon-lost", en)
        capture("addon-blocked", en)
        capture("addon-notdelivered", en, end: true)

        for l in [de, vi, fr] {
            capture("orders-a7", l, end: true)
            capture("orders-a4", l, end: true)
            capture("addon", l, end: true)
            capture("addon-coupon", l, end: true)
            capture("addon-done", l)
        }
        capture("addon-blocked", de)
        capture("addon-notdelivered", de, end: true)

        capture("orders-a7", de + xxxl, end: true)
        capture("orders-a4", de + xxxl, end: true)
        capture("addon", de + xxxl, end: true)
        capture("addon-coupon", de + xxxl, end: true)
        capture("addon-done-notdelivered", de + xxxl)

        capture("orders-a4", de + axl, end: true)
        capture("addon", de + axl, end: true)
        capture("addon-done", de + axl)
        capture("orders-a7", en + ax3, end: true)
        capture("addon", en + ax3, end: true)
    }

    /// Fast drags up until the screen's end is on screen.
    private func scrollToEnd(_ app: XCUIApplication) {
        for _ in 0..<6 {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: 3000, thenHoldForDuration: 0.05)
        }
        sleep(2)
    }

    private func capture(_ screen: String, _ args: [String], end: Bool = false, then: ((XCUIApplication) -> Void)? = nil) {
        let app = XCUIApplication()
        app.launchArguments = ["-fog6shot", screen] + args
        app.launch()
        sleep(4)
        let size = args.contains("UICTContentSizeCategoryAccessibilityXXXL") ? "-ax3"
            : args.contains("UICTContentSizeCategoryAccessibilityL") ? "-axl"
            : args.contains("UICTContentSizeCategoryXXXL") ? "-xxxl" : ""
        let langTag = args.first(where: { $0.hasPrefix("(") })?.trimmingCharacters(in: CharacterSet(charactersIn: "()")) ?? "en"
        let tag = screen + "-" + langTag + size
        shot(tag)
        if end {
            scrollToEnd(app)
            shot(tag + "-end")
        }
        then?(app)
        app.terminate()
    }

    private func shot(_ name: String) {
        n += 1
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = String(format: "%03d-%@", n, name)
        a.lifetime = .keepAlways
        add(a)
    }
}
