import XCTest

/// Drives the real app against a real local backend (scripts/run-ui-tests.sh starts it).
/// Covers: account creation, Alpha and Beta onboarding, pairing with Alpha approval, simulated
/// telemetry, viewing telemetry, changing settings, a help request alert, acknowledging it, and
/// revoking access. Each launch uses an in-memory token store (-uiTesting), so it starts signed out.
final class EndToEndUITests: XCTestCase {
    let apiBaseURL = ProcessInfo.processInfo.environment["AB_UITEST_API"] ?? "http://127.0.0.1:8787"
    let password = "uitest-password-1"
    let runId = String(UUID().uuidString.prefix(6)).lowercased()
    var alphaEmail: String { "alpha-\(runId)@uitest.local" }
    var betaEmail: String { "beta-\(runId)@uitest.local" }
    let alphaName = "Rose Alpha"
    let betaName = "Ben Beta"

    override func setUp() {
        continueAfterFailure = false
    }

    func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-apiBaseURL", apiBaseURL, "-simulation", "YES"]
        app.launch()
        return app
    }

    func allowNotificationsIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 4) { allow.tap() }
    }

    func flip(_ toggle: XCUIElement) {
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    func auth(_ app: XCUIApplication, email: String, create: Bool) {
        let emailField = app.textFields["email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 15))
        if create { flip(app.switches["createAccountToggle"]) }
        emailField.tap()
        emailField.typeText(email)
        let pw = app.secureTextFields["password"]
        pw.tap()
        pw.typeText(password)
        app.buttons["submitAuth"].tap()
    }

    func onboard(_ app: XCUIApplication, name: String, alpha: Bool) {
        let nameField = app.textFields["name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 15))
        nameField.tap()
        nameField.typeText(name)
        if alpha {
            flip(app.switches["roleAlpha"])
            app.swipeUp()
            flip(app.switches["consent"])
        } else {
            flip(app.switches["roleBeta"])
        }
        app.buttons["continueOnboarding"].tap()
        allowNotificationsIfAsked()
    }

    func testFullWellderWorkflow() throws {
        // 1. Alpha creates an account, onboards, creates an invitation and sends simulated telemetry.
        var app = launch()
        auth(app, email: alphaEmail, create: true)
        onboard(app, name: alphaName, alpha: true)
        XCTAssertTrue(app.staticTexts["monitoringState"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Caregivers"].tap()
        app.buttons["inviteCaregiver"].tap()
        app.buttons["createInvite"].tap()
        let codeLabel = app.staticTexts["inviteCode"]
        XCTAssertTrue(codeLabel.waitForExistence(timeout: 10))
        let code = codeLabel.label.replacingOccurrences(of: " ", with: "")
        XCTAssertEqual(code.count, 8)
        app.buttons["inviteDone"].tap()
        app.tabBars.buttons["Home"].tap()
        let send = app.buttons["sendSimulatedData"]
        for _ in 0..<4 where !send.isHittable { app.swipeUp() }
        send.tap()
        XCTAssertTrue(app.staticTexts["simulationResult"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["simulationResult"].label.hasPrefix("Sent"), app.staticTexts["simulationResult"].label)
        app.terminate()

        // 2. Beta creates an account and redeems the code (pending until the Alpha approves).
        app = launch()
        auth(app, email: betaEmail, create: true)
        onboard(app, name: betaName, alpha: false)
        XCTAssertTrue(app.otherElements["emptyDashboard"].waitForExistence(timeout: 20) || app.buttons["addAlpha"].waitForExistence(timeout: 5))
        app.buttons["addAlpha"].tap()
        let field = app.textFields["inviteCodeField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(code)
        app.buttons["redeemInvite"].tap()
        XCTAssertTrue(app.staticTexts["redeemResult"].waitForExistence(timeout: 10))
        app.buttons["redeemDone"].tap()
        XCTAssertFalse(app.buttons["alphaCard-\(alphaName)"].exists, "not visible before approval")
        app.terminate()

        // 3. Alpha approves the caregiver, changes a setting and requests help.
        app = launch()
        auth(app, email: alphaEmail, create: false)
        allowNotificationsIfAsked()
        app.tabBars.buttons["Caregivers"].tap()
        let pending = app.buttons["pending-\(betaName)"]
        XCTAssertTrue(pending.waitForExistence(timeout: 15))
        pending.tap()
        app.buttons["approveCaregiver"].tap()
        XCTAssertTrue(app.buttons["caregiver-\(betaName)"].waitForExistence(timeout: 10))

        app.tabBars.buttons["Settings"].tap()
        flip(app.switches["nightModeToggle"])
        app.buttons["saveSettings"].tap()
        XCTAssertTrue(app.buttons["saveSettings"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Home"].tap()
        app.buttons["helpButton"].tap()
        app.buttons["confirmHelp"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Help request sent"].waitForExistence(timeout: 10) || app.staticTexts["Help request sent"].exists)
        sleep(2) // let the upload complete
        app.terminate()

        // 4. Beta sees the Alpha, inspects telemetry and acknowledges the alert.
        app = launch()
        auth(app, email: betaEmail, create: false)
        allowNotificationsIfAsked()
        // The open help request rings the full-screen alarm; acknowledge it there (the caregiver's
        // main path), then check the alert's detail shows it as acknowledged.
        let ackAlarm = app.buttons["acknowledgeAlarm"]
        XCTAssertTrue(ackAlarm.waitForExistence(timeout: 20), "alarm for the open help request")
        sleep(1) // let the full-screen cover finish presenting
        // Coordinate tap: while the alarm is sounding, XCUITest computes no hit point ({-1, -1})
        // for buttons on this cover and a plain tap() never lands.
        ackAlarm.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let card = app.buttons["alphaCard-\(alphaName)"]
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        // Wait for the alarm's full-screen cover to finish dismissing.
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: card)
        if XCTWaiter().wait(for: [hittable], timeout: 10) != .completed {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.lifetime = .keepAlways
            add(shot)
            XCTFail("dashboard card stayed covered after silencing the alarm")
        }
        card.tap()
        XCTAssertTrue(app.staticTexts["statusReason"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["statusReason"].label.contains("requested help"), app.staticTexts["statusReason"].label)
        app.segmentedControls.buttons["Heart"].tap()
        XCTAssertTrue(app.staticTexts["hrReadings"].waitForExistence(timeout: 10) || app.otherElements["hrReadings"].exists)
        app.segmentedControls.buttons["Location"].tap()
        XCTAssertTrue(app.staticTexts["recordedPoints"].waitForExistence(timeout: 10) || app.otherElements["recordedPoints"].exists)
        app.segmentedControls.buttons["Alerts"].tap()
        let alertRow = app.buttons["alert-manualHelpRequest"]
        XCTAssertTrue(alertRow.waitForExistence(timeout: 10))
        alertRow.tap()
        XCTAssertTrue(app.buttons["resolveAlert"].waitForExistence(timeout: 10), "acknowledged from the alarm screen")
        XCTAssertFalse(app.buttons["acknowledgeAlert"].exists)
        app.terminate()

        // 5. Alpha revokes access.
        app = launch()
        auth(app, email: alphaEmail, create: false)
        allowNotificationsIfAsked()
        app.tabBars.buttons["Caregivers"].tap()
        let caregiver = app.buttons["caregiver-\(betaName)"]
        XCTAssertTrue(caregiver.waitForExistence(timeout: 15))
        caregiver.tap()
        app.buttons["revokeCaregiver"].tap()
        app.buttons["confirmRevoke"].firstMatch.tap()
        XCTAssertFalse(app.buttons["caregiver-\(betaName)"].waitForExistence(timeout: 5))
        app.terminate()

        // 6. The revoked Beta no longer sees the Alpha.
        app = launch()
        auth(app, email: betaEmail, create: false)
        allowNotificationsIfAsked()
        XCTAssertTrue(app.buttons["addAlpha"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["alphaCard-\(alphaName)"].waitForExistence(timeout: 5))
    }
}
