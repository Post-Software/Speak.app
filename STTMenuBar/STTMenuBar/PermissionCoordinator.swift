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
        let status = microphoneStatus
        switch status {
        case .authorized:
            completion(true)
        case .notDetermined:
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        completion(true)
                        return
                    }
                    self.pollMicrophoneStatusUntilResolved(timeout: 3.0, completion: completion)
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

    private func pollMicrophoneStatusUntilResolved(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)

        func check() {
            let current = AVCaptureDevice.authorizationStatus(for: .audio)
            switch current {
            case .authorized:
                completion(true)
            case .denied, .restricted:
                completion(false)
            case .notDetermined:
                if Date() >= deadline {
                    completion(false)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        check()
                    }
                }
            @unknown default:
                completion(false)
            }
        }

        check()
    }
}
