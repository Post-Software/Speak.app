import Foundation

final class TranscriptionRunner {
    enum RunnerError: LocalizedError {
        case bundledRuntimeMissing
        case modelSetupRequired

        var errorDescription: String? {
            switch self {
            case .bundledRuntimeMissing:
                return "Bundled transcription runtime is missing from Speak.app. Please reinstall Speak."
            case .modelSetupRequired:
                return "No model is installed yet. Complete setup before recording."
            }
        }
    }

    private let settings = Settings.shared
    private let modelManager = ModelManager.shared
    private let worker = PythonWorker()

    func cancel() {
        worker.stop()
    }

    func prewarm() {
        guard let modelPath = modelManager.activeModelLocalPath else { return }
        guard let runtime = try? resolveRuntimePaths() else { return }

        worker.prewarm(
            pythonURL: runtime.pythonURL,
            scriptURL: runtime.scriptURL,
            modelPath: modelPath,
            computeType: settings.computeType
        )
    }

    func transcribe(audioURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        guard let modelPath = modelManager.activeModelLocalPath else {
            completion(.failure(RunnerError.modelSetupRequired))
            return
        }

        let runtime: (pythonURL: URL, scriptURL: URL)
        do {
            runtime = try resolveRuntimePaths()
        } catch {
            completion(.failure(error))
            return
        }

        worker.transcribe(
            pythonURL: runtime.pythonURL,
            scriptURL: runtime.scriptURL,
            modelPath: modelPath,
            audioPath: audioURL.path,
            computeType: settings.computeType,
            completion: completion
        )
    }

    private func resolveRuntimePaths() throws -> (pythonURL: URL, scriptURL: URL) {
        if let resourcesURL = Bundle.main.resourceURL {
            let bundledPython = resourcesURL.appendingPathComponent("python/bin/python")
            let bundledScript = resourcesURL.appendingPathComponent("python/transcribe.py")
            if FileManager.default.fileExists(atPath: bundledPython.path),
               FileManager.default.fileExists(atPath: bundledScript.path) {
                return (bundledPython, bundledScript)
            }
        }

        #if DEBUG
        let pythonURL = URL(fileURLWithPath: settings.pythonPath)
        let scriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/python/transcribe.py")
        if FileManager.default.fileExists(atPath: pythonURL.path),
           FileManager.default.fileExists(atPath: scriptURL.path) {
            return (pythonURL, scriptURL)
        }
        #endif

        throw RunnerError.bundledRuntimeMissing
    }
}
