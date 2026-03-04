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

    private func makeEmptyAppSupportFixture() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speak-ui-test-\(UUID().uuidString)", isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root.path
    }

    private func makeAppSupportFixtureForDownloadedParakeet() throws -> String {
        let root = URL(fileURLWithPath: try makeEmptyAppSupportFixture(), isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        let modelDir = models.appendingPathComponent("parakeet_tdt_0_6b_v3", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        let manifest = """
        {
          "activeModelID": "parakeet_tdt_0_6b_v3",
          "installed": [],
          "lastKnownModelSizes": {
            "parakeet_tdt_0_6b_v3": 478517071
          }
        }
        """
        try manifest.write(to: models.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        return root.path
    }

    func testSetupRendersDefaultParakeetAndAllModelOptions() throws {
        let fixtureRoot = try makeEmptyAppSupportFixture()
        let app = launchApp(env: [
            "SPEAK_UI_TEST_MODE": "1",
            "SPEAK_UI_MIC_STATUS": "authorized",
            "SPEAK_UI_AX_STATUS": "trusted",
            "SPEAK_UI_RUNTIME_STATUS": "ok",
            "SPEAK_UI_FORCE_NEEDS_SETUP": "1",
            "SPEAK_TEST_APP_SUPPORT_DIR": fixtureRoot
        ])

        let modelPicker = app.popUpButtons["setup.modelPicker"]
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 2))
        waitForValueContains(modelPicker, text: "Parakeet v3")

        let description = app.staticTexts["setup.modelDescription"]
        XCTAssertTrue(description.exists)
        waitForTextContains(description, text: "Fast")
        waitForTextContains(description, text: "Small")
    }

    func testBlockedPermissionsKeepDownloadDisabled() throws {
        let fixtureRoot = try makeEmptyAppSupportFixture()
        let app = launchApp(env: [
            "SPEAK_UI_TEST_MODE": "1",
            "SPEAK_UI_MIC_STATUS": "denied",
            "SPEAK_UI_AX_STATUS": "blocked",
            "SPEAK_UI_FORCE_NEEDS_SETUP": "1",
            "SPEAK_TEST_APP_SUPPORT_DIR": fixtureRoot
        ])

        let downloadButton = app.buttons["setup.downloadButton"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 2))
        XCTAssertFalse(downloadButton.isEnabled)
    }

    func testDownloadEnablesWhenPermissionsGrantedAndConsentChecked() throws {
        let fixtureRoot = try makeEmptyAppSupportFixture()
        let app = launchApp(env: [
            "SPEAK_UI_TEST_MODE": "1",
            "SPEAK_UI_MIC_STATUS": "authorized",
            "SPEAK_UI_AX_STATUS": "trusted",
            "SPEAK_UI_RUNTIME_STATUS": "ok",
            "SPEAK_UI_FORCE_NEEDS_SETUP": "1",
            "SPEAK_TEST_APP_SUPPORT_DIR": fixtureRoot
        ])

        let consent = app.checkBoxes["setup.consentCheckbox"]
        XCTAssertTrue(consent.waitForExistence(timeout: 2))
        consent.click()

        let downloadButton = app.buttons["setup.downloadButton"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 2))
        XCTAssertTrue(downloadButton.isEnabled)
    }

    func testUnsupportedParakeetAutoFallsBackToSmall() throws {
        let fixtureRoot = try makeEmptyAppSupportFixture()
        let app = launchApp(env: [
            "SPEAK_UI_TEST_MODE": "1",
            "SPEAK_UI_MIC_STATUS": "authorized",
            "SPEAK_UI_AX_STATUS": "trusted",
            "SPEAK_UI_RUNTIME_STATUS": "unsupported",
            "SPEAK_UI_FORCE_NEEDS_SETUP": "1",
            "SPEAK_TEST_APP_SUPPORT_DIR": fixtureRoot
        ])

        let modelPicker = app.popUpButtons["setup.modelPicker"]
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 2))
        waitForValueContains(modelPicker, text: "Small", timeout: 5)
    }

    func testAlreadyDownloadedModelShowsDownloadedStateInSetup() throws {
        let fixtureRoot = try makeAppSupportFixtureForDownloadedParakeet()
        let app = launchApp(env: [
            "SPEAK_UI_TEST_MODE": "1",
            "SPEAK_UI_MIC_STATUS": "authorized",
            "SPEAK_UI_AX_STATUS": "trusted",
            "SPEAK_UI_FORCE_NEEDS_SETUP": "1",
            "SPEAK_TEST_APP_SUPPORT_DIR": fixtureRoot
        ])

        let status = app.staticTexts["setup.modelStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 2))
        waitForTextContains(status, text: "Downloaded", timeout: 5)

        let downloadButton = app.buttons["setup.downloadButton"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 2))
        XCTAssertFalse(downloadButton.isEnabled)
    }

    func testExistingUserLaunchDoesNotForceSetup() throws {
        let fixtureRoot = try makeEmptyAppSupportFixture()
        let app = launchApp(env: [
            "SPEAK_UI_TEST_MODE": "1",
            "SPEAK_UI_MIC_STATUS": "authorized",
            "SPEAK_UI_AX_STATUS": "trusted",
            "SPEAK_UI_FORCE_NEEDS_SETUP": "0",
            "SPEAK_TEST_APP_SUPPORT_DIR": fixtureRoot
        ])

        let setupTitle = app.staticTexts["Set Up Speak"]
        XCTAssertFalse(setupTitle.waitForExistence(timeout: 1.5))
    }

    func testTransientTranscriptionFailureDoesNotReopenSetup() throws {
        let fixtureRoot = try makeEmptyAppSupportFixture()
        let app = launchApp(env: [
            "SPEAK_UI_TEST_MODE": "1",
            "SPEAK_UI_MIC_STATUS": "authorized",
            "SPEAK_UI_AX_STATUS": "trusted",
            "SPEAK_UI_FORCE_NEEDS_SETUP": "0",
            "SPEAK_UI_SIMULATE_TRANSCRIPTION_ERROR": "parakeet network timeout",
            "SPEAK_TEST_APP_SUPPORT_DIR": fixtureRoot
        ])

        let setupTitle = app.staticTexts["Set Up Speak"]
        XCTAssertFalse(setupTitle.waitForExistence(timeout: 2.5))
    }

    func testRecoverableTranscriptionFailureReopensSetup() throws {
        let fixtureRoot = try makeEmptyAppSupportFixture()
        let app = launchApp(env: [
            "SPEAK_UI_TEST_MODE": "1",
            "SPEAK_UI_MIC_STATUS": "authorized",
            "SPEAK_UI_AX_STATUS": "trusted",
            "SPEAK_UI_FORCE_NEEDS_SETUP": "0",
            "SPEAK_UI_SIMULATE_TRANSCRIPTION_ERROR": "parakeet could not locate downloaded parakeet model artifacts",
            "SPEAK_TEST_APP_SUPPORT_DIR": fixtureRoot
        ])

        let setupTitle = app.staticTexts["Set Up Speak"]
        XCTAssertTrue(setupTitle.waitForExistence(timeout: 3))
    }
}
