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

        // 7. Account screen with no backend configured.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Account"].tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))
        snap("07-account-offline")
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
        if app.buttons.matching(identifier: "1 of your edits was replaced").firstMatch.exists {
            app.buttons.matching(identifier: "1 of your edits was replaced").firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Review changes"].waitForExistence(timeout: 5))
            snap("11-conflict-review")
        }
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

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
