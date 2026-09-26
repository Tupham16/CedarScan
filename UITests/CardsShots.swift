import UIKit
import XCTest

/// THROWAWAY (branch claude/cards-shots, never main): Cards v2 (Home / Orders) + address suggestions.
final class CardsShots: XCTestCase {
    private var n = 0

    private func lang(_ l: String, _ r: String) -> [String] { ["-AppleLanguages", "(\(l))", "-AppleLocale", "\(l)_\(r)"] }
    private let xxxl = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]
    private let ax3 = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    func testShots() {
        continueAfterFailure = true
        let en = lang("en", "US")
        let de = lang("de", "DE")
        let vi = lang("vi", "VN")
        let gb = lang("en", "GB")


        // Address suggestions: type a few letters, wait for MapKit, shot.
        for (args, text) in [(gb, "63 Saint Ja"), (en, "1600 Pennsylvania Av"), (vi, "12 Nguyen Hue"), (gb, "10 Downing")] {
            typeAddress(args, text)
        }
    }

    private func typeAddress(_ args: [String], _ text: String) {
        let app = XCUIApplication()
        app.launchArguments = ["-fog6shot", "address"] + args
        app.launch()
        sleep(4)
        let field = app.textFields.firstMatch
        guard field.waitForExistence(timeout: 5) else { shot("address-nofield"); app.terminate(); return }
        field.tap()
        sleep(1)
        field.typeText(text)
        for wait in [3, 6] {
            sleep(UInt32(wait))
            shot("address-" + text.replacingOccurrences(of: " ", with: "_") + "-\(wait)s")
        }
        let labels = app.buttons.allElementsBoundByIndex.prefix(30).map(\.label)
        let probe = app.staticTexts["probe"].firstMatch.label
        let a = XCTAttachment(string: "typed=\(text)\nprobe=\(probe)\nbuttons=\(labels)")
        a.name = String(format: "%03d-address-buttons-%@", n, text.replacingOccurrences(of: " ", with: "_"))
        a.lifetime = .keepAlways
        add(a)
        app.terminate()
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

    private func capture(_ screen: String, _ args: [String], end: Bool = false) {
        let app = XCUIApplication()
        app.launchArguments = ["-fog6shot", screen] + args
        app.launch()
        sleep(4)
        let size = args.contains("UICTContentSizeCategoryAccessibilityXXXL") ? "-ax3"
            : args.contains("UICTContentSizeCategoryXXXL") ? "-xxxl" : ""
        let langTag = args.first(where: { $0.hasPrefix("(") })?.trimmingCharacters(in: CharacterSet(charactersIn: "()")) ?? "en"
        let tag = screen + "-" + langTag + size
        shot(tag)
        if end {
            scrollToEnd(app)
            shot(tag + "-end")
        }
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
