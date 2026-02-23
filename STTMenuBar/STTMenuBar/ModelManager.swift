import Foundation

final class ModelManager {
    static let shared = ModelManager()

    struct InstalledModel: Codable, Equatable {
        let id: String
        let sourceRepo: String
        let installedAt: Date
    }

    struct Manifest: Codable {
        var activeModelID: String?
        var installed: [InstalledModel]
        var lastKnownModelSizes: [String: Int64]
    }

    enum ManagerError: LocalizedError {
        case appSupportUnavailable
        case runtimeMissing
        case invalidModel
        case commandFailed(String)
        case modelVerificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .appSupportUnavailable:
                return "Could not resolve Application Support directory."
            case .runtimeMissing:
                return "Bundled Python runtime is missing from Speak.app. Reinstall Speak and try again."
            case .invalidModel:
                return "Invalid model selection."
            case .commandFailed(let message):
                return message
            case .modelVerificationFailed(let message):
                return message
            }
        }
    }

    private let queue = DispatchQueue(label: "speak.model.manager", qos: .userInitiated)
    private let settings = Settings.shared

    private(set) var manifest = Manifest(
        activeModelID: nil,
        installed: [],
        lastKnownModelSizes: [:]
    )

    private init() {
        loadManifest()
    }

    var modelsRootURL: URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Speak/models", isDirectory: true)
        }
        return appSupport.appendingPathComponent("Speak/models", isDirectory: true)
    }

    var manifestURL: URL {
        modelsRootURL.appendingPathComponent("manifest.json")
    }

    var activeModel: ModelVariant? {
        guard let activeModelID = manifest.activeModelID else { return nil }
        return ModelCatalog.model(for: activeModelID)
    }

    var activeModelLocalPath: String? {
        guard let activeModelID = manifest.activeModelID else { return nil }
        let path = modelDirectory(for: activeModelID).path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    func modelDirectory(for modelID: String) -> URL {
        modelsRootURL.appendingPathComponent(modelID, isDirectory: true)
    }

    func isInstalled(modelID: String) -> Bool {
        FileManager.default.fileExists(atPath: modelDirectory(for: modelID).path)
    }

    func needsSetup() -> Bool {
        guard settings.modelSetupCompleted else { return true }
        guard let activeModelID = manifest.activeModelID else { return true }
        return !isInstalled(modelID: activeModelID)
    }

    func fetchRemoteInfo(for variant: ModelVariant, completion: @escaping (Result<RemoteModelInfo, Error>) -> Void) {
        queue.async {
            do {
                let lines = try self.runPythonCommand(arguments: [
                    "--model-info",
                    "--model-id", variant.id
                ])

                guard let payload = self.lastJSONPayload(from: lines),
                      let id = payload["id"] as? String,
                      let repo = payload["repo"] as? String,
                      let displayName = payload["display_name"] as? String,
                      let bytesNumber = payload["download_bytes"] as? NSNumber else {
                    throw ManagerError.commandFailed("Could not parse model metadata response.")
                }
                let sizeSourceRaw = payload["size_source"] as? String ?? "exact"
                let sizeSource = RemoteModelInfo.SizeSource(rawValue: sizeSourceRaw) ?? .exact

                let info = RemoteModelInfo(
                    id: id,
                    repo: repo,
                    displayName: displayName,
                    downloadBytes: bytesNumber.int64Value,
                    sizeSource: sizeSource
                )

                DispatchQueue.main.async {
                    self.manifest.lastKnownModelSizes[id] = info.downloadBytes
                    self.persistManifest()
                    self.syncSettingsFromManifest()
                    completion(.success(info))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func installModel(variant: ModelVariant, completion: @escaping (Result<Void, Error>) -> Void) {
        let oldActiveModelID = self.manifest.activeModelID
        queue.async {
            let stagingRoot = self.modelsRootURL
                .appendingPathComponent(".staging", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)

            do {
                try self.ensureStorageRoot()
                try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

                _ = try self.runPythonCommand(arguments: [
                    "--download-model",
                    "--model-id", variant.id,
                    "--dest", stagingRoot.path
                ])

                let downloadedModelDir = stagingRoot.appendingPathComponent(variant.id, isDirectory: true)
                try self.verifyModelDirectory(downloadedModelDir)

                let finalModelDir = self.modelDirectory(for: variant.id)
                if FileManager.default.fileExists(atPath: finalModelDir.path) {
                    try FileManager.default.removeItem(at: finalModelDir)
                }
                try FileManager.default.moveItem(at: downloadedModelDir, to: finalModelDir)

                if let oldActiveModelID,
                   oldActiveModelID != variant.id {
                    let oldDir = self.modelDirectory(for: oldActiveModelID)
                    if FileManager.default.fileExists(atPath: oldDir.path) {
                        try? FileManager.default.removeItem(at: oldDir)
                    }
                }

                try? FileManager.default.removeItem(at: stagingRoot)

                DispatchQueue.main.async {
                    self.manifest.activeModelID = variant.id
                    self.manifest.installed = [
                        InstalledModel(id: variant.id, sourceRepo: variant.sourceRepo, installedAt: Date())
                    ]
                    self.persistManifest()
                    self.syncSettingsFromManifest()
                    completion(.success(()))
                }
            } catch {
                try? FileManager.default.removeItem(at: stagingRoot)

                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func loadManifest() {
        do {
            try ensureStorageRoot()
            guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                persistManifest()
                syncSettingsFromManifest()
                return
            }

            let data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(Manifest.self, from: data)
            syncSettingsFromManifest()
        } catch {
            NSLog("Failed to load model manifest: %@", error.localizedDescription)
            manifest = Manifest(activeModelID: nil, installed: [], lastKnownModelSizes: [:])
            syncSettingsFromManifest()
        }
    }

    private func syncSettingsFromManifest() {
        settings.activeModelID = manifest.activeModelID ?? ""
        settings.modelSetupCompleted = activeModelLocalPath != nil

        if let installedData = try? JSONEncoder().encode(manifest.installed),
           let installedJSON = String(data: installedData, encoding: .utf8) {
            settings.installedModelsJSON = installedJSON
        }

        if let sizesData = try? JSONEncoder().encode(manifest.lastKnownModelSizes),
           let sizesJSON = String(data: sizesData, encoding: .utf8) {
            settings.lastKnownModelSizesJSON = sizesJSON
        }
    }

    private func ensureStorageRoot() throws {
        try FileManager.default.createDirectory(at: modelsRootURL, withIntermediateDirectories: true)
    }

    private func persistManifest() {
        do {
            try ensureStorageRoot()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            NSLog("Failed to persist model manifest: %@", error.localizedDescription)
        }
    }

    private func verifyModelDirectory(_ url: URL) throws {
        let required = ["model.bin", "config.json", "tokenizer.json"]
        for name in required {
            let path = url.appendingPathComponent(name).path
            if !FileManager.default.fileExists(atPath: path) {
                throw ManagerError.modelVerificationFailed("Downloaded model is incomplete (missing \(name)).")
            }
        }
    }

    private func resolvePythonRuntime() throws -> (pythonURL: URL, scriptURL: URL) {
        if let resourcesURL = Bundle.main.resourceURL {
            let bundledPython = resourcesURL.appendingPathComponent("python/bin/python")
            let bundledScript = resourcesURL.appendingPathComponent("python/transcribe.py")
            if FileManager.default.isExecutableFile(atPath: bundledPython.path),
               FileManager.default.fileExists(atPath: bundledScript.path) {
                return (bundledPython, bundledScript)
            }
        }

        #if DEBUG
        let cwd = FileManager.default.currentDirectoryPath
        let localPython = URL(fileURLWithPath: cwd).appendingPathComponent("python/.venv/bin/python")
        let localScript = URL(fileURLWithPath: cwd).appendingPathComponent("python/transcribe.py")
        if FileManager.default.isExecutableFile(atPath: localPython.path),
           FileManager.default.fileExists(atPath: localScript.path) {
            return (localPython, localScript)
        }
        #endif

        throw ManagerError.runtimeMissing
    }

    private func runPythonCommand(arguments: [String]) throws -> [String] {
        let runtime = try resolvePythonRuntime()

        let process = Process()
        process.executableURL = runtime.pythonURL
        process.arguments = [runtime.scriptURL.path] + arguments
        process.environment = PythonRuntimeEnvironment.makeEnvironment(for: runtime.pythonURL)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdoutString = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrString = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = stderrString.isEmpty ? stdoutString : stderrString
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("dlopen(/Library/Frameworks/Python.framework") {
                NSLog("ModelManager: detected invalid bundled Python path resolution: %@", trimmed)
                throw ManagerError.commandFailed("Bundled Python runtime path is invalid. Reinstall Speak or rebuild release package.")
            }
            throw ManagerError.commandFailed(trimmed)
        }

        return stdoutString
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func lastJSONPayload(from lines: [String]) -> [String: Any]? {
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            return obj
        }
        return nil
    }
}
