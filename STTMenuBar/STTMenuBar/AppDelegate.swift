import Cocoa
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let hotKeyMonitor = HotKeyMonitor()
    private let audioRecorder = AudioRecorder()
    private let soundPlayer = SystemSoundPlayer()
    private let transcriptionRunner = TranscriptionRunner()
    private let pasteController = PasteController()
    private let settings = Settings.shared

    private var isRecording = false
    private var isTranscribing = false
    private var currentRecordingURL: URL?
    private var recordingStartedAt: Date?

    private var toggleItem: NSMenuItem?
    private var soundsItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureHotKey()
        requestMicrophonePermissionOnStartup()
        if settings.prewarmOnLaunch {
            transcriptionRunner.prewarm()
        }
    }

    private func configureStatusItem() {
        if statusItem.button == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        }
        statusItem.length = NSStatusItem.squareLength
        if let button = statusItem.button {
            button.title = ""
            button.image = StatusIcon.image(color: .systemGreen)
            button.imagePosition = .imageOnly
            statusItem.isVisible = true
        } else {
            NSLog("Status item button was nil")
        }

        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "")
        toggle.target = self
        toggleItem = toggle
        menu.addItem(toggle)

        menu.addItem(NSMenuItem.separator())

        let hotKeyMenu = NSMenu()
        for trigger in HotKeyMonitor.triggers {
            let item = NSMenuItem(title: trigger.title, action: #selector(selectHotKeyTrigger(_:)), keyEquivalent: "")
            item.representedObject = trigger.id
            item.state = settings.hotKeyTrigger == trigger.id ? .on : .off
            item.target = self
            hotKeyMenu.addItem(item)
        }
        let hotKeyItem = NSMenuItem(title: "Hotkey", action: nil, keyEquivalent: "")
        menu.setSubmenu(hotKeyMenu, for: hotKeyItem)
        menu.addItem(hotKeyItem)

        let sounds = NSMenuItem(title: "Sounds", action: #selector(toggleSounds), keyEquivalent: "")
        sounds.target = self
        sounds.state = settings.soundsEnabled ? .on : .off
        soundsItem = sounds
        menu.addItem(sounds)

        let prewarm = NSMenuItem(title: "Pre-warm Model on Launch", action: #selector(togglePrewarm), keyEquivalent: "")
        prewarm.target = self
        prewarm.state = settings.prewarmOnLaunch ? .on : .off
        menu.addItem(prewarm)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func configureHotKey() {
        AccessibilityHelper.requestIfNeeded()
        hotKeyMonitor.onDoubleTap = { [weak self] in
            self?.toggleRecording()
        }
        hotKeyMonitor.onStartFailure = { [weak self] in
            let alert = NSAlert()
            alert.messageText = "Hotkey Disabled"
            alert.informativeText = "Speak could not register the global hotkey because macOS blocked accessibility access. Open System Settings → Privacy & Security → Accessibility, enable Speak, and then relaunch the app."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            self?.updateToggleTitle()
        }
        hotKeyMonitor.start()
    }

    private func requestMicrophonePermissionOnStartup() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .notDetermined else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.audioRecorder.requestMicrophoneAccess { granted in
                if !granted {
                    self?.showMicrophonePermissionAlert()
                }
            }
        }
    }

    @objc private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch authStatus {
        case .authorized:
            break
        case .notDetermined:
            audioRecorder.requestMicrophoneAccess { [weak self] granted in
                if granted {
                    self?.startRecording()
                } else {
                    self?.showMicrophonePermissionAlert()
                }
            }
            return
        case .denied, .restricted:
            showMicrophonePermissionAlert()
            return
        @unknown default:
            showMicrophonePermissionAlert()
            return
        }

        transcriptionRunner.cancel()
        setTranscribing(false)

        do {
            currentRecordingURL = try audioRecorder.startRecording()
            recordingStartedAt = Date()
            isRecording = true
            updateStatusIcon()
            updateToggleTitle()
            if settings.soundsEnabled { soundPlayer.playOn() }
        } catch {
            NSLog("Failed to start recording: \(error)")
        }
    }

    private func showMicrophonePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Access Required"
        alert.informativeText = "Speak cannot start recording because microphone access is blocked. Open System Settings → Privacy & Security → Microphone and enable Speak."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func stopRecording() {
        audioRecorder.stopRecording()
        isRecording = false
        updateStatusIcon()
        updateToggleTitle()
        if settings.soundsEnabled { soundPlayer.playOff() }

        guard let audioURL = currentRecordingURL else { return }
        let recordingDuration = Date().timeIntervalSince(recordingStartedAt ?? Date())
        recordingStartedAt = nil

        setTranscribing(true)
        transcriptionRunner.transcribe(audioURL: audioURL) { [weak self] result in
            switch result {
            case .success(let text):
                DispatchQueue.main.async {
                    self?.setTranscribing(false)
                }
                guard !text.isEmpty else {
                    if recordingDuration < 5.0 {
                        return
                    }
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "No Transcription Output"
                        alert.informativeText = "The transcription completed but returned no text. Try a longer or louder recording."
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                    return
                }
                DispatchQueue.main.async {
                    self?.pasteController.insertText(text)
                }
            case .failure(let error):
                NSLog("Transcription failed: \(error)")
                DispatchQueue.main.async {
                    self?.setTranscribing(false)
                    let alert = NSAlert()
                    alert.messageText = "Transcription Failed"
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    private func updateStatusIcon() {
        if let button = statusItem.button {
            button.image = StatusIcon.image(color: isRecording ? .systemRed : .systemGreen)
        }
    }

    private func updateToggleTitle() {
        if isTranscribing {
            toggleItem?.title = "Transcribing…"
            toggleItem?.isEnabled = false
        } else {
            toggleItem?.isEnabled = true
            toggleItem?.title = isRecording ? "Stop Recording" : "Start Recording"
        }
    }

    private func setTranscribing(_ value: Bool) {
        isTranscribing = value
        updateToggleTitle()
    }

    @objc private func selectHotKeyTrigger(_ sender: NSMenuItem) {
        guard let triggerID = sender.representedObject as? String else { return }
        settings.hotKeyTrigger = triggerID
        sender.menu?.items.forEach { $0.state = .off }
        sender.state = .on
    }

    @objc private func toggleSounds() {
        settings.soundsEnabled.toggle()
        soundsItem?.state = settings.soundsEnabled ? .on : .off
    }

    @objc private func togglePrewarm(_ sender: NSMenuItem) {
        settings.prewarmOnLaunch.toggle()
        sender.state = settings.prewarmOnLaunch ? .on : .off
        if settings.prewarmOnLaunch {
            transcriptionRunner.prewarm()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

}

enum StatusIcon {
    static func image(color: NSColor, diameter: CGFloat = 14) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(ovalIn: rect)
        path.fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
