import Foundation

final class TranscriptionRunner {
    enum RunnerError: LocalizedError {
        case modelSetupRequired

        var errorDescription: String? {
            switch self {
            case .modelSetupRequired:
                return "No model is configured yet. Open Model setup and download a model first."
            }
        }
    }

    private let modelManager = ModelManager.shared
    private let worker = TranscriberProcess()

    var onWorkerReady: ((TranscriberProcess.WorkerReady) -> Void)? {
        didSet {
            worker.onWorkerReady = onWorkerReady
        }
    }

    func cancel() {
        worker.stop()
    }

    func prewarm() {
        guard let active = modelManager.activeModel else { return }
        _ = try? worker.ensureWorker(modelID: active.id, modelsRoot: modelManager.modelsRootURL)
    }

    func transcribe(audioURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        guard let active = modelManager.activeModel,
              modelManager.isInstalled(modelID: active.id) else {
            completion(.failure(RunnerError.modelSetupRequired))
            return
        }

        do {
            let ready = try worker.ensureWorker(modelID: active.id, modelsRoot: modelManager.modelsRootURL)
            modelManager.updateBackendState(backend: ready.backend, fallbackReason: ready.fallbackReason)
        } catch {
            completion(.failure(error))
            return
        }

        worker.transcribe(audioPath: audioURL.path, completion: completion)
    }
}
