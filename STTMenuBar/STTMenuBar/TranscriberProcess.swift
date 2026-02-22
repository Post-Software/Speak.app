import Foundation

final class TranscriberProcess {
    struct WorkerReady {
        let backend: String
        let fallbackReason: String?
    }

    enum ProcessError: LocalizedError {
        case sidecarMissing
        case launchFailed(String)
        case workerNotReady
        case workerNotRunning
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .sidecarMissing:
                return "speak-transcriber binary is missing from app resources."
            case .launchFailed(let message):
                return "Failed to launch transcriber: \(message)"
            case .workerNotReady:
                return "Transcriber worker is not ready."
            case .workerNotRunning:
                return "Transcriber worker is not running."
            case .invalidResponse:
                return "Invalid transcriber response."
            }
        }
    }

    private let queue = DispatchQueue(label: "speak.transcriber.worker")
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()

    private var currentModelID: String?
    private var workerReady: WorkerReady?
    private var readySemaphore: DispatchSemaphore?
    private var readyError: Error?
    private var transcriptionCompletion: ((Result<String, Error>) -> Void)?

    var onWorkerReady: ((WorkerReady) -> Void)?

    func stop() {
        queue.sync {
            stdoutHandle?.readabilityHandler = nil
            stderrHandle?.readabilityHandler = nil
            stdinHandle = nil
            stdoutHandle = nil
            stderrHandle = nil
            process?.terminate()
            process = nil
            workerReady = nil
            readySemaphore = nil
            readyError = nil
            transcriptionCompletion = nil
            stdoutBuffer.removeAll()
            stderrBuffer.removeAll()
        }
    }

    func ensureWorker(modelID: String, modelsRoot: URL) throws -> WorkerReady {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<WorkerReady, Error>?

        queue.async {
            do {
                if self.process?.isRunning == true,
                   self.currentModelID == modelID,
                   let ready = self.workerReady {
                    result = .success(ready)
                    semaphore.signal()
                    return
                }

                self.stopInternalLocked()
                self.currentModelID = modelID
                self.readySemaphore = semaphore
                self.readyError = nil

                let process = Process()
                process.executableURL = try Self.sidecarBinaryURL()
                process.arguments = [
                    "worker",
                    "--id", modelID,
                    "--dest", modelsRoot.path
                ]
                process.environment = ProcessInfo.processInfo.environment.merging(["RUST_LOG": "info"]) { _, new in new }

                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    guard let self else { return }
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    self.queue.async {
                        self.handleStdoutData(data)
                    }
                }

                stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    guard let self else { return }
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    self.queue.async {
                        self.stderrBuffer.append(data)
                    }
                }

                process.terminationHandler = { [weak self] _ in
                    guard let self else { return }
                    self.queue.async {
                        if self.workerReady == nil {
                            let message = String(data: self.stderrBuffer, encoding: .utf8) ?? "unknown startup error"
                            self.readyError = ProcessError.launchFailed(message)
                            self.readySemaphore?.signal()
                        }
                        if let completion = self.transcriptionCompletion {
                            self.transcriptionCompletion = nil
                            DispatchQueue.main.async {
                                completion(.failure(ProcessError.workerNotRunning))
                            }
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
                    result = .failure(ProcessError.launchFailed(error.localizedDescription))
                    semaphore.signal()
                    return
                }

                self.process = process
                self.stdinHandle = stdinPipe.fileHandleForWriting
                self.stdoutHandle = stdoutPipe.fileHandleForReading
                self.stderrHandle = stderrPipe.fileHandleForReading
            } catch {
                result = .failure(error)
                semaphore.signal()
            }
        }

        let wait = semaphore.wait(timeout: .now() + 60)
        if wait == .timedOut {
            throw ProcessError.workerNotReady
        }
        if let result {
            switch result {
            case .success(let ready):
                return ready
            case .failure(let error):
                throw error
            }
        }
        if let readyError {
            throw readyError
        }
        guard let workerReady else {
            throw ProcessError.workerNotReady
        }
        return workerReady
    }

    func transcribe(audioPath: String, completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            guard self.process?.isRunning == true else {
                DispatchQueue.main.async {
                    completion(.failure(ProcessError.workerNotRunning))
                }
                return
            }

            if self.transcriptionCompletion != nil {
                DispatchQueue.main.async {
                    completion(.failure(ProcessError.launchFailed("Worker is busy.")))
                }
                return
            }

            self.transcriptionCompletion = completion
            let request: [String: String] = [
                "type": "transcribe",
                "audio_path": audioPath
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: request)
                if var line = String(data: data, encoding: .utf8) {
                    line.append("\n")
                    try self.stdinHandle?.write(contentsOf: Data(line.utf8))
                } else {
                    throw ProcessError.invalidResponse
                }
            } catch {
                let callback = self.transcriptionCompletion
                self.transcriptionCompletion = nil
                DispatchQueue.main.async {
                    callback?(.failure(error))
                }
            }
        }
    }

    static func runOneShot(arguments: [String]) throws -> [String] {
        let process = Process()
        process.executableURL = try sidecarBinaryURL()
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw ProcessError.launchFailed(stderr.isEmpty ? output : stderr)
        }

        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    static func sidecarBinaryURL() throws -> URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/speak-transcriber"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        #if DEBUG
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            URL(fileURLWithPath: cwd).appendingPathComponent("rust-transcriber/target/debug/speak-transcriber"),
            URL(fileURLWithPath: cwd).appendingPathComponent("rust-transcriber/target/release/speak-transcriber"),
            URL(fileURLWithPath: cwd).appendingPathComponent("../rust-transcriber/target/debug/speak-transcriber"),
            URL(fileURLWithPath: cwd).appendingPathComponent("../rust-transcriber/target/release/speak-transcriber"),
            URL(fileURLWithPath: cwd).appendingPathComponent("target/debug/speak-transcriber"),
            URL(fileURLWithPath: cwd).appendingPathComponent("target/release/speak-transcriber")
        ]

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        #endif

        throw ProcessError.sidecarMissing
    }

    private func stopInternalLocked() {
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        process?.terminate()
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        workerReady = nil
        readySemaphore = nil
        readyError = nil
        transcriptionCompletion = nil
        stdoutBuffer.removeAll()
        stderrBuffer.removeAll()
    }

    private func handleStdoutData(_ data: Data) {
        stdoutBuffer.append(data)
        while let lineRange = stdoutBuffer.firstRange(of: Data([0x0A])) {
            let lineData = stdoutBuffer.subdata(in: 0..<lineRange.lowerBound)
            stdoutBuffer.removeSubrange(0...lineRange.lowerBound)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = payload["type"] as? String else {
            return
        }

        switch kind {
        case "worker_ready":
            let backend = (payload["backend"] as? String) ?? "unknown"
            let reason = payload["fallback_reason"] as? String
            let ready = WorkerReady(backend: backend, fallbackReason: reason)
            workerReady = ready
            readySemaphore?.signal()
            DispatchQueue.main.async {
                self.onWorkerReady?(ready)
            }
        case "result":
            guard let completion = transcriptionCompletion else { return }
            transcriptionCompletion = nil

            let ok = (payload["ok"] as? Bool) ?? false
            if ok {
                let text = (payload["text"] as? String) ?? ""
                DispatchQueue.main.async {
                    completion(.success(text))
                }
            } else {
                let message = (payload["error"] as? String) ?? "Unknown transcription error"
                DispatchQueue.main.async {
                    completion(.failure(ProcessError.launchFailed(message)))
                }
            }
        default:
            break
        }
    }
}
