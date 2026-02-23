import Foundation
import AVFoundation
import AppKit

enum PermissionCoordinatorError: LocalizedError {
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Required permission is not granted."
        }
    }
}

final class PermissionCoordinator {
    private let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    private let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

    func hasAllRequiredPermissions() -> Bool {
        microphoneStatus == .authorized && AccessibilityHelper.isTrusted()
    }

    var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    var accessibilityTrusted: Bool {
        AccessibilityHelper.isTrusted()
    }

    func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
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
        NSApp.activate(ignoringOtherApps: true)
        _ = AccessibilityHelper.requestIfNeeded()
    }

    func openMicrophoneSettings() {
        guard let microphoneSettingsURL else { return }
        NSWorkspace.shared.open(microphoneSettingsURL)
    }

    func openAccessibilitySettings() {
        guard let accessibilitySettingsURL else { return }
        NSWorkspace.shared.open(accessibilitySettingsURL)
    }
}
