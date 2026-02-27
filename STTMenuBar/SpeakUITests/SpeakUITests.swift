import XCTest

final class SpeakUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp(env: [String: String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = env
        app.launch()
        return app
    }

    private func waitForTextContains(_ element: XCUIElement, text: String, timeout: TimeInterval = 3) {
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    private func waitForValueContains(_ element: XCUIElement, text: String, timeout: TimeInterval = 3) {
        let predicate = NSPredicate(format: "value CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    func testSetupRendersDefaultParakeetAndAllModelOptions() {
        let app = launchApp(env: [
            "SPEAK_UI_TEST_MODE": "1",
            "SPEAK_UI_MIC_STATUS": "authorized",
            "SPEAK_UI_AX_STATUS": "trusted",
            "SPEAK_UI_RUNTIME_STATUS": "ok",
            "SPEAK_UI_FORCE_NEEDS_SETUP": "1"
        ])

        let modelPicker = app.popUpButtons["setup.modelPicker"]
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 2))
        waitForValueContains(modelPicker, text: "Parakeet v3")

        let description = app.staticTexts["setup.modelDescription"]
        XCTAssertTrue(description.exists)
        waitForTextContains(description, text: "Fast")
        waitForTextContains(description, text: "Small")

        modelPicker.click()
        XCTAssertTrue(app.menuItems["Parakeet v3 (Default)"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["Small (Fastest)"].exists)
        XCTAssertTrue(app.menuItems["Medium (Recommended)"].exists)
        XCTAssertTrue(app.menuItems["Large v3 (Best Accuracy)"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testBlockedPermissionsKeepDownloadDisabled() {
        let app = launchApp(env: [
            "SPEAK_UI_TEST_MODE": "1",
            "SPEAK_UI_MIC_STATUS": "denied",
            "SPEAK_UI_AX_STATUS": "blocked",
            "SPEAK_UI_FORCE_NEEDS_SETUP": "1"
        ])

        let downloadButton = app.buttons["setup.downloadButton"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 2))
        XCTAssertFalse(downloadButton.isEnabled)
    }

    func testDownloadEnablesWhenPermissionsGrantedAndConsentChecked() {
        let app = launchApp(env: [
            "SPEAK_UI_TEST_MODE": "1",
            "SPEAK_UI_MIC_STATUS": "authorized",
            "SPEAK_UI_AX_STATUS": "trusted",
            "SPEAK_UI_RUNTIME_STATUS": "ok",
            "SPEAK_UI_FORCE_NEEDS_SETUP": "1"
        ])

        let consent = app.checkBoxes["setup.consentCheckbox"]
        XCTAssertTrue(consent.waitForExistence(timeout: 2))
        consent.click()

        let downloadButton = app.buttons["setup.downloadButton"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 2))
        XCTAssertTrue(downloadButton.isEnabled)
    }

    func testUnsupportedParakeetAutoFallsBackToSmall() {
        let app = launchApp(env: [
            "SPEAK_UI_TEST_MODE": "1",
            "SPEAK_UI_MIC_STATUS": "authorized",
            "SPEAK_UI_AX_STATUS": "trusted",
            "SPEAK_UI_RUNTIME_STATUS": "unsupported",
            "SPEAK_UI_FORCE_NEEDS_SETUP": "1"
        ])

        let modelPicker = app.popUpButtons["setup.modelPicker"]
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 2))

        let fallbackNotice = app.staticTexts["setup.modelStatus"]
        XCTAssertTrue(fallbackNotice.waitForExistence(timeout: 2))
        waitForTextContains(fallbackNotice, text: "Small (Fallback)", timeout: 5)
        waitForValueContains(modelPicker, text: "Small", timeout: 5)
    }

    func testExistingUserLaunchDoesNotForceSetup() {
        let app = launchApp(env: [
            "SPEAK_UI_TEST_MODE": "1",
            "SPEAK_UI_MIC_STATUS": "authorized",
            "SPEAK_UI_AX_STATUS": "trusted",
            "SPEAK_UI_FORCE_NEEDS_SETUP": "0"
        ])

        let setupTitle = app.staticTexts["Set Up Speak"]
        XCTAssertFalse(setupTitle.waitForExistence(timeout: 1.5))
    }

    func testTransientTranscriptionFailureDoesNotReopenSetup() {
        let app = launchApp(env: [
            "SPEAK_UI_TEST_MODE": "1",
            "SPEAK_UI_MIC_STATUS": "authorized",
            "SPEAK_UI_AX_STATUS": "trusted",
            "SPEAK_UI_FORCE_NEEDS_SETUP": "0",
            "SPEAK_UI_SIMULATE_TRANSCRIPTION_ERROR": "parakeet network timeout"
        ])

        let setupTitle = app.staticTexts["Set Up Speak"]
        XCTAssertFalse(setupTitle.waitForExistence(timeout: 2.5))
    }

    func testRecoverableTranscriptionFailureReopensSetup() {
        let app = launchApp(env: [
            "SPEAK_UI_TEST_MODE": "1",
            "SPEAK_UI_MIC_STATUS": "authorized",
            "SPEAK_UI_AX_STATUS": "trusted",
            "SPEAK_UI_FORCE_NEEDS_SETUP": "0",
            "SPEAK_UI_SIMULATE_TRANSCRIPTION_ERROR": "parakeet could not locate downloaded parakeet model artifacts"
        ])

        let setupTitle = app.staticTexts["Set Up Speak"]
        XCTAssertTrue(setupTitle.waitForExistence(timeout: 3))
    }
}
