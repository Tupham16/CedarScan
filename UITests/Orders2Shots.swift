import XCTest

/// THROWAWAY: screenshots of the Orders v2 list + order detail with canned orders. Never merge to main.
final class Orders2Shots: XCTestCase {
    private var n = 0

    func testShots() {
        continueAfterFailure = true
        func lang(_ l: String, _ r: String) -> [String] { ["-AppleLanguages", "(\(l))", "-AppleLocale", "\(l)_\(r)"] }
        let ax3 = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        let xxxl = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]
        capture([], "list") { app in
            // A real tap on a row pushes the detail; Back returns to the list.
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Oak Street")).firstMatch.tap()
            sleep(2)
            self.shot("tap-oak")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            sleep(2)
            self.shot("tap-back")
            app.searchFields.firstMatch.tap()
            app.typeText("Harbor")
            sleep(2)
            self.shot("search-harbor")
        }
        capture(["-orders2error"], "list-offline")
        capture(["-orders2open", "o1"], "detail-delivered") { app in
            app.swipeUp()
            sleep(2)
            self.shot("detail-delivered-bottom")
        }
        capture(["-orders2open", "o2"], "detail-unpaid")
        capture(["-orders2open", "o3"], "detail-tourphotos")
        capture(["-orders2open", "o4"], "detail-long") { app in
            app.swipeUp()
            sleep(2)
            self.shot("detail-long-bottom")
        }
        capture(["-orders2open", "o5"], "detail-refunded")
        capture(["-orders2open", "o6"], "detail-noitems")
        capture(["-orders2open", "o1", "-orders2error"], "detail-offline")
        capture(lang("de", "DE"), "list-de")
        capture(["-orders2open", "o1"] + lang("de", "DE"), "detail-de")
        capture(["-orders2open", "o2"] + lang("vi", "VN"), "detail-unpaid-vi")
        capture(["-orders2open", "o4"] + lang("fr", "FR"), "detail-long-fr")
        capture(xxxl + lang("de", "DE"), "list-de-xxxl")
        capture(["-orders2open", "o1"] + xxxl + lang("de", "DE"), "detail-de-xxxl") { app in
            app.swipeUp()
            sleep(2)
            self.shot("detail-de-xxxl-bottom")
        }
        capture(ax3, "list-ax3")
        capture(["-orders2open", "o1"] + ax3, "detail-ax3") { app in
            app.swipeUp()
            sleep(2)
            self.shot("detail-ax3-bottom")
        }
    }

    private func capture(_ args: [String], _ name: String, then: ((XCUIApplication) -> Void)? = nil) {
        let app = XCUIApplication()
        app.launchArguments = ["-orders2shots"] + args
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
