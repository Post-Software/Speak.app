import Foundation

final class PythonWorker: PythonWorkerServing {
    private let queue = DispatchQueue(label: "speak.python.worker")
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
        pythonURL: URL,
        scriptURL: URL,
        modelID: String,
        modelPath: String,
        audioPath: String,
        computeType: String,
        additionalPythonPaths: [String],
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        queue.async {
            if self.currentCompletion != nil {
                self.stopOnQueue(clearCompletion: true)
            }

            if self.process?.isRunning != true {
                do {
                    try self.startWorker(
                        pythonURL: pythonURL,
                        scriptURL: scriptURL,
                        modelID: modelID,
                        modelPath: modelPath,
                        computeType: computeType,
                        additionalPythonPaths: additionalPythonPaths
                    )
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

    func prewarm(
        pythonURL: URL,
        scriptURL: URL,
        modelID: String,
        modelPath: String,
        computeType: String,
        additionalPythonPaths: [String]
    ) {
        queue.async {
            if self.process?.isRunning == true { return }
            do {
                try self.startWorker(
                    pythonURL: pythonURL,
                    scriptURL: scriptURL,
                    modelID: modelID,
                    modelPath: modelPath,
                    computeType: computeType,
                    additionalPythonPaths: additionalPythonPaths
                )
            } catch {
                // Ignore prewarm failures; transcription will surface errors later.
            }
        }
    }

    private func startWorker(
        pythonURL: URL,
        scriptURL: URL,
        modelID: String,
        modelPath: String,
        computeType: String,
        additionalPythonPaths: [String]
    ) throws {
        let newProcess = Process()
        newProcess.executableURL = pythonURL
        newProcess.arguments = [
            scriptURL.path,
            "--worker",
            "--model-id", modelID,
            "--model", modelPath,
            "--language", "en",
            "--beam-size", "1",
            "--compute-type", computeType,
            "--device", "cpu",
            "--local-only"
        ]
        newProcess.currentDirectoryURL = Bundle.main.resourceURL
        newProcess.environment = PythonRuntimeEnvironment.makeEnvironment(
            for: pythonURL,
            additionalPythonPaths: additionalPythonPaths
        )

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
            "PythonWorker: started pid=%d modelID=%@ modelPath=%@",
            newProcess.processIdentifier,
            modelID,
            modelPath
        )
    }

    private func sendRequestOnQueue(audioPath: String) {
        guard process?.isRunning == true else {
            finishOnQueue(.failure(NSError(domain: "Transcription", code: -4, userInfo: [NSLocalizedDescriptionKey: "Transcription worker not running."])))
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
            let message = "Failed to send transcription request to worker: \(error.localizedDescription)"
            stopOnQueue(clearCompletion: false)
            finishOnQueue(.failure(NSError(domain: "Transcription", code: -6, userInfo: [NSLocalizedDescriptionKey: message])))
        }
    }

    private func handleStdoutOnQueue(_ data: Data) {
        buffer.append(data)
        while let range = buffer.range(of: Data([0x0A])) { // newline
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
            NSLog("PythonWorker: timed out waiting for transcription response.")
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
            "PythonWorker: worker terminated status=%d reason=%@",
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
            message = "Python worker exited unexpectedly."
        }
        if terminatedProcess.terminationReason == .uncaughtSignal && terminatedProcess.terminationStatus == 9 {
            message += " macOS killed the worker (signal 9), often due to invalid code signing on bundled Python binaries."
            NSLog("PythonWorker: detected possible code-signing kill (SIGKILL).")
        }
        lastStderr = ""
        finishOnQueue(.failure(NSError(domain: "Transcription", code: Int(terminatedProcess.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])))
    }
}
