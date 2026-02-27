import Foundation

protocol PythonWorkerServing: AnyObject {
    func stop()
    func transcribe(
        pythonURL: URL,
        scriptURL: URL,
        modelID: String,
        modelPath: String,
        audioPath: String,
        computeType: String,
        additionalPythonPaths: [String],
        completion: @escaping (Result<String, Error>) -> Void
    )
    func prewarm(
        pythonURL: URL,
        scriptURL: URL,
        modelID: String,
        modelPath: String,
        computeType: String,
        additionalPythonPaths: [String]
    )
}

protocol RustWorkerServing: AnyObject {
    func stop()
    func transcribe(
        workerURL: URL,
        modelID: String,
        modelPath: String,
        audioPath: String,
        completion: @escaping (Result<String, Error>) -> Void
    )
    func prewarm(workerURL: URL, modelID: String, modelPath: String)
}

final class TranscriptionRunner {
    enum RunnerError: LocalizedError, Equatable {
        case bundledRuntimeMissing
        case parakeetWorkerMissing
        case modelSetupRequired

        var errorDescription: String? {
            switch self {
            case .bundledRuntimeMissing:
                return "Bundled transcription runtime is missing from Speak.app. Please reinstall Speak."
            case .parakeetWorkerMissing:
                return "Bundled Parakeet worker is missing from Speak.app. Please reinstall Speak."
            case .modelSetupRequired:
                return "No model is installed yet. Complete setup before recording."
            }
        }
    }

    private let settings: Settings
    private let modelManager: ModelManaging
    private let pythonWorker: PythonWorkerServing
    private let rustWorker: RustWorkerServing
    private let pythonRuntimeResolver: (() throws -> (pythonURL: URL, scriptURL: URL))?
    private let parakeetWorkerResolver: (() throws -> URL)?

    init(
        settings: Settings = .shared,
        modelManager: ModelManaging = ModelManager.shared,
        pythonWorker: PythonWorkerServing = PythonWorker(),
        rustWorker: RustWorkerServing = RustWorker(),
        pythonRuntimeResolver: (() throws -> (pythonURL: URL, scriptURL: URL))? = nil,
        parakeetWorkerResolver: (() throws -> URL)? = nil
    ) {
        self.settings = settings
        self.modelManager = modelManager
        self.pythonWorker = pythonWorker
        self.rustWorker = rustWorker
        self.pythonRuntimeResolver = pythonRuntimeResolver
        self.parakeetWorkerResolver = parakeetWorkerResolver
    }

    private var forcePythonParakeet: Bool {
        ProcessInfo.processInfo.environment["SPEAK_FORCE_PYTHON_PARAKEET"] == "1"
    }

    func cancel() {
        pythonWorker.stop()
        rustWorker.stop()
    }

    func prewarm() {
        guard let activeModel = modelManager.activeModel,
              let modelPath = modelManager.activeModelLocalPath else { return }

        if activeModel.engine == .parakeetTDTV3 && !forcePythonParakeet {
            let workerURL: URL
            if let resolver = parakeetWorkerResolver {
                guard let resolved = try? resolver() else { return }
                workerURL = resolved
            } else {
                guard let resolved = try? resolveParakeetWorker() else { return }
                workerURL = resolved
            }
            rustWorker.prewarm(
                workerURL: workerURL,
                modelID: activeModel.id,
                modelPath: modelPath
            )
            return
        }

        let runtime: (pythonURL: URL, scriptURL: URL)
        if let resolver = pythonRuntimeResolver {
            guard let resolved = try? resolver() else { return }
            runtime = resolved
        } else {
            guard let resolved = try? resolvePythonRuntimePaths() else { return }
            runtime = resolved
        }
        let additionalPythonPaths = modelManager.additionalPythonPaths(for: activeModel.id)
        pythonWorker.prewarm(
            pythonURL: runtime.pythonURL,
            scriptURL: runtime.scriptURL,
            modelID: activeModel.id,
            modelPath: modelPath,
            computeType: settings.computeType,
            additionalPythonPaths: additionalPythonPaths
        )
    }

