import XCTest
@testable import Speak

final class ModelManagerRuntimeTests: XCTestCase {
    func testRuntimeSupportInfoParsesExpectedFields() {
        let whisperPayload: [String: Any] = [
            "model_id": "whisper_medium_en",
            "supported": true,
            "status": "ok",
            "reason": "",
            "requires_install": false
        ]

        let parakeetPayload: [String: Any] = [
            "model_id": "parakeet_tdt_0_6b_v3",
            "supported": false,
            "status": "missing_runtime",
            "reason": "runtime deps missing",
            "requires_install": true
        ]

        let whisper = ModelManager.runtimeSupportInfo(from: whisperPayload, fallbackModelID: "fallback")
        let parakeet = ModelManager.runtimeSupportInfo(from: parakeetPayload, fallbackModelID: "fallback")

        XCTAssertEqual(whisper.modelID, "whisper_medium_en")
        XCTAssertTrue(whisper.supported)
        XCTAssertEqual(whisper.status, "ok")
        XCTAssertFalse(whisper.requiresInstall)

        XCTAssertEqual(parakeet.modelID, "parakeet_tdt_0_6b_v3")
        XCTAssertFalse(parakeet.supported)
        XCTAssertEqual(parakeet.status, "missing_runtime")
        XCTAssertEqual(parakeet.reason, "runtime deps missing")
        XCTAssertTrue(parakeet.requiresInstall)
    }

    func testCompactCommandFailureMessageStripsNoise() {
        let raw = """
        Fetching 5 files: 80%|██████|
        Warning: You are sending unauthenticated requests to the HF Hub
        /path/huggingface_hub/utils/_validators.py: UserWarning: local_dir_use_symlinks ignored
        ERROR: Could not locate downloaded Parakeet model artifacts.
        """

        let message = ModelManager.compactCommandFailureMessage(raw)
        XCTAssertTrue(message.contains("Could not locate downloaded Parakeet model artifacts"))
        XCTAssertFalse(message.contains("Fetching 5 files"))
        XCTAssertFalse(message.contains("HF Hub"))
        XCTAssertFalse(message.contains("local_dir_use_symlinks"))
    }

    func testInstallFailureKeepsExistingActiveModel() {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("speak-tests-\(UUID().uuidString)", isDirectory: true)
        let modelsDir = tempRoot.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let manifestURL = modelsDir.appendingPathComponent("manifest.json")
        let manifestJSON = """
        {
          "activeModelID": "whisper_medium_en",
          "installed": [],
          "lastKnownModelSizes": {}
        }
        """
        try? manifestJSON.data(using: .utf8)?.write(to: manifestURL)

        let env: [String: String] = [
            "SPEAK_UI_TEST_MODE": "1",
            "SPEAK_UI_INSTALL_RESULT": "fail",
            "SPEAK_TEST_APP_SUPPORT_DIR": tempRoot.path
        ]
        let manager = ModelManager(environment: env)

        let failed = expectation(description: "install fails")
        manager.installModel(variant: ModelCatalog.smallEN) { result in
            if case .failure = result {
                failed.fulfill()
            }
        }
        wait(for: [failed], timeout: 1)

        XCTAssertEqual(manager.manifest.activeModelID, "whisper_medium_en")
        try? FileManager.default.removeItem(at: tempRoot)
    }
}
