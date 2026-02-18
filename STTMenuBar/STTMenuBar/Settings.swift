import Foundation

final class Settings: ObservableObject {
    static let shared = Settings()

    enum Keys {
        static let modelName = "modelName"
        static let language = "language"
        static let soundsEnabled = "soundsEnabled"
        static let doubleTapInterval = "doubleTapInterval"
        static let hotKeyTrigger = "hotKeyTrigger"
        static let computeType = "computeType"
        static let device = "device"
        static let pythonPath = "pythonPath"
        static let useTypingFallback = "useTypingFallback"
        static let prewarmOnLaunch = "prewarmOnLaunch"
        static let hasSeenPermissionSetup = "hasSeenPermissionSetup"
    }

    @Published var modelName: String {
        didSet { UserDefaults.standard.set(modelName, forKey: Keys.modelName) }
    }

    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: Keys.language) }
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

    @Published var device: String {
        didSet { UserDefaults.standard.set(device, forKey: Keys.device) }
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

    @Published var hasSeenPermissionSetup: Bool {
        didSet { UserDefaults.standard.set(hasSeenPermissionSetup, forKey: Keys.hasSeenPermissionSetup) }
    }

    private init() {
        let defaults = UserDefaults.standard
        modelName = defaults.string(forKey: Keys.modelName) ?? "small"
        language = defaults.string(forKey: Keys.language) ?? "en"
        soundsEnabled = defaults.object(forKey: Keys.soundsEnabled) as? Bool ?? true
        doubleTapInterval = defaults.object(forKey: Keys.doubleTapInterval) as? TimeInterval ?? 0.35
        hotKeyTrigger = defaults.string(forKey: Keys.hotKeyTrigger) ?? "option"
        computeType = defaults.string(forKey: Keys.computeType) ?? "auto"
        device = defaults.string(forKey: Keys.device) ?? "auto"
        pythonPath = defaults.string(forKey: Keys.pythonPath) ?? "python/.venv/bin/python"
        useTypingFallback = defaults.object(forKey: Keys.useTypingFallback) as? Bool ?? false
        prewarmOnLaunch = defaults.object(forKey: Keys.prewarmOnLaunch) as? Bool ?? false
        hasSeenPermissionSetup = defaults.object(forKey: Keys.hasSeenPermissionSetup) as? Bool ?? false
    }
}