    func transcribe(audioURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        guard let activeModel = modelManager.activeModel,
              let modelPath = modelManager.activeModelLocalPath else {
            completion(.failure(RunnerError.modelSetupRequired))
            return
        }

        if activeModel.engine == .parakeetTDTV3 && !forcePythonParakeet {
            let workerURL: URL
            do {
                if let resolver = parakeetWorkerResolver {
                    workerURL = try resolver()
                } else {
                    workerURL = try resolveParakeetWorker()
                }
            } catch {
                completion(.failure(error))
                return
            }

            rustWorker.transcribe(
                workerURL: workerURL,
                modelID: activeModel.id,
                modelPath: modelPath,
                audioPath: audioURL.path,
                completion: completion
            )
            return
        }

        let additionalPythonPaths = modelManager.additionalPythonPaths(for: activeModel.id)

        let runtime: (pythonURL: URL, scriptURL: URL)
        do {
            if let resolver = pythonRuntimeResolver {
                runtime = try resolver()
            } else {
                runtime = try resolvePythonRuntimePaths()
            }
        } catch {
            completion(.failure(error))
            return
        }

        pythonWorker.transcribe(
            pythonURL: runtime.pythonURL,
            scriptURL: runtime.scriptURL,
            modelID: activeModel.id,
            modelPath: modelPath,
            audioPath: audioURL.path,
            computeType: settings.computeType,
            additionalPythonPaths: additionalPythonPaths,
            completion: completion
        )
    }

    private func resolvePythonRuntimePaths() throws -> (pythonURL: URL, scriptURL: URL) {
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

    private func resolveParakeetWorker() throws -> URL {
        if let resourcesURL = Bundle.main.resourceURL {
            let bundledWorker = resourcesURL.appendingPathComponent("parakeet-worker")
            if FileManager.default.isExecutableFile(atPath: bundledWorker.path) {
                return bundledWorker
            }
        }

        #if DEBUG
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let debugWorker = cwd
            .appendingPathComponent("rust/parakeet-worker/target/release/parakeet-worker")
        if FileManager.default.isExecutableFile(atPath: debugWorker.path) {
            return debugWorker
        }

        let altWorker = cwd
            .appendingPathComponent("rust/target/parakeet-worker/release/parakeet-worker")
        if FileManager.default.isExecutableFile(atPath: altWorker.path) {
            return altWorker
        }
        #endif

        throw RunnerError.parakeetWorkerMissing
    }
}

private final class RustWorker: RustWorkerServing {
    private let queue = DispatchQueue(label: "speak.rust.worker")
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var buffer = Data()
    private var currentCompletion: ((Result<String, Error>) -> Void)?
    private var timeoutTimer: DispatchSourceTimer?
    private var lastStderr = ""

    func stop() {
        queue.async {
            self.stopOnQueue(clearCompletion: true)
        }
    }

    func transcribe(
        workerURL: URL,
        modelID: String,
        modelPath: String,
        audioPath: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        queue.async {
            if self.currentCompletion != nil {
                self.stopOnQueue(clearCompletion: true)
            }

            if self.process?.isRunning != true {
                do {
                    try self.startWorker(workerURL: workerURL, modelID: modelID, modelPath: modelPath)
                } catch {
                    completion(.failure(error))
                    return
                }
            }

            self.currentCompletion = completion
            self.sendRequestOnQueue(audioPath: audioPath)
            self.startTimeoutOnQueue()
        }
    }

    func prewarm(workerURL: URL, modelID: String, modelPath: String) {
        queue.async {
            if self.process?.isRunning == true { return }
            do {
                try self.startWorker(workerURL: workerURL, modelID: modelID, modelPath: modelPath)
            } catch {
                // Ignore prewarm failures; transcription will surface errors later.
            }
        }
    }

