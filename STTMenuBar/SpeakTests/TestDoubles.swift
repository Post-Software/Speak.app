import Foundation
import AVFoundation
@testable import Speak

final class StubPermissionCoordinator: PermissionCoordinating {
    var micStatus: AVAuthorizationStatus
    var axTrusted: Bool

    init(micStatus: AVAuthorizationStatus, axTrusted: Bool) {
        self.micStatus = micStatus
        self.axTrusted = axTrusted
    }

    func hasAllRequiredPermissions() -> Bool {
        micStatus == .authorized && axTrusted
    }

    var microphoneStatus: AVAuthorizationStatus { micStatus }

    var accessibilityTrusted: Bool { axTrusted }

    func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        completion(micStatus == .authorized)
    }

    func requestAccessibilityAccess() {}

    func openMicrophoneSettings() {}

    func openAccessibilitySettings() {}
}

final class StubModelManager: ModelManaging {
    var manifest: ModelManager.Manifest
    var activeModel: ModelVariant?
    var activeModelLocalPath: String?
    var additionalPaths: [String] = []
    var needsSetupValue = true

    var runtimeResults: [String: RuntimeSupportInfo] = [:]
    var remoteInfoResults: [String: RemoteModelInfo] = [:]
    var installResult: Result<Void, Error> = .success(())

    init(
        activeModelID: String? = nil,
        activeModel: ModelVariant? = nil,
        activeModelLocalPath: String? = nil,
        needsSetup: Bool = true
    ) {
        self.manifest = .init(activeModelID: activeModelID, installed: [], lastKnownModelSizes: [:])
        self.activeModel = activeModel
        self.activeModelLocalPath = activeModelLocalPath
        self.needsSetupValue = needsSetup
    }

    func additionalPythonPaths(for modelID: String) -> [String] {
        additionalPaths
    }

    func needsSetup() -> Bool {
        needsSetupValue
    }

    func checkRuntime(for variant: ModelVariant, completion: @escaping (Result<RuntimeSupportInfo, Error>) -> Void) {
        if let result = runtimeResults[variant.id] {
            DispatchQueue.main.async {
                completion(.success(result))
            }
            return
        }

        let supported = RuntimeSupportInfo(
            modelID: variant.id,
            supported: true,
            status: "ok",
            reason: "",
            requiresInstall: false
        )
        DispatchQueue.main.async {
            completion(.success(supported))
        }
    }

    func fetchRemoteInfo(for variant: ModelVariant, completion: @escaping (Result<RemoteModelInfo, Error>) -> Void) {
        let info = remoteInfoResults[variant.id] ?? RemoteModelInfo(
            id: variant.id,
            repo: variant.sourceRepo,
            displayName: variant.displayName,
            downloadBytes: 1_000_000,
            sizeSource: .fallback
        )

        DispatchQueue.main.async {
            completion(.success(info))
        }
    }

    func installModel(variant: ModelVariant, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.main.async {
            completion(self.installResult)
        }
    }
}

final class StubPythonWorker: PythonWorkerServing {
    var transcribeCalls = 0
    var prewarmCalls = 0
    var lastModelID: String?
    var transcribeResult: Result<String, Error> = .success("python")

    func stop() {}

    func transcribe(
        pythonURL: URL,
        scriptURL: URL,
        modelID: String,
        modelPath: String,
        audioPath: String,
        computeType: String,
        additionalPythonPaths: [String],
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        transcribeCalls += 1
        lastModelID = modelID
        completion(transcribeResult)
    }

    func prewarm(
        pythonURL: URL,
        scriptURL: URL,
        modelID: String,
        modelPath: String,
        computeType: String,
        additionalPythonPaths: [String]
    ) {
        prewarmCalls += 1
        lastModelID = modelID
    }
}

final class StubRustWorker: RustWorkerServing {
    var transcribeCalls = 0
    var prewarmCalls = 0
    var lastModelID: String?
    var transcribeResult: Result<String, Error> = .success("rust")

    func stop() {}

    func transcribe(
        workerURL: URL,
        modelID: String,
        modelPath: String,
        audioPath: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        transcribeCalls += 1
        lastModelID = modelID
        completion(transcribeResult)
    }

    func prewarm(workerURL: URL, modelID: String, modelPath: String) {
        prewarmCalls += 1
        lastModelID = modelID
    }
}

final class StubUpdateController: UpdateChecking {
    var canCheckForUpdates = true
    var checkForUpdatesCalls = 0

    func checkForUpdates() {
        checkForUpdatesCalls += 1
    }
}
