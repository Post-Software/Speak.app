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
    private let permissionCoordinator = PermissionCoordinator()
    private let modelManager = ModelManager.shared

    private var isRecording = false
    private var isTranscribing = false
    private var currentRecordingURL: URL?
    private var recordingStartedAt: Date?

    private var permissionSetupWindowController: PermissionSetupWindowController?
    private var modelSetupWindowController: ModelSetupWindowController?

    private var toggleItem: NSMenuItem?
    private var soundsItem: NSMenuItem?
    private var fallbackWarningShown = false
    private var lastToggleInvocationAt: TimeInterval = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureHotKeyCallbacks()
        configureTranscriberCallbacks()

        if permissionCoordinator.hasAllRequiredPermissions() {
            completeLaunchAfterSetup()
        } else {
            showPermissionSetupWindow(activate: true)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        permissionSetupWindowController?.refreshStatuses()
        refreshHotKeyRegistration()
    }

    private func configureTranscriberCallbacks() {
        transcriptionRunner.onWorkerReady = { [weak self] ready in
            guard let self else { return }
            self.modelManager.updateBackendState(backend: ready.backend, fallbackReason: ready.fallbackReason)
            guard ready.backend == "cpu", self.fallbackWarningShown == false else { return }
            self.fallbackWarningShown = true
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "CPU Fallback Mode"
                alert.informativeText = "Speak is running without Metal acceleration. Transcription will be slower on this machine."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
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
        }

        let menu = NSMenu()

        let toggle = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "")
        toggle.target = self
        toggleItem = toggle
        menu.addItem(toggle)

        let setup = NSMenuItem(title: "Permissions Setup...", action: #selector(openPermissionSetup), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)

        let modelItem = NSMenuItem(title: "Select your model", action: #selector(openModelSetup), keyEquivalent: "")
        modelItem.target = self
        menu.addItem(modelItem)

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

    private func configureHotKeyCallbacks() {
        hotKeyMonitor.onDoubleTap = { [weak self] in
            self?.toggleRecording()
        }
        hotKeyMonitor.onStartFailure = { [weak self] in
            self?.showHotkeyPermissionAlert()
        }
    }

    @objc private func toggleRecording() {
        let now = Date().timeIntervalSince1970
        if now - lastToggleInvocationAt < 0.25 {
            return
        }
        lastToggleInvocationAt = now

        if isTranscribing {
            return
        }

        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard modelManager.needsSetup() == false else {
            openModelSetup()
            return
        }

        permissionCoordinator.requestMicrophoneAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.showMicrophonePermissionAlert()
                return
            }

            do {
                self.currentRecordingURL = try self.audioRecorder.startRecording()
                self.recordingStartedAt = Date()
                self.isRecording = true
                self.updateStatusIcon()
                self.updateToggleTitle()
                if self.settings.soundsEnabled {
                    self.soundPlayer.playOn()
                }
            } catch {
                NSLog("Failed to start recording: \(error)")
            }
        }
    }

    private func stopRecording() {
        audioRecorder.stopRecording()
        isRecording = false
        updateStatusIcon()
        updateToggleTitle()
        if settings.soundsEnabled {
            soundPlayer.playOff()
        }

        guard let audioURL = currentRecordingURL else { return }
        let recordingDuration = Date().timeIntervalSince(recordingStartedAt ?? Date())
        recordingStartedAt = nil

        setTranscribing(true)
        transcriptionRunner.transcribe(audioURL: audioURL) { [weak self] result in
            guard let self else { return }
            self.setTranscribing(false)

            switch result {
            case .success(let text):
                guard !text.isEmpty else {
                    if recordingDuration < 5.0 {
                        return
                    }
                    let alert = NSAlert()
                    alert.messageText = "No Transcription Output"
                    alert.informativeText = "The transcription completed but returned no text. Try a longer or louder recording."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }
                self.pasteController.insertText(text)
            case .failure(let error):
                NSLog("Transcription failed: \(error)")
                let alert = NSAlert()
                alert.messageText = "Transcription Failed"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    private func completeLaunchAfterSetup() {
        refreshHotKeyRegistration()

        if modelManager.needsSetup() {
            openModelSetup()
            return
        }

        if settings.prewarmOnLaunch {
            transcriptionRunner.prewarm()
        }
    }

    private func refreshHotKeyRegistration() {
        hotKeyMonitor.stop()
        guard permissionCoordinator.accessibilityTrusted else { return }
        hotKeyMonitor.start()
    }

    private func showPermissionSetupWindow(activate: Bool) {
        if permissionSetupWindowController == nil {
            let controller = PermissionSetupWindowController()
            controller.onRequestMicrophone = { [weak self] in
                guard let self else { return }
                self.permissionCoordinator.requestMicrophoneAccess { granted in
                    if !granted && self.permissionCoordinator.microphoneStatus != .notDetermined {
                        self.permissionCoordinator.openMicrophoneSettings()
                    }
                    self.permissionSetupWindowController?.refreshStatuses()
                }
            }
            controller.onRequestAccessibility = { [weak self] in
                guard let self else { return }
                self.permissionCoordinator.requestAccessibilityAccess()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.permissionSetupWindowController?.refreshStatuses()
                    self.refreshHotKeyRegistration()
                }
            }
            controller.onContinue = { [weak self] in
                guard let self else { return }
                if self.permissionCoordinator.hasAllRequiredPermissions() {
                    self.completeLaunchAfterSetup()
                }
            }
            permissionSetupWindowController = controller
        }

        permissionSetupWindowController?.refreshStatuses()
        permissionSetupWindowController?.showWindow(nil)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showMicrophonePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Access Required"
        alert.informativeText = "Speak cannot record until microphone access is enabled."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            permissionCoordinator.openMicrophoneSettings()
        }
    }

    private func showHotkeyPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Hotkey Disabled"
        alert.informativeText = "Speak could not register the global hotkey because accessibility access is blocked. Open Permissions Setup from the menu bar to grant Accessibility access."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func updateStatusIcon() {
        if let button = statusItem.button {
            button.image = StatusIcon.image(color: isRecording ? .systemRed : .systemGreen)
        }
    }

    private func updateToggleTitle() {
        if isTranscribing {
            toggleItem?.title = "Transcribing..."
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

    @objc private func openPermissionSetup() {
        showPermissionSetupWindow(activate: true)
    }

    @objc private func openModelSetup() {
        if modelSetupWindowController == nil {
            let controller = ModelSetupWindowController()
            controller.onComplete = { [weak self] in
                if self?.settings.prewarmOnLaunch == true {
                    self?.transcriptionRunner.prewarm()
                }
            }
            modelSetupWindowController = controller
        }
        modelSetupWindowController?.open(activate: true)
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
