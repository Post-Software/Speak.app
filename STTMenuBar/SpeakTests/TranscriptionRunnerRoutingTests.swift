import XCTest
@testable import Speak

final class TranscriptionRunnerRoutingTests: XCTestCase {
    func testParakeetRoutesToRustWorker() {
        let manager = StubModelManager(
            activeModelID: ModelCatalog.parakeetTdtV3.id,
            activeModel: ModelCatalog.parakeetTdtV3,
            activeModelLocalPath: "/tmp/parakeet"
        )
        let python = StubPythonWorker()
        let rust = StubRustWorker()

        let runner = TranscriptionRunner(
            modelManager: manager,
            pythonWorker: python,
            rustWorker: rust,
            pythonRuntimeResolver: { (URL(fileURLWithPath: "/tmp/python"), URL(fileURLWithPath: "/tmp/transcribe.py")) },
            parakeetWorkerResolver: { URL(fileURLWithPath: "/tmp/parakeet-worker") }
        )

        let done = expectation(description: "transcribe done")
        runner.transcribe(audioURL: URL(fileURLWithPath: "/tmp/input.wav")) { result in
            if case .success = result {
                done.fulfill()
            }
        }

        wait(for: [done], timeout: 1)
        XCTAssertEqual(rust.transcribeCalls, 1)
        XCTAssertEqual(python.transcribeCalls, 0)
    }

    func testWhisperRoutesToPythonWorker() {
        let manager = StubModelManager(
            activeModelID: ModelCatalog.smallEN.id,
            activeModel: ModelCatalog.smallEN,
            activeModelLocalPath: "/tmp/whisper"
        )
        let python = StubPythonWorker()
        let rust = StubRustWorker()

        let runner = TranscriptionRunner(
            modelManager: manager,
            pythonWorker: python,
            rustWorker: rust,
            pythonRuntimeResolver: { (URL(fileURLWithPath: "/tmp/python"), URL(fileURLWithPath: "/tmp/transcribe.py")) },
            parakeetWorkerResolver: { URL(fileURLWithPath: "/tmp/parakeet-worker") }
        )

        let done = expectation(description: "transcribe done")
        runner.transcribe(audioURL: URL(fileURLWithPath: "/tmp/input.wav")) { result in
            if case .success = result {
                done.fulfill()
            }
        }

        wait(for: [done], timeout: 1)
        XCTAssertEqual(python.transcribeCalls, 1)
        XCTAssertEqual(rust.transcribeCalls, 0)
    }

    func testMissingModelReturnsSetupRequired() {
        let manager = StubModelManager(activeModelID: nil, activeModel: nil, activeModelLocalPath: nil)
        let runner = TranscriptionRunner(
            modelManager: manager,
            pythonWorker: StubPythonWorker(),
            rustWorker: StubRustWorker(),
            pythonRuntimeResolver: { (URL(fileURLWithPath: "/tmp/python"), URL(fileURLWithPath: "/tmp/transcribe.py")) },
            parakeetWorkerResolver: { URL(fileURLWithPath: "/tmp/parakeet-worker") }
        )

        let done = expectation(description: "transcribe done")
        runner.transcribe(audioURL: URL(fileURLWithPath: "/tmp/input.wav")) { result in
            switch result {
            case .failure(let error as TranscriptionRunner.RunnerError):
                XCTAssertEqual(error, .modelSetupRequired)
                done.fulfill()
            default:
                XCTFail("Expected modelSetupRequired")
            }
        }

        wait(for: [done], timeout: 1)
    }
}
