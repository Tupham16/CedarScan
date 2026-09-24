import XCTest

/// THROWAWAY: launch the Orders list 8 times and screenshot it (are the filter chips drawn?).
final class Orders2Shots: XCTestCase {
    private var n = 0

    func testFlake() {
        continueAfterFailure = true
        for i in 1...8 {
            capture(i % 2 == 0 ? ["-orders2error"] : [], "list-r\(i)")
        }
    }

    private func capture(_ args: [String], _ name: String) {
        let app = XCUIApplication()
        app.launchArguments = ["-orders2shots"] + args
        app.launch()
        sleep(4)
        n += 1
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = String(format: "%02d-%@", n, name)
        a.lifetime = .keepAlways
        add(a)
        app.terminate()
    }
}
