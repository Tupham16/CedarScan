import XCTest

/// THROWAWAY: screenshots of the Fog step 5 scan screen over a still image. Never merge to main.
final class Fog5Shots: XCTestCase {
    private var n = 0

    func testShots() {
        continueAfterFailure = true
        let on = ["-showScanMesh", "YES", "-fog5probe"]
        let de = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        capture(on, "probe-en")
        capture(on + de, "probe-de")
        capture(on + de + ["-fog5v1"], "probe-de-v1-fullwidth")
        capture(on + de + ["-fog5v2"], "probe-de-v2-scale")
        capture(on + ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"], "probe-es")
        capture(on + de + ["-fog5banner", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"], "probe-de-ax")
    }

    private func capture(_ args: [String], _ name: String, then: ((XCUIApplication) -> Void)? = nil) {
        let app = XCUIApplication()
        app.launchArguments = ["-fog5shots"] + args
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
