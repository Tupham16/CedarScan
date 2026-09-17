import XCTest

/// Throwaway: screenshots of the system chrome under the iOS 26 SDK. Never merge to main.
final class ChromeShots: XCTestCase {
    private var n = 0

    func testShots() {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Orders"].firstMatch.waitForExistence(timeout: 60))
        sleep(2)
        shot("home")

        app.buttons["Scan a new space"].firstMatch.tap()
        sleep(2)
        shot("home-alert")
        let ok = app.alerts.buttons.firstMatch
        if ok.waitForExistence(timeout: 5) { ok.tap() }

        tab(app, "Orders")
        shot("orders")
        tab(app, "Learn")
        shot("learn")
        let faq = app.staticTexts["Order Q&A"].firstMatch
        if faq.waitForExistence(timeout: 5) {
            faq.tap()
            sleep(2)
            shot("learn-faq")
            app.navigationBars.buttons.firstMatch.tap()
            sleep(1)
        }
        tab(app, "Account")
        shot("account")
        for label in ["Sign in", "Create account", "Sign in or create account"] {
            let b = app.buttons[label].firstMatch
            if b.exists {
                b.tap()
                sleep(2)
                shot("account-sheet")
                break
            }
        }
        print("CHROME-SHOTS buttons:", app.buttons.allElementsBoundByIndex.map(\.label))
    }

    private func tab(_ app: XCUIApplication, _ name: String) {
        let b = app.buttons[name].firstMatch
        if b.waitForExistence(timeout: 10) { b.tap() }
        sleep(2)
    }

    private func shot(_ name: String) {
        n += 1
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = String(format: "%02d-%@", n, name)
        a.lifetime = .keepAlways
        add(a)
    }
}
