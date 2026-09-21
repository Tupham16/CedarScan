import XCTest

/// THROWAWAY: screenshots of the Fog step 5 scan screen over a still image. Never merge to main.
final class Fog5Shots: XCTestCase {
    private var n = 0

    func testShots() {
        continueAfterFailure = true
        capture([], "en-on") { app in
            for line in app.debugDescription.split(separator: "\n") {
                print("FOG5TREE", line)
            }
            let toggle = app.buttons["Toggle scan mesh"].firstMatch
            if toggle.waitForExistence(timeout: 5) {
                toggle.tap()
                sleep(1)
                self.shot("en-off")
            } else {
                print("FOG5 toggle not found")
            }
        }
        capture(["-fog5white"], "en-white")
        capture(["-fog5banner"], "en-banner")
        capture(["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"], "de")
        capture(["-AppleLanguages", "(cs)", "-AppleLocale", "cs_CZ"], "cs")
        capture(["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN"], "vi")
        capture(["-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"], "fr")
        capture(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"], "en-axL")
        capture(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
                 "-AppleLanguages", "(de)", "-AppleLocale", "de_DE"], "de-axXXXL")
    }

    private func capture(_ extra: [String], _ name: String, then: ((XCUIApplication) -> Void)? = nil) {
        let app = XCUIApplication()
        app.launchArguments = ["-fog5shots"] + extra
        app.launch()
        sleep(4)
        shot(name)
        then?(app)
        app.terminate()
    }

    private func shot(_ name: String) {
        n += 1
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = String(format: "%02d-%@", n, name)
        a.lifetime = .keepAlways
        add(a)
    }
}
