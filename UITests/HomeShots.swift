import XCTest

/// THROWAWAY (branch claude/home-bottom-shots, never main): Home's last card vs CedarTabBar.
final class HomeShots: XCTestCase {
    private var n = 0

    func testShots() {
        continueAfterFailure = true
        // Round 3: the real fix (tabRootBarRoom) compiled in.
        for count in [1, 3, 20] {
            let app = launch(count)
            report(app, "n\(count)-top")
            scrollToEnd(app)
            report(app, "n\(count)-end")
            tryLastTrash(app, "n\(count)-end")
            app.terminate()
        }
        let app = launch(20)
        scrollToEnd(app)
        openLastCard(app)
        report(app, "n20-pushed")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(2)
        report(app, "n20-after-pop")
        scrollToEnd(app)
        report(app, "n20-after-pop-end")
        tryLastTrash(app, "n20-after-pop-end")
        deleteOneVisible(app)
        report(app, "n20-after-delete")
        scrollToEnd(app)
        report(app, "n20-after-delete-end")
        tryLastTrash(app, "n20-after-delete-end")
        // Search with the keyboard up.
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 3) {
            field.tap()
            field.typeText("Elm")
            sleep(2)
            report(app, "n20-search-elm")
            scrollToEnd(app)
            report(app, "n20-search-elm-end")
        }
        app.terminate()
        // Other tab roots, signed out.
        let out = launch(1)
        tab(out, "Learn")
        scrollToEnd(out)
        report(out, "learn-end")
        tab(out, "Account")
        report(out, "account-signedout")
        scrollToEnd(out)
        report(out, "account-signedout-end")
        out.terminate()
        // Signed in (fake): Account list end, a pushed legal page end, Orders.
        let inApp = launch(1, ["-homeSignedIn"])
        tab(inApp, "Orders")
        report(inApp, "orders-signedin")
        tab(inApp, "Account")
        report(inApp, "account-signedin")
        scrollToEnd(inApp)
        report(inApp, "account-signedin-end")
        let legal = inApp.cells.allElementsBoundByIndex.first { $0.label.contains("Privacy") && $0.isHittable }
            ?? inApp.buttons.allElementsBoundByIndex.first { $0.label.contains("Privacy") && $0.isHittable }
        if let legal {
            legal.tap()
            sleep(2)
            report(inApp, "legal-top")
            scrollToEnd(inApp)
            report(inApp, "legal-end")
        } else {
            note("no Privacy link")
        }
        inApp.terminate()
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
        for v in app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'CedarScan 2'")).allElementsBoundByIndex {
            lines.append("version \(v.label) \(v.frame)")
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
