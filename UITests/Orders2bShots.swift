import UIKit
import XCTest

/// THROWAWAY (branch claude/orders2b-shots, never main): Orders v2 B screens, light or dark per run.
final class Orders2bShots: XCTestCase {
    private var n = 0

    private func lang(_ l: String, _ r: String) -> [String] { ["-AppleLanguages", "(\(l))", "-AppleLocale", "\(l)_\(r)"] }
    private let xxxl = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]
    private let axl = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]

    func testShots() {
        continueAfterFailure = true
        let en = lang("en", "US")
        let de = lang("de", "DE")
        let vi = lang("vi", "VN")
        let fr = lang("fr", "FR")

        capture("orders", en)
        capture("orders-a1", en, end: true) { app in
            let cancel = app.buttons["Cancel order"].firstMatch
            guard cancel.waitForExistence(timeout: 5) else { return }
            cancel.tap()
            sleep(2)
            self.shot("orders-a1-confirm-en")
            let destroy = app.alerts.buttons["Cancel order"].firstMatch
            guard destroy.waitForExistence(timeout: 3) else { return }
            destroy.tap()
            sleep(1)
            self.shot("orders-a1-cancelling-en")
            sleep(8)
            self.shot("orders-a1-refused-en")
        }
        capture("orders-a2", en, end: true)
        capture("orders-a3", en)
        capture("orders-a4", en)
        capture("orders-a5", en)
        capture("orders-a6", en)
        capture("placed-awaiting", en)
        capture("placed-awaiting-test", en)
        capture("placed-awaiting-nolink", en)
        capture("placed-awaiting-coupon", en)
        capture("placed", en)
        capture("placed-free", en)
        capture("home", en)
        capture("project", en)
        capture("detail-awaiting", en)
        capture("detail-ordered", en)

        capture("orders", de)
        capture("orders-a1", de, end: true)
        capture("orders-a5", de)
        capture("placed-awaiting", de)
        capture("home", de)
        capture("project", de)
        capture("detail-awaiting", de)

        capture("orders-a1", de + xxxl, end: true)
        capture("orders-a5", de + xxxl)
        capture("placed-awaiting", de + xxxl, end: true)
        capture("detail-awaiting", de + xxxl)
        capture("home", de + xxxl)
        capture("project", de + xxxl)

        capture("orders-a1", de + axl, end: true)
        capture("placed-awaiting", de + axl, end: true)
        capture("orders", en + axl)

        let ax3 = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        capture("home", de + ax3, end: true)
        capture("project", de + ax3)
        capture("detail-awaiting", de + ax3, end: true)
        capture("orders-a1", vi)
        capture("placed-awaiting", vi)
        capture("project", vi)
        capture("orders-a1", fr)
        capture("orders-a5", fr)
        capture("placed-awaiting", fr)
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
