import Foundation
import AVFoundation
import AppKit

protocol PermissionCoordinating: AnyObject {
    func hasAllRequiredPermissions() -> Bool
    var microphoneStatus: AVAuthorizationStatus { get }
    var accessibilityTrusted: Bool { get }
    func requestMicrophoneAccess(completion: @escaping (Bool) -> Void)
    func requestAccessibilityAccess()
    func openMicrophoneSettings()
    func openAccessibilitySettings()
}

enum PermissionCoordinatorError: LocalizedError {
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Required permission is not granted."
        }
    }
}

final class PermissionCoordinator: PermissionCoordinating {
    private let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    private let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    private let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    private var uiTestMode: Bool {
        environment["SPEAK_UI_TEST_MODE"] == "1"
    }

    private var uiTestMicrophoneStatus: AVAuthorizationStatus? {
        guard uiTestMode else { return nil }
        switch environment["SPEAK_UI_MIC_STATUS"]?.lowercased() {
        case "authorized":
            return .authorized
        case "denied":
            return .denied
        case "restricted":
            return .restricted
        case "not_determined":
            return .notDetermined
        default:
            return nil
        }
    }

    private var uiTestAccessibilityTrusted: Bool? {
        guard uiTestMode else { return nil }
        switch environment["SPEAK_UI_AX_STATUS"]?.lowercased() {
        case "trusted":
            return true
        case "blocked":
            return false
        default:
            return nil
        }
    }

    func hasAllRequiredPermissions() -> Bool {
        microphoneStatus == .authorized && accessibilityTrusted
    }

    var microphoneStatus: AVAuthorizationStatus {
        if let override = uiTestMicrophoneStatus {
            return override
        }
        return AVCaptureDevice.authorizationStatus(for: .audio)
    }

    var accessibilityTrusted: Bool {
        if let override = uiTestAccessibilityTrusted {
            return override
        }
        return AccessibilityHelper.isTrusted()
    }

    func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        if let override = uiTestMicrophoneStatus {
            completion(override == .authorized)
            return
        }

        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.requestMicrophoneAccess(completion: completion)
            }
            return
        }

        let currentStatus = microphoneStatus
        NSLog("Microphone permission request path captureStatus=%ld", currentStatus.rawValue)

        switch currentStatus {
        case .authorized:
            completion(true)
        case .notDetermined:
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    func requestAccessibilityAccess() {
        if uiTestMode {
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        _ = AccessibilityHelper.requestIfNeeded()
    }

    func openMicrophoneSettings() {
        if uiTestMode {
            return
        }
        guard let microphoneSettingsURL else { return }
        NSWorkspace.shared.open(microphoneSettingsURL)
    }

    func openAccessibilitySettings() {
        if uiTestMode {
            return
        }
        guard let accessibilitySettingsURL else { return }
        NSWorkspace.shared.open(accessibilitySettingsURL)
    }
}
