import Foundation

final class TranscriptionRunner {
    private let settings = Settings.shared
    private let bundledModelRelativePath = "models/medium"
    private let worker = PythonWorker()

    func cancel() {
        worker.stop()
    }

    func prewarm() {
        let resolved = resolveBundledPaths()
        worker.prewarm(
            pythonURL: resolved.pythonURL,
            scriptURL: resolved.scriptURL,
            modelPath: resolved.modelPath,
            computeType: settings.computeType
        )
    }

    func transcribe(audioURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        let resolved = resolveBundledPaths()
        worker.transcribe(
            pythonURL: resolved.pythonURL,
            scriptURL: resolved.scriptURL,
            modelPath: resolved.modelPath,
            audioPath: audioURL.path,
            computeType: settings.computeType,
            completion: completion
        )
    }

    private func resolveBundledPaths() -> (pythonURL: URL, scriptURL: URL, modelPath: String) {
        if let resourcesURL = Bundle.main.resourceURL {
            let bundledPython = resourcesURL.appendingPathComponent("python/bin/python")
            let bundledScript = resourcesURL.appendingPathComponent("python/transcribe.py")
            let bundledModel = resourcesURL.appendingPathComponent(bundledModelRelativePath)
            if FileManager.default.fileExists(atPath: bundledPython.path),
               FileManager.default.fileExists(atPath: bundledScript.path),
               FileManager.default.fileExists(atPath: bundledModel.path) {
                return (bundledPython, bundledScript, bundledModel.path)
            }
        }

        // Fallback for development runs outside a bundled app.
        let pythonURL = URL(fileURLWithPath: settings.pythonPath)
        let scriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/python/transcribe.py")
        let projectModelPath = FileManager.default.currentDirectoryPath + "/models/medium"
        let modelPath = FileManager.default.fileExists(atPath: projectModelPath) ? projectModelPath : settings.modelName
        return (pythonURL, scriptURL, modelPath)
    }
}
