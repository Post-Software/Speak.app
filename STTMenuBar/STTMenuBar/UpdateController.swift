import Foundation

#if canImport(Sparkle)
import Sparkle
#endif

protocol UpdateChecking: AnyObject {
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}

final class UpdateController: NSObject, UpdateChecking {
#if canImport(Sparkle)
    private let updaterController: SPUStandardUpdaterController
#endif

    override init() {
#if canImport(Sparkle)
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
#endif
        super.init()
    }

    var canCheckForUpdates: Bool {
#if canImport(Sparkle)
        return updaterController.updater.canCheckForUpdates
#else
        return false
#endif
    }

    func checkForUpdates() {
#if canImport(Sparkle)
        updaterController.checkForUpdates(nil)
#else
        NSLog("Sparkle framework is unavailable. Check for Updates is disabled.")
#endif
    }
}
