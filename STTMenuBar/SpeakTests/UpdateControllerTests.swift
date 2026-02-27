import XCTest
@testable import Speak

@MainActor
final class UpdateControllerTests: XCTestCase {
    func testUpdateControllerInitializes() {
        let controller = UpdateController()
        XCTAssertNotNil(controller)
    }

    func testManualCheckInvokesUpdateController() {
        let permissionCoordinator = StubPermissionCoordinator(micStatus: .authorized, axTrusted: true)
        let modelManager = StubModelManager(activeModelID: nil, activeModel: nil, activeModelLocalPath: nil, needsSetup: true)
        let runner = TranscriptionRunner(
            modelManager: modelManager,
            pythonWorker: StubPythonWorker(),
            rustWorker: StubRustWorker(),
            pythonRuntimeResolver: { (URL(fileURLWithPath: "/tmp/python"), URL(fileURLWithPath: "/tmp/transcribe.py")) },
            parakeetWorkerResolver: { URL(fileURLWithPath: "/tmp/parakeet-worker") }
        )
        let updateController = StubUpdateController()

        let appDelegate = AppDelegate(
            permissionCoordinator: permissionCoordinator,
            modelManager: modelManager,
            transcriptionRunner: runner,
            updateController: updateController
        )

        appDelegate.checkForAppUpdates()
        XCTAssertEqual(updateController.checkForUpdatesCalls, 1)
    }

    func testStatusMenuContainsCheckForUpdatesItem() {
        let permissionCoordinator = StubPermissionCoordinator(micStatus: .authorized, axTrusted: true)
        let modelManager = StubModelManager(activeModelID: nil, activeModel: nil, activeModelLocalPath: nil, needsSetup: true)
        let runner = TranscriptionRunner(
            modelManager: modelManager,
            pythonWorker: StubPythonWorker(),
            rustWorker: StubRustWorker(),
            pythonRuntimeResolver: { (URL(fileURLWithPath: "/tmp/python"), URL(fileURLWithPath: "/tmp/transcribe.py")) },
            parakeetWorkerResolver: { URL(fileURLWithPath: "/tmp/parakeet-worker") }
        )
        let updateController = StubUpdateController()

        let appDelegate = AppDelegate(
            permissionCoordinator: permissionCoordinator,
            modelManager: modelManager,
            transcriptionRunner: runner,
            updateController: updateController
        )

        let menu = appDelegate.buildStatusMenu()
        let hasItem = menu.items.contains { $0.title == "Check for Updates..." }
        XCTAssertTrue(hasItem)
    }
}
