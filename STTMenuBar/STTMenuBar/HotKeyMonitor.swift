import Foundation
import AppKit

final class HotKeyMonitor {
    struct Trigger {
        let id: String
        let title: String
        let keyCodes: Set<Int64>
        let flag: CGEventFlags
    }

    static let triggers: [Trigger] = [
        Trigger(id: "option", title: "Double-Tap Option (⌥)", keyCodes: [58, 61], flag: .maskAlternate),
        Trigger(id: "command", title: "Double-Tap Command (⌘)", keyCodes: [55, 54], flag: .maskCommand),
        Trigger(id: "control", title: "Double-Tap Control (⌃)", keyCodes: [59, 62], flag: .maskControl),
        Trigger(id: "shift", title: "Double-Tap Shift (⇧)", keyCodes: [56, 60], flag: .maskShift)
    ]

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var lastTapDown: TimeInterval = 0
    private var lastDoubleTapFire: TimeInterval = 0
    private let settings = Settings.shared

    var onDoubleTap: (() -> Void)?
    var onStartFailure: (() -> Void)?

    func start() {
        guard eventTap == nil else { return }

        let mask = (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        guard let eventTap else {
            NSLog("Failed to create event tap. Check Accessibility permissions.")
            DispatchQueue.main.async { [weak self] in
                self?.onStartFailure?()
            }
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let trigger = Self.triggers.first(where: { $0.id == settings.hotKeyTrigger }) ?? Self.triggers[0]

        let isTriggerKey = trigger.keyCodes.contains(keyCode)
        let isTriggerDown = flags.contains(trigger.flag)

        if isTriggerKey && isTriggerDown {
            let now = Date().timeIntervalSince1970
            let interval = settings.doubleTapInterval
            if now - lastTapDown <= interval {
                if now - lastDoubleTapFire < 0.25 {
                    return Unmanaged.passUnretained(event)
                }
                lastTapDown = 0
                lastDoubleTapFire = now
                DispatchQueue.main.async { [weak self] in
                    self?.onDoubleTap?()
                }
            } else {
                lastTapDown = now
            }
        }

        return Unmanaged.passUnretained(event)
    }
}
