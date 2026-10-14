import XCTest

/// Walks the app offline from a clean install and attaches a screenshot of each step.
/// The attachments are the release screenshots (`docs/release/export-screenshots.sh`).
final class WalkthroughUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-resetData"]
        app.launch()
    }

    func testOfflineWalkthrough() {
        // 1. Onboarding.
        let name = app.textFields["Your name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        snap("01-onboarding")
        name.tap()
        name.typeText("David")
        app.buttons["Continue"].tap()

        // 2. Empty group list.
        XCTAssertTrue(app.navigationBars["Groups"].waitForExistence(timeout: 10))
        snap("02-no-groups")

        // 3. New group.
        app.navigationBars["Groups"].buttons["New group"].tap()
        let groupName = app.textFields["Group name"]
        XCTAssertTrue(groupName.waitForExistence(timeout: 5))
        groupName.tap()
        groupName.typeText("Lisbon trip")
        snap("03-new-group")
        app.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts["Lisbon trip"].waitForExistence(timeout: 5))
        app.staticTexts["Lisbon trip"].tap()

        // 4. A second participant.
        XCTAssertTrue(app.buttons["Add participant"].waitForExistence(timeout: 5))
        app.buttons["Add participant"].tap()
        let participant = app.textFields["Name"]
        XCTAssertTrue(participant.waitForExistence(timeout: 5))
        participant.tap()
        participant.typeText("Ana")
        snap("04-add-participant")
        app.buttons["Add"].tap()
        XCTAssertTrue(app.staticTexts["Ana"].waitForExistence(timeout: 5))

        // 5. An expense, split equally.
        app.buttons["Add expense"].tap()
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Dinner")
        let amount = app.textFields["Amount (EUR)"]
        amount.tap()
        amount.typeText("60")
        snap("05-add-expense")
        app.buttons["Save"].tap()

        // 6. The expense, balances and a suggested settlement, all without a network.
        XCTAssertTrue(app.staticTexts["Dinner"].waitForExistence(timeout: 5))
        snap("06-expense-and-balances")

        // 7. Everything is local: no account, no sync status.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Groups"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Account"].exists)
        XCTAssertFalse(app.staticTexts["Local only"].exists)
        snap("07-groups-local")
    }

    func testDemoPolishScreens() {
        app.terminate()
        app.launchArguments = ["-resetData", "-demoData"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Lisbon trip"].waitForExistence(timeout: 15))
        snap("08-groups-demo")
        app.staticTexts["Lisbon trip"].tap()
        XCTAssertTrue(app.staticTexts["Airbnb in Alfama"].waitForExistence(timeout: 10))
        snap("09-group-detail-demo")
        app.staticTexts["Airbnb in Alfama"].tap()
        XCTAssertTrue(app.navigationBars["Edit expense"].waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: app.buttons["Save"]
        )], timeout: 10), .completed)
        snap("10-edit-expense")
        app.buttons["Cancel"].tap()
    }

    func testEditingAnExpensePreservesItsPartialSplit() {
        app.terminate()
        app.launchArguments = ["-resetData", "-demoData"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Lisbon trip"].waitForExistence(timeout: 15))
        app.staticTexts["Lisbon trip"].tap()
        let tram = app.staticTexts["Tram 28 tickets"]
        XCTAssertTrue(tram.waitForExistence(timeout: 10))
        tram.tap()
        XCTAssertTrue(app.navigationBars["Edit expense"].waitForExistence(timeout: 5))
        let save = app.buttons["Save"]
        let ready = NSPredicate(format: "isEnabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: save)], timeout: 10), .completed)
        XCTAssertEqual(app.switches["D, David"].value as? String, "0")
        XCTAssertEqual(app.switches["M, Marta"].value as? String, "1")
        let title = app.textFields["Title"]
        title.tap()
        title.typeText(" updated")
        save.tap()
        XCTAssertTrue(app.staticTexts["Tram 28 tickets updated"].waitForExistence(timeout: 10))
        app.staticTexts["Tram 28 tickets updated"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: app.buttons["Save"])], timeout: 10), .completed)
        XCTAssertEqual(app.switches["D, David"].value as? String, "0")
        XCTAssertEqual(app.switches["M, Marta"].value as? String, "1")
    }

    func testUnequalSplitsAreSavedAndReopenedAsExactAmounts() {
        app.terminate()
        app.launchArguments = ["-resetData", "-demoData", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Lisbon trip"].waitForExistence(timeout: 15))
        app.staticTexts["Lisbon trip"].tap()
        XCTAssertTrue(app.buttons["Add expense"].waitForExistence(timeout: 10))
        app.buttons["Add expense"].tap()

        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Wine")
        let amount = app.textFields["Amount (EUR)"]
        amount.tap()
        amount.typeText("30")

        // 2 parts for David and 1 for Marta: 20.00 and 10.00.
        app.buttons["Shares"].tap()
        let david = app.textFields["David"]
        XCTAssertTrue(david.waitForExistence(timeout: 5))
        david.replaceText(with: "2")
        app.buttons["Done"].tap()
        let marta = app.textFields["Marta"]
        marta.replaceText(with: "1")
        app.buttons["Done"].tap()
        // The rest start at 1 part each; an empty field leaves them out.
        for other in ["Ana", "Bruno"] where app.textFields[other].exists {
            app.textFields[other].replaceText(with: "")
            app.buttons["Done"].tap()
        }
        snap("11-unequal-shares")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Wine"].waitForExistence(timeout: 10))

        app.staticTexts["Wine"].tap()
        XCTAssertTrue(app.navigationBars["Edit expense"].waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: app.buttons["Save"]
        )], timeout: 10), .completed)
        XCTAssertEqual(app.textFields["David"].value as? String, "20.00")
        XCTAssertEqual(app.textFields["Marta"].value as? String, "10.00")
    }

    func testSharedGroupLinkCanBeImportedAsACopy() {
        app.terminate()
        app.launchArguments = ["-resetData", "-demoData", "-exposeShareLink", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Lisbon trip"].waitForExistence(timeout: 15))
        app.staticTexts["Lisbon trip"].tap()
        XCTAssertTrue(app.buttons["Share group"].waitForExistence(timeout: 10))
        app.buttons["Share group"].tap()

        XCTAssertTrue(app.navigationBars["Share group"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.images["QR code for the group Lisbon trip"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Share as file"].exists)
        XCTAssertTrue(app.buttons["Share link"].exists)
        XCTAssertTrue(app.buttons["Share summary as text"].exists)
        let summary = app.staticTexts["summaryText"].label
        XCTAssertTrue(summary.hasPrefix("Lisbon trip – who owes whom"), "The summary is \(summary)")
        XCTAssertTrue(summary.contains(" owes "), "The summary is \(summary)")
        snap("12-share-group")
        app.buttons["Copy link"].tap()
        let copied = app.buttons["Link copied"]
        XCTAssertTrue(copied.waitForExistence(timeout: 5))
        let link = copied.value as? String ?? ""
        XCTAssertTrue(link.hasPrefix("tab://group?d="), "The copied link is \(link)")
        app.buttons["Done"].tap()

        // Opening the link on a phone that already has the group offers to update it or to add a copy.
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-incomingURL", link]
        app.launch()
        XCTAssertTrue(app.navigationBars["Import group"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["You already have this group"].exists)
        app.buttons["Add a copy"].tap()
        snap("13-import-group")
        app.buttons["Import group"].tap()
        let copies = app.staticTexts.matching(identifier: "Lisbon trip")
        XCTAssertTrue(copies.element(boundBy: 1).waitForExistence(timeout: 10))
    }

    func testBrokenLinkShowsAnErrorAndChangesNothing() {
        app.terminate()
        app.launchArguments = ["-resetData", "-demoData", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-incomingURL", "tab://group?d=not-a-real-group"]
        app.launch()
        XCTAssertTrue(app.alerts["Could not open the file"].waitForExistence(timeout: 15))
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.staticTexts["Lisbon trip"].exists)
        XCTAssertFalse(app.navigationBars["Import group"].exists)
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension XCUIElement {
    /// Replaces the text of a field: taps at its trailing edge so the cursor lands after the text, then deletes it.
    func replaceText(with newText: String) {
        coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let count = (value as? String)?.count ?? 0
        if count > 0 { typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count + 2)) }
        if !newText.isEmpty { typeText(newText) }
    }
}
