import Foundation

final class ModelManager: ModelManaging {
    static let shared = ModelManager()

    struct InstalledModel: Codable, Equatable {
        let id: String
        let sourceRepo: String
        let installedAt: Date
        let modelSourceURL: String?
        let modelArtifactHash: String?
        let modelLayoutVersion: String?
    }

    struct Manifest: Codable {
        var activeModelID: String?
        var installed: [InstalledModel]
        var lastKnownModelSizes: [String: Int64]
    }

    enum ManagerError: LocalizedError {
        case appSupportUnavailable
        case runtimeMissing
        case parakeetWorkerMissing
        case invalidModel
        case commandFailed(String)
        case modelVerificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .appSupportUnavailable:
                return "Could not resolve Application Support directory."
            case .runtimeMissing:
                return "Bundled Python runtime is missing from Speak.app. Reinstall Speak and try again."
            case .parakeetWorkerMissing:
                return "Bundled Parakeet worker is missing from Speak.app. Reinstall Speak and try again."
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
    private let environment: [String: String]

    private(set) var manifest = Manifest(
        activeModelID: nil,
        installed: [],
        lastKnownModelSizes: [:]
    )

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        loadManifest()
    }

    private var speakSupportURL: URL {
        if let override = environment["SPEAK_TEST_APP_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Speak", isDirectory: true)
        }
        return appSupport.appendingPathComponent("Speak", isDirectory: true)
    }

    var modelsRootURL: URL {
        speakSupportURL.appendingPathComponent("models", isDirectory: true)
    }

    var runtimeRootURL: URL {
        speakSupportURL.appendingPathComponent("runtime", isDirectory: true)
    }

    var manifestURL: URL {
        modelsRootURL.appendingPathComponent("manifest.json")
    }

    private var uiTestMode: Bool {
        environment["SPEAK_UI_TEST_MODE"] == "1"
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

    func runtimeSitePackagesURL(for modelID: String) -> URL? {
        guard let model = ModelCatalog.model(for: modelID) else { return nil }
        switch model.engine {
        case .whisper:
            return nil
        case .parakeetTDTV3:
            return runtimeRootURL
                .appendingPathComponent("parakeet-v3", isDirectory: true)
                .appendingPathComponent("site-packages", isDirectory: true)
        }
    }

    func additionalPythonPaths(for modelID: String) -> [String] {
        guard let sitePackages = runtimeSitePackagesURL(for: modelID) else { return [] }
        return [sitePackages.path]
    }

    func isInstalled(modelID: String) -> Bool {
        FileManager.default.fileExists(atPath: modelDirectory(for: modelID).path)
    }

    func needsSetup() -> Bool {
        if uiTestMode {
            if let forced = environment["SPEAK_UI_FORCE_NEEDS_SETUP"] {
                return forced != "0"
            }
        }

        guard settings.modelSetupCompleted else { return true }
        guard let activeModelID = manifest.activeModelID else { return true }
        return !isInstalled(modelID: activeModelID)
    }

    func checkRuntime(for variant: ModelVariant, completion: @escaping (Result<RuntimeSupportInfo, Error>) -> Void) {
        queue.async {
            do {
                let runtimeInfo = try self.runtimeSupportInfo(for: variant)
                DispatchQueue.main.async {
                    completion(.success(runtimeInfo))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func fetchRemoteInfo(for variant: ModelVariant, completion: @escaping (Result<RemoteModelInfo, Error>) -> Void) {
        queue.async {
            if let uiInfo = self.uiTestRemoteInfo(for: variant) {
                DispatchQueue.main.async {
                    self.manifest.lastKnownModelSizes[uiInfo.id] = uiInfo.downloadBytes
                    self.persistManifest()
                    self.syncSettingsFromManifest()
                    completion(.success(uiInfo))
                }
                return
            }

            do {
                let lines: [String]
                if variant.engine == .parakeetTDTV3 {
                    lines = try self.runParakeetCommand(
                        arguments: [
                            "--model-info",
                            "--model-id", variant.id
                        ]
                    )
                } else {
                    lines = try self.runPythonCommand(
                        arguments: [
                            "--model-info",
                            "--model-id", variant.id
                        ],
                        additionalPythonPaths: self.additionalPythonPaths(for: variant.id)
                    )
                }

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
            if self.uiTestMode {
                let shouldFail = self.environment["SPEAK_UI_INSTALL_RESULT"]?.lowercased() == "fail"
                DispatchQueue.main.async {
                    if shouldFail {
                        completion(.failure(ManagerError.commandFailed("UI test requested install failure.")))
                        return
                    }

                    self.manifest.activeModelID = variant.id
                    self.manifest.installed = [
                        InstalledModel(
                            id: variant.id,
                            sourceRepo: variant.sourceRepo,
                            installedAt: Date(),
                            modelSourceURL: nil,
                            modelArtifactHash: nil,
                            modelLayoutVersion: nil
                        )
                    ]
                    self.persistManifest()
                    self.syncSettingsFromManifest()
                    completion(.success(()))
                }
                return
            }

            let stagingRoot = self.modelsRootURL
                .appendingPathComponent(".staging", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)

            do {
                try self.ensureStorageRoot()
                try self.ensureRuntimeRoot()
                try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

                var installedModelSourceURL: String?
                var installedModelArtifactHash: String?
                var installedModelLayoutVersion: String?

                if variant.engine == .parakeetTDTV3 {
                    let runtimeStatus = try self.runtimeSupportInfo(for: variant)
                    if runtimeStatus.isHardUnsupported {
                        let message = runtimeStatus.reason.isEmpty
                            ? "Parakeet v3 runtime is not supported on this machine."
                            : runtimeStatus.reason
                        throw ManagerError.commandFailed(message)
                    }

                    let downloadLines = try self.runParakeetCommand(
                        arguments: [
                            "--download-model",
                            "--model-id", variant.id,
                            "--dest", stagingRoot.path
                        ]
                    )

                    guard let downloadPayload = self.lastJSONPayload(from: downloadLines),
                          (downloadPayload["ok"] as? Bool) == true else {
                        throw ManagerError.commandFailed("Failed to download Parakeet v3 model.")
                    }

                    installedModelSourceURL = downloadPayload["source_url"] as? String
                    installedModelArtifactHash = downloadPayload["artifact_hash"] as? String
                    installedModelLayoutVersion = downloadPayload["layout_version"] as? String
                } else {
                    _ = try self.runPythonCommand(
                        arguments: [
                            "--download-model",
                            "--model-id", variant.id,
                            "--dest", stagingRoot.path
                        ],
                        additionalPythonPaths: self.additionalPythonPaths(for: variant.id)
                    )
                }

                let downloadedModelDir = stagingRoot.appendingPathComponent(variant.id, isDirectory: true)
                if variant.engine == .parakeetTDTV3 {
                    _ = try self.runParakeetCommand(
                        arguments: [
                            "--verify-model",
                            "--model-id", variant.id,
                            "--model-path", downloadedModelDir.path
                        ]
                    )
                } else {
                    _ = try self.runPythonCommand(
                        arguments: [
                            "--verify-model",
                            "--model-id", variant.id,
                            "--model-path", downloadedModelDir.path
                        ],
                        additionalPythonPaths: self.additionalPythonPaths(for: variant.id)
                    )
                }

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
                        InstalledModel(
                            id: variant.id,
                            sourceRepo: variant.sourceRepo,
                            installedAt: Date(),
                            modelSourceURL: installedModelSourceURL,
                            modelArtifactHash: installedModelArtifactHash,
                            modelLayoutVersion: installedModelLayoutVersion
                        )
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

    private func ensureRuntimeRoot() throws {
        try FileManager.default.createDirectory(at: runtimeRootURL, withIntermediateDirectories: true)
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

    private func runtimeSupportInfo(for variant: ModelVariant) throws -> RuntimeSupportInfo {
        if let override = uiTestRuntimeSupportInfo(for: variant) {
            return override
        }

        let lines: [String]
        if variant.engine == .parakeetTDTV3 {
            lines = try runParakeetCommand(
                arguments: [
                    "--runtime-check",
                    "--model-id", variant.id
                ]
            )
        } else {
            lines = try runPythonCommand(
                arguments: [
                    "--runtime-check",
                    "--model-id", variant.id
                ],
                additionalPythonPaths: additionalPythonPaths(for: variant.id)
            )
        }

        guard let payload = lastJSONPayload(from: lines) else {
            throw ManagerError.commandFailed("Could not parse runtime check response.")
        }

        return Self.runtimeSupportInfo(from: payload, fallbackModelID: variant.id)
    }

    private func uiTestRuntimeSupportInfo(for variant: ModelVariant) -> RuntimeSupportInfo? {
        guard uiTestMode else { return nil }

        if variant.engine == .whisper {
            return RuntimeSupportInfo(
                modelID: variant.id,
                supported: true,
                status: "ok",
                reason: "",
                requiresInstall: false
            )
        }

        let status = environment["SPEAK_UI_RUNTIME_STATUS"]?.lowercased() ?? "ok"
        switch status {
        case "unsupported":
            return RuntimeSupportInfo(
                modelID: variant.id,
                supported: false,
                status: "unsupported",
                reason: "Parakeet is not supported on this machine.",
                requiresInstall: false
            )
        case "missing_runtime":
            return RuntimeSupportInfo(
                modelID: variant.id,
                supported: false,
                status: "missing_runtime",
                reason: "Parakeet runtime components will be installed during setup.",
                requiresInstall: true
            )
        default:
            return RuntimeSupportInfo(
                modelID: variant.id,
                supported: true,
                status: "ok",
                reason: "",
                requiresInstall: false
            )
        }
    }

    private func uiTestRemoteInfo(for variant: ModelVariant) -> RemoteModelInfo? {
        guard uiTestMode else { return nil }

        let sizeByModelID: [String: Int64] = [
            ModelCatalog.parakeetTdtV3.id: 478_517_071,
            ModelCatalog.smallEN.id: 490_000_000,
            ModelCatalog.mediumEN.id: 1_530_000_000,
            ModelCatalog.largeV3.id: 3_080_000_000
        ]

        return RemoteModelInfo(
            id: variant.id,
            repo: variant.sourceRepo,
            displayName: variant.displayName,
            downloadBytes: sizeByModelID[variant.id] ?? 500_000_000,
            sizeSource: .fallback
        )
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

        throw ManagerError.parakeetWorkerMissing
    }

    private func runPythonCommand(arguments: [String], additionalPythonPaths: [String] = []) throws -> [String] {
        let runtime = try resolvePythonRuntime()
        let fileManager = FileManager.default

        let process = Process()
        process.executableURL = runtime.pythonURL
        process.arguments = [runtime.scriptURL.path] + arguments
        process.environment = PythonRuntimeEnvironment.makeEnvironment(
            for: runtime.pythonURL,
            additionalPythonPaths: additionalPythonPaths
        )
        let fallbackCWD = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        do {
            try fileManager.createDirectory(at: speakSupportURL, withIntermediateDirectories: true)
            process.currentDirectoryURL = speakSupportURL
        } catch {
            NSLog("ModelManager: failed to create working directory %@ (%@)", speakSupportURL.path, error.localizedDescription)
            process.currentDirectoryURL = fallbackCWD
        }

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
            let trimmed = compactCommandFailureMessage(message)
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

    private func runParakeetCommand(arguments: [String]) throws -> [String] {
        let workerURL = try resolveParakeetWorker()
        let fileManager = FileManager.default

        let process = Process()
        process.executableURL = workerURL
        process.arguments = arguments
        let fallbackCWD = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        do {
            try fileManager.createDirectory(at: speakSupportURL, withIntermediateDirectories: true)
            process.currentDirectoryURL = speakSupportURL
        } catch {
            NSLog("ModelManager: failed to create working directory %@ (%@)", speakSupportURL.path, error.localizedDescription)
            process.currentDirectoryURL = fallbackCWD
        }

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
            throw ManagerError.commandFailed(compactCommandFailureMessage(message))
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

    private func compactCommandFailureMessage(_ raw: String) -> String {
        Self.compactCommandFailureMessage(raw)
    }

    static func compactCommandFailureMessage(_ raw: String) -> String {
        let ansiPattern = #"\u{001B}\[[0-9;]*[A-Za-z]"#
        let withoutANSI = raw.replacingOccurrences(
            of: ansiPattern,
            with: "",
            options: .regularExpression
        )

        let cleanedLines = withoutANSI
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty else { return false }
                if line.hasPrefix("Fetching ") { return false }
                if line.hasPrefix("|") { return false }
                if line.hasPrefix("Warning:") { return false }
                if line.contains("UserWarning:") { return false }
                if line.contains("local_dir_use_symlinks") { return false }
                if line.contains("huggingface_hub/utils/_validators.py") { return false }
                if line.contains("HF Hub") && line.contains("HF_TOKEN") { return false }
                return true
            }

        if cleanedLines.isEmpty {
            return withoutANSI.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let summary = cleanedLines.suffix(4).joined(separator: " | ")
        return summary
    }

    static func runtimeSupportInfo(from payload: [String: Any], fallbackModelID: String) -> RuntimeSupportInfo {
        let modelID = payload["model_id"] as? String ?? fallbackModelID
        let supported = payload["supported"] as? Bool ?? false
        let status = payload["status"] as? String ?? "unknown"
        let reason = payload["reason"] as? String ?? ""
        let requiresInstall = payload["requires_install"] as? Bool ?? false

        return RuntimeSupportInfo(
            modelID: modelID,
            supported: supported,
            status: status,
            reason: reason,
            requiresInstall: requiresInstall
        )
    }
}
