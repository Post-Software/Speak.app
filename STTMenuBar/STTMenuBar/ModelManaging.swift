import Foundation

protocol ModelManaging: AnyObject {
    var manifest: ModelManager.Manifest { get }
    var activeModel: ModelVariant? { get }
    var activeModelLocalPath: String? { get }

    func additionalPythonPaths(for modelID: String) -> [String]
    func needsSetup() -> Bool
    func checkRuntime(for variant: ModelVariant, completion: @escaping (Result<RuntimeSupportInfo, Error>) -> Void)
    func fetchRemoteInfo(for variant: ModelVariant, completion: @escaping (Result<RemoteModelInfo, Error>) -> Void)
    func installModel(variant: ModelVariant, completion: @escaping (Result<Void, Error>) -> Void)
}

