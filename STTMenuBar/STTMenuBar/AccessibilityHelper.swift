import Foundation
import ApplicationServices

enum AccessibilityHelper {
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestIfNeeded() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

