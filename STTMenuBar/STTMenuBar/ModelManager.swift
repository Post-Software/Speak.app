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
        var lastBackend: String?
        var lastFallbackReason: String?
    }

    enum ManagerError: LocalizedError {
        case appSupportUnavailable
        case invalidModel
        case downloadFailed(String)

        var errorDescription: String? {
            switch self {
            case .appSupportUnavailable:
                return "Could not resolve Application Support directory."
            case .invalidModel:
                return "Invalid model selection."
            case .downloadFailed(let message):
                return message
            }
        }
    }

    private let queue = DispatchQueue(label: "speak.model.manager", qos: .userInitiated)
    private let settings = Settings.shared

    private(set) var manifest: Manifest

    private init() {
        manifest = Manifest(
            activeModelID: nil,
            installed: [],
            lastKnownModelSizes: [:],
            lastBackend: nil,
            lastFallbackReason: nil
        )

        loadManifest()
    }

    var modelsRootURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Speak/models", isDirectory: true)
    }

    var manifestURL: URL {
        modelsRootURL.appendingPathComponent("manifest.json")
    }

    var activeModel: ModelVariant? {
        guard let activeID = manifest.activeModelID else { return nil }
        return ModelCatalog.model(for: activeID)
    }

    func needsSetup() -> Bool {
        guard settings.modelSetupCompleted else { return true }
        guard let activeID = manifest.activeModelID else { return true }
        return !isInstalled(modelID: activeID)
    }

    func installedModels() -> [InstalledModel] {
        manifest.installed
    }

    func isInstalled(modelID: String) -> Bool {
        let dir = modelDirectory(for: modelID)
        return FileManager.default.fileExists(atPath: dir.path)
    }

    func modelDirectory(for modelID: String) -> URL {
        modelsRootURL.appendingPathComponent(modelID, isDirectory: true)
    }

    func fetchRemoteInfo(for variant: ModelVariant, completion: @escaping (Result<RemoteModelInfo, Error>) -> Void) {
        queue.async {
            do {
                let lines = try TranscriberProcess.runOneShot(arguments: ["model-info", "--id", variant.id])
                guard let line = lines.last,
                      let data = line.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = object["id"] as? String,
                      let repo = object["repo"] as? String,
                      let displayName = object["display_name"] as? String,
                      let downloadBytesNumber = object["download_bytes"] as? NSNumber,
                      let runtimeBytesNumber = object["estimated_runtime_memory_bytes"] as? NSNumber else {
                    throw ManagerError.downloadFailed("Could not parse model info.")
                }

                let info = RemoteModelInfo(
                    id: id,
                    repo: repo,
                    displayName: displayName,
                    downloadBytes: downloadBytesNumber.int64Value,
                    estimatedRuntimeMemoryBytes: runtimeBytesNumber.int64Value
                )

                DispatchQueue.main.async {
                    completion(.success(info))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func installModel(
        variant: ModelVariant,
        deletePreviousModelID: String?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async {
            do {
                try self.ensureStorageRoot()

                if !self.isInstalled(modelID: variant.id) {
                    let lines = try TranscriberProcess.runOneShot(arguments: [
                        "download",
                        "--id", variant.id,
                        "--dest", self.modelsRootURL.path
                    ])

                    if lines.isEmpty {
                        throw ManagerError.downloadFailed("Model download produced no output.")
                    }
                }

                self.setActiveModel(variant.id)

                if let deletePreviousModelID,
                   !deletePreviousModelID.isEmpty,
                   deletePreviousModelID != variant.id {
                    _ = try? TranscriberProcess.runOneShot(arguments: [
                        "delete",
                        "--id", deletePreviousModelID,
                        "--dest", self.modelsRootURL.path
                    ])
                    self.manifest.installed.removeAll(where: { $0.id == deletePreviousModelID })
                }

                self.persistManifest()

                DispatchQueue.main.async {
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func recordModelSize(id: String, bytes: Int64) {
        manifest.lastKnownModelSizes[id] = bytes
        persistManifest()
    }

    func updateBackendState(backend: String, fallbackReason: String?) {
        manifest.lastBackend = backend
        manifest.lastFallbackReason = fallbackReason
        settings.lastBackend = backend
        settings.lastFallbackReason = fallbackReason ?? ""
        persistManifest()
    }

    private func setActiveModel(_ modelID: String) {
        if !manifest.installed.contains(where: { $0.id == modelID }) {
            if let variant = ModelCatalog.model(for: modelID) {
                manifest.installed.append(InstalledModel(id: modelID, sourceRepo: variant.sourceRepo, installedAt: Date()))
            }
        }

        manifest.activeModelID = modelID
        settings.activeModelID = modelID
        settings.modelSetupCompleted = true

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(manifest.installed),
           let text = String(data: data, encoding: .utf8) {
            settings.installedModelsJSON = text
        }

        if let sizeData = try? JSONEncoder().encode(manifest.lastKnownModelSizes),
           let sizeText = String(data: sizeData, encoding: .utf8) {
            settings.lastKnownModelSizesJSON = sizeText
        }
    }

    private func loadManifest() {
        do {
            try ensureStorageRoot()
            guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                persistManifest()
                return
            }

            let data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(Manifest.self, from: data)
            manifest = decoded

            if let activeModelID = decoded.activeModelID {
                settings.activeModelID = activeModelID
                settings.modelSetupCompleted = true
            }
        } catch {
            NSLog("Failed to load model manifest: \(error)")
        }
    }

    private func ensureStorageRoot() throws {
        try FileManager.default.createDirectory(at: modelsRootURL, withIntermediateDirectories: true)
    }

    private func persistManifest() {
        do {
            try ensureStorageRoot()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            NSLog("Failed to persist model manifest: \(error)")
        }
    }
}
