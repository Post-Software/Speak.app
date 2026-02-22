import Foundation

final class PythonWorker {
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
        queue.sync {
            stdoutHandle?.readabilityHandler = nil
            stderrHandle?.readabilityHandler = nil
            stdinHandle = nil
            stdoutHandle = nil
            stderrHandle = nil
            process?.terminate()
            process = nil
            currentCompletion = nil
            buffer.removeAll()
            lastStderr = ""
            timeoutTimer?.cancel()
            timeoutTimer = nil
        }
    }

    func transcribe(pythonURL: URL, scriptURL: URL, modelPath: String, audioPath: String, computeType: String, completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            if self.currentCompletion != nil {
                self.stop()
            }

            if self.process?.isRunning != true {
                do {
                    try self.startWorker(pythonURL: pythonURL, scriptURL: scriptURL, modelPath: modelPath, computeType: computeType)
                } catch {
                    completion(.failure(error))
                    return
                }
            }

            self.currentCompletion = completion
            self.sendRequest(audioPath: audioPath)
            self.startTimeout()
        }
    }

    func prewarm(pythonURL: URL, scriptURL: URL, modelPath: String, computeType: String) {
        queue.async {
            if self.process?.isRunning == true { return }
            do {
                try self.startWorker(pythonURL: pythonURL, scriptURL: scriptURL, modelPath: modelPath, computeType: computeType)
            } catch {
                // Ignore prewarm failures; transcription will surface errors later.
            }
        }
    }

    private func startWorker(pythonURL: URL, scriptURL: URL, modelPath: String, computeType: String) throws {
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [
            scriptURL.path,
            "--worker",
            "--model", modelPath,
            "--language", "en",
            "--beam-size", "1",
            "--compute-type", computeType,
            "--device", "cpu",
            "--local-only"
        ]
        process.currentDirectoryURL = Bundle.main.resourceURL
        process.environment = (ProcessInfo.processInfo.environment.merging(["PYTHONUNBUFFERED": "1"]) { $1 })

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            self?.handleStdout(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let text = String(data: data, encoding: .utf8) {
                self?.lastStderr.append(text)
            }
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            if self.currentCompletion != nil {
                let message = self.lastStderr.isEmpty ? "Python worker exited unexpectedly." : self.lastStderr
                self.finish(.failure(NSError(domain: "Transcription", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])))
            }
        }

        try process.run()
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.stderrHandle = stderrPipe.fileHandleForReading
        self.buffer.removeAll()
        self.lastStderr = ""
    }

    private func sendRequest(audioPath: String) {
        guard process?.isRunning == true else {
            finish(.failure(NSError(domain: "Transcription", code: -4, userInfo: [NSLocalizedDescriptionKey: "Transcription worker not running."])))
            return
        }
        let request: [String: String] = ["audio": audioPath]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              var line = String(data: data, encoding: .utf8) else {
            currentCompletion?(.failure(NSError(domain: "Transcription", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode request"])) )
            currentCompletion = nil
            return
        }
        line.append("\n")
        if let bytes = line.data(using: .utf8) {
            try? stdinHandle?.write(contentsOf: bytes)
        }
    }

    private func handleStdout(_ data: Data) {
        buffer.append(data)
        while let range = buffer.range(of: Data([0x0A])) { // newline
            let lineData = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0...range.lowerBound)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            handleResponseLine(line)
        }
    }

    private func handleResponseLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            finish(.failure(NSError(domain: "Transcription", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])))
            return
        }

        if let ok = json["ok"] as? Bool, ok {
            let text = (json["text"] as? String) ?? ""
            finish(.success(text))
        } else {
            let message = (json["error"] as? String) ?? "Unknown error"
            finish(.failure(NSError(domain: "Transcription", code: -3, userInfo: [NSLocalizedDescriptionKey: message])))
        }
    }

    private func finish(_ result: Result<String, Error>) {
        timeoutTimer?.cancel()
        timeoutTimer = nil
        let completion = currentCompletion
        currentCompletion = nil
        DispatchQueue.main.async {
            completion?(result)
        }
    }

    private func startTimeout() {
        timeoutTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 120)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.stop()
            self.finish(.failure(NSError(domain: "Transcription", code: -5, userInfo: [NSLocalizedDescriptionKey: "Transcription timed out."])))
        }
        timeoutTimer = timer
        timer.resume()
    }
}
