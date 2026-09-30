import XCTest

/// THROWAWAY (branch claude/home-bottom-shots, never main): Home's last card vs CedarTabBar.
final class HomeShots: XCTestCase {
    private var n = 0

    func testShots() {
        continueAfterFailure = true
        for count in [1, 3, 8, 20] {
            let app = launch(count)
            report(app, "n\(count)-top")
            scrollToEnd(app)
            report(app, "n\(count)-end")
            tryLastTrash(app, "n\(count)-end")
            app.terminate()
        }
        // Push / pop and delete, 20 properties.
        let app = launch(20)
        scrollToEnd(app)
        openLastCard(app)
        report(app, "n20-pushed")
        scrollToEnd(app)
        report(app, "n20-pushed-end")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(2)
        report(app, "n20-after-pop")
        tryLastTrash(app, "n20-after-pop")
        deleteOneVisible(app)
        report(app, "n20-after-delete")
        scrollToEnd(app)
        report(app, "n20-after-delete-end")
        tryLastTrash(app, "n20-after-delete-end")
        // Other tab roots.
        tab(app, "Orders")
        report(app, "orders")
        tab(app, "Learn")
        scrollToEnd(app)
        report(app, "learn-end")
        tab(app, "Home")
        report(app, "home-again")
        app.terminate()
        // Candidate fixes.
        for fix in ["margins", "padding"] {
            for count in [3, 20] {
                let a = launch(count, ["-homeFix", fix])
                report(a, "fix-\(fix)-n\(count)-top")
                scrollToEnd(a)
                report(a, "fix-\(fix)-n\(count)-end")
                tryLastTrash(a, "fix-\(fix)-n\(count)-end")
                a.terminate()
            }
        }
    }

    private func launch(_ count: Int, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-homeShots", "\(count)", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        app.launch()
        sleep(4)
        return app
    }

    private func tab(_ app: XCUIApplication, _ label: String) {
        let b = app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
            .last { $0.isHittable }
        b?.tap()
        sleep(2)
    }

    private func scrollToEnd(_ app: XCUIApplication) {
        for _ in 0..<8 {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: 3000, thenHoldForDuration: 0.05)
        }
        sleep(3)
    }

    private func trashes(_ app: XCUIApplication) -> [XCUIElement] {
        app.buttons.matching(NSPredicate(format: "label == 'Delete property'")).allElementsBoundByIndex
    }

    /// Frames of every trash button, the tab bar's Home item, probe text; screenshot.
    private func report(_ app: XCUIApplication, _ tag: String) {
        var lines = [tag]
        lines.append("window \(app.windows.firstMatch.frame)")
        for b in app.buttons.matching(NSPredicate(format: "label == 'Home'")).allElementsBoundByIndex {
            lines.append("Home button \(b.frame) hittable=\(b.isHittable)")
        }
        for (i, t) in trashes(app).enumerated() {
            lines.append("trash[\(i)] \(t.frame) hittable=\(t.isHittable)")
        }
        let probe = app.staticTexts["homeProbe"]
        lines.append("probe: " + (probe.exists ? probe.label : "missing"))
        let text = lines.joined(separator: "\n")
        print(text)
        n += 1
        let t = XCTAttachment(string: text)
        t.name = String(format: "%03d-%@.txt", n, tag)
        t.lifetime = .keepAlways
        add(t)
        shot(tag)
    }

    /// Finger-like tap on the centre of the LAST trash button (no auto-scroll): alert or not.
    private func tryLastTrash(_ app: XCUIApplication, _ tag: String) {
        guard let last = trashes(app).last, last.exists else { return note("\(tag) no trash") }
        let frame = last.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        let alert = app.alerts.firstMatch
        let ok = alert.waitForExistence(timeout: 3)
        note("\(tag) last trash \(frame) -> alert=\(ok)")
        if ok {
            shot(tag + "-alert")
            alert.buttons["Cancel"].tap()
            sleep(1)
        } else {
            shot(tag + "-noalert")
            // A miss lands on the tab bar: go back to Home if it moved.
            tab(app, "Home")
        }
    }

    private func openLastCard(_ app: XCUIApplication) {
        let cells = app.cells.allElementsBoundByIndex.filter { $0.isHittable }
        guard let c = cells.last else { return note("no hittable cell") }
        note("open cell \(c.frame)")
        c.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).tap()
        sleep(3)
    }

    private func deleteOneVisible(_ app: XCUIApplication) {
        guard let t = trashes(app).filter({ $0.isHittable }).dropLast().last else { return note("no trash to delete") }
        t.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let alert = app.alerts.firstMatch
        guard alert.waitForExistence(timeout: 3) else { return note("delete: no alert") }
        let destructive = alert.buttons.allElementsBoundByIndex.first { $0.label != "Cancel" }
        destructive?.tap()
        sleep(2)
    }

    private func note(_ s: String) {
        print(s)
        n += 1
        let t = XCTAttachment(string: s)
        t.name = String(format: "%03d-note.txt", n)
        t.lifetime = .keepAlways
        add(t)
    }

    private func shot(_ name: String) {
        n += 1
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = String(format: "%03d-%@", n, name)
        a.lifetime = .keepAlways
        add(a)
    }
}