    private func startWorker(workerURL: URL, modelID: String, modelPath: String) throws {
        let newProcess = Process()
        newProcess.executableURL = workerURL
        newProcess.arguments = [
            "--worker",
            "--model-id", modelID,
            "--model", modelPath
        ]

        if let resourcesURL = Bundle.main.resourceURL {
            newProcess.currentDirectoryURL = resourcesURL
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        newProcess.standardInput = stdinPipe
        newProcess.standardOutput = stdoutPipe
        newProcess.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            self?.queue.async {
                self?.handleStdoutOnQueue(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            self?.queue.async {
                if let text = String(data: data, encoding: .utf8) {
                    self?.lastStderr.append(text)
                }
            }
        }

        newProcess.terminationHandler = { [weak self] proc in
            self?.queue.async {
                self?.handleTerminationOnQueue(proc)
            }
        }

        try newProcess.run()
        self.process = newProcess
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.stderrHandle = stderrPipe.fileHandleForReading
        self.buffer.removeAll()
        self.lastStderr = ""
        NSLog(
            "RustWorker: started pid=%d modelID=%@ modelPath=%@",
            newProcess.processIdentifier,
            modelID,
            modelPath
        )
    }

    private func sendRequestOnQueue(audioPath: String) {
        guard process?.isRunning == true else {
            finishOnQueue(.failure(NSError(domain: "Transcription", code: -4, userInfo: [NSLocalizedDescriptionKey: "Parakeet worker not running."])))
            return
        }

        let request: [String: String] = ["audio": audioPath]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              var line = String(data: data, encoding: .utf8) else {
            finishOnQueue(.failure(NSError(domain: "Transcription", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode request"])))
            return
        }

        line.append("\n")
        guard let bytes = line.data(using: .utf8) else {
            finishOnQueue(.failure(NSError(domain: "Transcription", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode request"])))
            return
        }

        do {
            try stdinHandle?.write(contentsOf: bytes)
        } catch {
            let message = "Failed to send transcription request to Parakeet worker: \(error.localizedDescription)"
            stopOnQueue(clearCompletion: false)
            finishOnQueue(.failure(NSError(domain: "Transcription", code: -6, userInfo: [NSLocalizedDescriptionKey: message])))
        }
    }

    private func handleStdoutOnQueue(_ data: Data) {
        buffer.append(data)
        while let range = buffer.range(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0...range.lowerBound)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            handleResponseLineOnQueue(line)
        }
    }

    private func handleResponseLineOnQueue(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            finishOnQueue(.failure(NSError(domain: "Transcription", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])))
            return
        }

        if let ok = json["ok"] as? Bool, ok {
            let text = (json["text"] as? String) ?? ""
            finishOnQueue(.success(text))
        } else {
            let message = (json["error"] as? String) ?? "Unknown error"
            finishOnQueue(.failure(NSError(domain: "Transcription", code: -3, userInfo: [NSLocalizedDescriptionKey: message])))
        }
    }

    private func finishOnQueue(_ result: Result<String, Error>) {
        timeoutTimer?.cancel()
        timeoutTimer = nil
        let completion = currentCompletion
        currentCompletion = nil
        guard completion != nil else { return }
        DispatchQueue.main.async {
            completion?(result)
        }
    }

    private func startTimeoutOnQueue() {
        timeoutTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 120)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            NSLog("RustWorker: timed out waiting for transcription response.")
            self.stopOnQueue(clearCompletion: false)
            self.finishOnQueue(.failure(NSError(domain: "Transcription", code: -5, userInfo: [NSLocalizedDescriptionKey: "Transcription timed out."])))
        }
        timeoutTimer = timer
        timer.resume()
    }

    private func stopOnQueue(clearCompletion: Bool) {
        timeoutTimer?.cancel()
        timeoutTimer = nil
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        if let process {
            process.terminationHandler = nil
            if process.isRunning {
                process.terminate()
            }
        }
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        process = nil
        buffer.removeAll()
        lastStderr = ""
        if clearCompletion {
            currentCompletion = nil
        }
    }

    private func handleTerminationOnQueue(_ terminatedProcess: Process) {
        if let currentProcess = process, currentProcess !== terminatedProcess {
            return
        }

        NSLog(
            "RustWorker: worker terminated status=%d reason=%@",
            terminatedProcess.terminationStatus,
            terminatedProcess.terminationReason == .uncaughtSignal ? "signal" : "exit"
        )

        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        process = nil
        timeoutTimer?.cancel()
        timeoutTimer = nil
        buffer.removeAll()

        guard currentCompletion != nil else {
            lastStderr = ""
            return
        }

        var message = lastStderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            message = "Parakeet worker exited unexpectedly."
        }
        lastStderr = ""

        finishOnQueue(.failure(NSError(domain: "Transcription", code: Int(terminatedProcess.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])))
    }
}
