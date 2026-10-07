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
        app.buttons["New group"].tap()
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

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
