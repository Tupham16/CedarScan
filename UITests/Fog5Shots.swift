import XCTest

/// THROWAWAY: screenshots of the Fog step 5 scan screen over a still image. Never merge to main.
final class Fog5Shots: XCTestCase {
    private var n = 0

    func testShots() {
        continueAfterFailure = true
        let on = ["-showScanMesh", "YES"]
        let de = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        capture(on + de + ["-fog5probe"], "de-probe")
        capture(on, "en-on")
        capture(["-showScanMesh", "NO"], "en-off")
        capture(on + ["-fog5white"], "en-white")
        capture(on + de, "de")
        capture(on + ["-AppleLanguages", "(cs)", "-AppleLocale", "cs_CZ"], "cs")
        capture(on + ["-AppleLanguages", "(sk)", "-AppleLocale", "sk_SK"], "sk")
        capture(on + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN"], "vi")
        capture(on + ["-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"], "fr")
        capture(on + ["-AppleLanguages", "(nl)", "-AppleLocale", "nl_NL"], "nl")
        capture(on + ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"], "es")
        capture(on + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"], "en-axL")
        capture(on + de + ["-fog5banner", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"], "de-banner-axXXXL")
        capture(on + de + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryExtraExtraExtraLarge"], "de-xxxL")
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
