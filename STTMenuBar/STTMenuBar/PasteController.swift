import Foundation
import AppKit

final class PasteController {
    private let settings = Settings.shared

    func insertText(_ text: String) {
        let pasteboard = NSPasteboard.general
        let savedItems = snapshotPasteboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard AccessibilityHelper.isTrusted() else {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Accessibility Required"
                alert.informativeText = "Transcription was copied to your clipboard. Enable Speak in System Settings → Privacy & Security → Accessibility to allow automatic paste."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            return
        }

        sendPasteKeystroke()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.restorePasteboard(pasteboard, savedItems: savedItems)
        }

        if settings.useTypingFallback {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.typeText(text)
            }
        }
    }

    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict
        }
    }

    private func restorePasteboard(_ pasteboard: NSPasteboard, savedItems: [[NSPasteboard.PasteboardType: Data]]) {
        pasteboard.clearContents()
        var items: [NSPasteboardItem] = []
        for itemDict in savedItems {
            let item = NSPasteboardItem()
            for (type, data) in itemDict {
                item.setData(data, forType: type)
            }
            items.append(item)
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    private func sendPasteKeystroke() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func typeText(_ text: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let utf16 = Array(text.utf16)
        let chunkSize = 20
        var index = 0

        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            let chunk = Array(utf16[index..<end])
            if let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event.post(tap: .cghidEventTap)
            }
            index = end
        }
    }
}
