import Foundation

final class Settings: ObservableObject {
    static let shared = Settings()

    enum Keys {
        static let modelName = "modelName"
        static let soundsEnabled = "soundsEnabled"
        static let doubleTapInterval = "doubleTapInterval"
        static let hotKeyTrigger = "hotKeyTrigger"
        static let computeType = "computeType"
        static let pythonPath = "pythonPath"
        static let useTypingFallback = "useTypingFallback"
        static let prewarmOnLaunch = "prewarmOnLaunch"

        static let activeModelID = "activeModelID"
        static let modelSetupCompleted = "modelSetupCompleted"
        static let installedModels = "installedModels"
        static let lastKnownModelSizes = "lastKnownModelSizes"
    }

    @Published var modelName: String {
        didSet { UserDefaults.standard.set(modelName, forKey: Keys.modelName) }
    }

    @Published var soundsEnabled: Bool {
        didSet { UserDefaults.standard.set(soundsEnabled, forKey: Keys.soundsEnabled) }
    }

    @Published var doubleTapInterval: TimeInterval {
        didSet { UserDefaults.standard.set(doubleTapInterval, forKey: Keys.doubleTapInterval) }
    }

    @Published var hotKeyTrigger: String {
        didSet { UserDefaults.standard.set(hotKeyTrigger, forKey: Keys.hotKeyTrigger) }
    }

    @Published var computeType: String {
        didSet { UserDefaults.standard.set(computeType, forKey: Keys.computeType) }
    }

    @Published var pythonPath: String {
        didSet { UserDefaults.standard.set(pythonPath, forKey: Keys.pythonPath) }
    }

    @Published var useTypingFallback: Bool {
        didSet { UserDefaults.standard.set(useTypingFallback, forKey: Keys.useTypingFallback) }
    }

    @Published var prewarmOnLaunch: Bool {
        didSet { UserDefaults.standard.set(prewarmOnLaunch, forKey: Keys.prewarmOnLaunch) }
    }

    @Published var activeModelID: String {
        didSet { UserDefaults.standard.set(activeModelID, forKey: Keys.activeModelID) }
    }

    @Published var modelSetupCompleted: Bool {
        didSet { UserDefaults.standard.set(modelSetupCompleted, forKey: Keys.modelSetupCompleted) }
    }

    @Published var installedModelsJSON: String {
        didSet { UserDefaults.standard.set(installedModelsJSON, forKey: Keys.installedModels) }
    }

    @Published var lastKnownModelSizesJSON: String {
        didSet { UserDefaults.standard.set(lastKnownModelSizesJSON, forKey: Keys.lastKnownModelSizes) }
    }

    private init() {
        let defaults = UserDefaults.standard
        modelName = defaults.string(forKey: Keys.modelName) ?? "medium"
        soundsEnabled = defaults.object(forKey: Keys.soundsEnabled) as? Bool ?? true
        doubleTapInterval = defaults.object(forKey: Keys.doubleTapInterval) as? TimeInterval ?? 0.35
        hotKeyTrigger = defaults.string(forKey: Keys.hotKeyTrigger) ?? "option"
        computeType = defaults.string(forKey: Keys.computeType) ?? "auto"
        pythonPath = defaults.string(forKey: Keys.pythonPath) ?? "python/.venv/bin/python"
        useTypingFallback = defaults.object(forKey: Keys.useTypingFallback) as? Bool ?? false
        prewarmOnLaunch = defaults.object(forKey: Keys.prewarmOnLaunch) as? Bool ?? false

        activeModelID = defaults.string(forKey: Keys.activeModelID) ?? ""
        modelSetupCompleted = defaults.object(forKey: Keys.modelSetupCompleted) as? Bool ?? false
        installedModelsJSON = defaults.string(forKey: Keys.installedModels) ?? "[]"
        lastKnownModelSizesJSON = defaults.string(forKey: Keys.lastKnownModelSizes) ?? "{}"
    }
}
