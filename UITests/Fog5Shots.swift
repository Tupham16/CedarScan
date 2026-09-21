import XCTest

/// THROWAWAY: screenshots of the Fog step 5 scan screen over a still image. Never merge to main.
final class Fog5Shots: XCTestCase {
    private var n = 0

    func testShots() {
        continueAfterFailure = true
        let on = ["-showScanMesh", "YES"]
        func lang(_ l: String, _ r: String) -> [String] { ["-AppleLanguages", "(\(l))", "-AppleLocale", "\(l)_\(r)"] }
        let ax5 = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        capture(on + lang("de", "DE") + ["-fog5probe"], "de-probe")
        capture(on, "en-on")
        capture(["-showScanMesh", "NO"], "en-off")
        capture(on + ["-fog5white"], "en-white")
        capture(on + ["-fog5banner"], "en-banner")
        capture(on + lang("de", "DE"), "de")
        capture(on + lang("cs", "CZ"), "cs")
        capture(on + lang("sk", "SK"), "sk")
        capture(on + lang("vi", "VN"), "vi")
        capture(on + lang("fr", "FR"), "fr")
        capture(on + lang("nl", "NL"), "nl")
        capture(on + lang("es", "ES"), "es")
        capture(on + ax5, "en-ax")
        capture(on + lang("de", "DE") + ["-fog5banner"] + ax5, "de-banner-ax")
        capture(on + lang("fr", "FR") + ax5, "fr-ax")
        capture(on + lang("es", "ES") + ax5, "es-ax")
        capture(on + lang("nl", "NL") + ax5, "nl-ax")
        capture(on + lang("de", "DE") + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"], "de-xxxl")
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
