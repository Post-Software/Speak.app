import Cocoa
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let hotKeyMonitor = HotKeyMonitor()
    private let audioRecorder = AudioRecorder()
    private let soundPlayer = SystemSoundPlayer()
    private let transcriptionRunner: TranscriptionRunner
    private let pasteController = PasteController()
    private let settings = Settings.shared
    private let permissionCoordinator: PermissionCoordinating
    private let modelManager: ModelManaging
    private let updateController: UpdateChecking

    private var isRecording = false
    private var isTranscribing = false
    private var currentRecordingURL: URL?
    private var recordingStartedAt: Date?

    private var setupWizardWindowController: SetupWizardWindowController?

    private var toggleItem: NSMenuItem?
    private var soundsItem: NSMenuItem?
    private let launchEnvironment = ProcessInfo.processInfo.environment

    override init() {
        self.permissionCoordinator = PermissionCoordinator()
        self.modelManager = ModelManager.shared
        self.transcriptionRunner = TranscriptionRunner(modelManager: ModelManager.shared)
        self.updateController = UpdateController()
        super.init()
    }

    init(
        permissionCoordinator: PermissionCoordinating,
        modelManager: ModelManaging,
        transcriptionRunner: TranscriptionRunner,
        updateController: UpdateChecking = UpdateController()
    ) {
        self.permissionCoordinator = permissionCoordinator
        self.modelManager = modelManager
        self.transcriptionRunner = transcriptionRunner
        self.updateController = updateController
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureHotKeyCallbacks()

        if needsInitialSetup {
            showSetupWizard(activate: true)
        } else {
            completeLaunchAfterSetup()
        }

        runUITestLaunchHooksIfNeeded()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        setupWizardWindowController?.refreshState()
        refreshHotKeyRegistration()
    }

    private var needsInitialSetup: Bool {
        !permissionCoordinator.hasAllRequiredPermissions() || modelManager.needsSetup()
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

        statusItem.menu = buildStatusMenu()
    }

    func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()

        let toggle = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "")
        toggle.target = self
        toggleItem = toggle
        menu.addItem(toggle)

        let setup = NSMenuItem(title: "Run Setup & Select Model", action: #selector(openSetupWizard), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)

        let checkForUpdatesItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForAppUpdates), keyEquivalent: "")
        checkForUpdatesItem.target = self
        checkForUpdatesItem.isEnabled = true
        menu.addItem(checkForUpdatesItem)

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

        return menu
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
        guard permissionCoordinator.accessibilityTrusted else {
            permissionCoordinator.requestAccessibilityAccess()
            showSetupWizard(activate: true)
            return
        }

        permissionCoordinator.requestMicrophoneAccess { [weak self] granted in
            guard let self else { return }

            guard granted else {
                if self.permissionCoordinator.microphoneStatus == .denied || self.permissionCoordinator.microphoneStatus == .restricted {
                    self.permissionCoordinator.openMicrophoneSettings()
                }
                self.showSetupWizard(activate: true)
                return
            }

            guard self.modelManager.needsSetup() == false else {
                self.showSetupWizard(activate: true)
                return
            }

            self.transcriptionRunner.cancel()
            self.setTranscribing(false)

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
                NSLog("Failed to start recording: %@", error.localizedDescription)
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
                self.handleTranscriptionError(error)
            }
        }
    }

    static func shouldRouteParakeetFailureToSetup(message: String) -> Bool {
        if message.contains("setup_required:") {
            return true
        }

        guard message.contains("parakeet") else { return false }
        let setupRecoverableSignals = [
            "not supported",
            "model directory is missing",
            "could not locate downloaded parakeet model artifacts",
            "bundled parakeet worker is missing"
        ]
        return setupRecoverableSignals.contains(where: { message.contains($0) })
    }

    private func handleTranscriptionError(_ error: Error) {
        if let runnerError = error as? TranscriptionRunner.RunnerError,
           runnerError == .modelSetupRequired {
            showSetupWizard(activate: true)
            return
        }

        let message = error.localizedDescription.lowercased()
        if Self.shouldRouteParakeetFailureToSetup(message: message) {
            showSetupWizard(activate: true)
            return
        }

        NSLog("Transcription failed: %@", error.localizedDescription)
        if isUITestMode {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Transcription Failed"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private var isUITestMode: Bool {
        launchEnvironment["SPEAK_UI_TEST_MODE"] == "1"
    }

    private func runUITestLaunchHooksIfNeeded() {
        guard isUITestMode else { return }

        guard let simulatedError = launchEnvironment["SPEAK_UI_SIMULATE_TRANSCRIPTION_ERROR"],
              simulatedError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            let error = NSError(
                domain: "Speak.UITest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: simulatedError]
            )
            self.handleTranscriptionError(error)
        }
    }

    private func completeLaunchAfterSetup() {
        refreshHotKeyRegistration()

        if settings.prewarmOnLaunch && modelManager.needsSetup() == false {
            transcriptionRunner.prewarm()
        }
    }

    private func refreshHotKeyRegistration() {
        hotKeyMonitor.stop()
        guard permissionCoordinator.accessibilityTrusted else { return }
        hotKeyMonitor.start()
    }

    private func ensureSetupWizard() {
        if setupWizardWindowController == nil {
            let controller = SetupWizardWindowController(
                permissionCoordinator: permissionCoordinator,
                modelManager: modelManager
            )
            controller.onSetupCompleted = { [weak self] in
                self?.completeLaunchAfterSetup()
            }
            setupWizardWindowController = controller
        }
    }

    private func showSetupWizard(activate: Bool) {
        ensureSetupWizard()
        setupWizardWindowController?.open(activate: activate)
    }

    private func showHotkeyPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Hotkey Disabled"
        alert.informativeText = "Speak could not register the global hotkey because accessibility access is blocked. Open setup and enable Accessibility access."
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
        if settings.prewarmOnLaunch && modelManager.needsSetup() == false {
            transcriptionRunner.prewarm()
        }
    }

    @objc private func openSetupWizard() {
        showSetupWizard(activate: true)
    }

    @objc func checkForAppUpdates() {
        updateController.checkForUpdates()
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
