import XCTest
import AVFoundation
@testable import Speak

@MainActor
final class SetupWizardModelSelectionTests: XCTestCase {
    private func pumpRunLoop(seconds: TimeInterval = 0.2) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            RunLoop.main.run(mode: .default, before: until)
        }
    }

    func testFreshStateDefaultsToParakeet() {
        let permissions = StubPermissionCoordinator(micStatus: .denied, axTrusted: false)
        let manager = StubModelManager(activeModelID: nil)

        let controller = SetupWizardWindowController(permissionCoordinator: permissions, modelManager: manager)
        XCTAssertEqual(controller.testSelectedModelID, ModelCatalog.parakeetTdtV3.id)
    }

    func testExistingActiveModelStaysSelected() {
        let permissions = StubPermissionCoordinator(micStatus: .denied, axTrusted: false)
        let manager = StubModelManager(activeModelID: ModelCatalog.mediumEN.id)

        let controller = SetupWizardWindowController(permissionCoordinator: permissions, modelManager: manager)
        XCTAssertEqual(controller.testSelectedModelID, ModelCatalog.mediumEN.id)
    }

    func testPermissionGateKeepsDownloadDisabledUntilRequirementsMet() {
        let blockedPermissions = StubPermissionCoordinator(micStatus: .denied, axTrusted: false)
        let manager = StubModelManager(activeModelID: nil)

        let blockedController = SetupWizardWindowController(permissionCoordinator: blockedPermissions, modelManager: manager)
        blockedController.refreshState()
        XCTAssertFalse(blockedController.testDownloadButtonEnabled)

        let grantedPermissions = StubPermissionCoordinator(micStatus: .authorized, axTrusted: true)
        let grantedController = SetupWizardWindowController(permissionCoordinator: grantedPermissions, modelManager: manager)
        grantedController.refreshState()
        pumpRunLoop()

        grantedController.testSetConsent(agreed: true)
        XCTAssertTrue(grantedController.testDownloadButtonEnabled)
    }

    func testParakeetUnsupportedFallsBackToSmall() {
        let permissions = StubPermissionCoordinator(micStatus: .authorized, axTrusted: true)
        let manager = StubModelManager(activeModelID: nil)
        manager.runtimeResults[ModelCatalog.parakeetTdtV3.id] = RuntimeSupportInfo(
            modelID: ModelCatalog.parakeetTdtV3.id,
            supported: false,
            status: "unsupported",
            reason: "No supported provider",
            requiresInstall: false
        )

        let controller = SetupWizardWindowController(permissionCoordinator: permissions, modelManager: manager)
        controller.refreshState()
        pumpRunLoop(seconds: 0.3)

        XCTAssertEqual(controller.testSelectedModelID, ModelCatalog.smallEN.id)
        XCTAssertTrue(controller.testModelStatusText.contains("Small (Fallback)"))
    }
}
