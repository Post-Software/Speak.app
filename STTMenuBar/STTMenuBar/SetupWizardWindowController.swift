import Cocoa
import AVFoundation

final class SetupWizardWindowController: NSWindowController {
    var onSetupCompleted: (() -> Void)?

    private let permissionCoordinator: PermissionCoordinating
    private let modelManager: ModelManaging

    private let microphoneStatusLabel = NSTextField(labelWithString: "")
    private let accessibilityStatusLabel = NSTextField(labelWithString: "")
    private let modelStatusLabel = NSTextField(labelWithString: "")

    private let microphoneButton = NSButton(title: "Grant Microphone", target: nil, action: nil)
    private let accessibilityButton = NSButton(title: "Enable Accessibility", target: nil, action: nil)

    private let modelPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelDescriptionLabel = NSTextField(labelWithString: "")
    private let modelSizeLabel = NSTextField(labelWithString: "")
    private let modelSizeBadgeLabel = NSTextField(labelWithString: "Estimated")
    private let consentCheckbox = NSButton(checkboxWithTitle: "I agree to download this model", target: nil, action: nil)
    private let downloadButton = NSButton(title: "Download & Activate", target: nil, action: nil)
    private let modelSpinner = NSProgressIndicator()

    private var currentInfo: RemoteModelInfo?
    private var currentInfoFetchID = UUID()
    private var modelSelectionNotice: String?
    private var hasNotifiedCompletion = false

    init(permissionCoordinator: PermissionCoordinating, modelManager: ModelManaging) {
        self.permissionCoordinator = permissionCoordinator
        self.modelManager = modelManager

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 510),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Speak Setup"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 510)
        window.maxSize = NSSize(width: 840, height: 1200)

        super.init(window: window)
        buildUI()
        refreshState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func open(activate: Bool) {
        showWindow(nil)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
        }
        refreshState()
    }

    func refreshState() {
        updatePermissionStatusLabels()
        updateModelSectionAvailability()

        if permissionsGranted {
            refreshModelInfo()
        } else {
            currentInfo = nil
            modelSizeLabel.stringValue = "Complete Step 1 first."
            modelSizeBadgeLabel.isHidden = true
            modelStatusLabel.stringValue = ""
            downloadButton.isEnabled = false
        }

        if setupIsComplete {
            modelStatusLabel.textColor = .systemGreen
            modelStatusLabel.stringValue = "Setup complete. Speak is ready."
            if hasNotifiedCompletion == false {
                hasNotifiedCompletion = true
                onSetupCompleted?()
            }
        } else {
            hasNotifiedCompletion = false
        }
    }

    private var permissionsGranted: Bool {
        permissionCoordinator.hasAllRequiredPermissions()
    }

    private var setupIsComplete: Bool {
        permissionsGranted && !modelManager.needsSetup()
    }

    private var selectedVariant: ModelVariant {
        let index = max(0, modelPicker.indexOfSelectedItem)
        return ModelCatalog.all[index]
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            root.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -22)
        ])

        let titleLabel = NSTextField(labelWithString: "Set Up Speak")
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        root.addArrangedSubview(titleLabel)

        let subtitleLabel = NSTextField(wrappingLabelWithString: "Finish permissions and choose a local model before recording. Speak keeps one model installed at a time to save disk space.")
        subtitleLabel.maximumNumberOfLines = 0
        subtitleLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(subtitleLabel)

        let permissionsHeader = NSTextField(labelWithString: "Step 1: Permissions")
        permissionsHeader.font = .systemFont(ofSize: 16, weight: .semibold)
        root.addArrangedSubview(permissionsHeader)

        microphoneButton.target = self
        microphoneButton.action = #selector(requestMicrophone)
        microphoneButton.identifier = NSUserInterfaceItemIdentifier("setup.microphoneButton")
        microphoneButton.setAccessibilityIdentifier("setup.microphoneButton")
        accessibilityButton.target = self
        accessibilityButton.action = #selector(requestAccessibility)
        accessibilityButton.identifier = NSUserInterfaceItemIdentifier("setup.accessibilityButton")
        accessibilityButton.setAccessibilityIdentifier("setup.accessibilityButton")

        let permissionsGrid = NSGridView(views: [
            [permissionInfoBlock(title: "Microphone", detail: "Required to capture your voice for transcription.", statusLabel: microphoneStatusLabel), microphoneButton],
            [permissionInfoBlock(title: "Accessibility", detail: "Required for global hotkey and automatic paste.", statusLabel: accessibilityStatusLabel), accessibilityButton]
        ])
        permissionsGrid.columnSpacing = 14
        permissionsGrid.rowSpacing = 16
        permissionsGrid.column(at: 0).xPlacement = .fill
        permissionsGrid.column(at: 1).xPlacement = .trailing
        permissionsGrid.column(at: 1).width = 180
        root.addArrangedSubview(permissionsGrid)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 620).isActive = true
        root.addArrangedSubview(divider)

        let modelHeader = NSTextField(labelWithString: "Step 2: Choose a Model")
        modelHeader.font = .systemFont(ofSize: 16, weight: .semibold)
        root.addArrangedSubview(modelHeader)

        modelPicker.addItems(withTitles: ModelCatalog.all.map { $0.displayName })
        modelPicker.target = self
        modelPicker.action = #selector(modelSelectionChanged)
        modelPicker.selectItem(at: defaultModelIndex())
        modelPicker.identifier = NSUserInterfaceItemIdentifier("setup.modelPicker")
        modelPicker.setAccessibilityIdentifier("setup.modelPicker")
        root.addArrangedSubview(modelPicker)

        modelDescriptionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        modelSizeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        modelSizeBadgeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        modelSizeBadgeLabel.textColor = .systemOrange
        modelSizeBadgeLabel.isHidden = true
        modelSizeBadgeLabel.wantsLayer = true
        modelSizeBadgeLabel.alignment = .center
        modelSizeBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        modelSizeBadgeLabel.lineBreakMode = .byClipping
        modelSizeBadgeLabel.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12)
        modelSizeBadgeLabel.drawsBackground = true
        modelSizeBadgeLabel.layer?.cornerRadius = 4
        modelSizeBadgeLabel.layer?.masksToBounds = true

        modelStatusLabel.textColor = .secondaryLabelColor
        modelDescriptionLabel.identifier = NSUserInterfaceItemIdentifier("setup.modelDescription")
        modelDescriptionLabel.setAccessibilityIdentifier("setup.modelDescription")
        modelStatusLabel.identifier = NSUserInterfaceItemIdentifier("setup.modelStatus")
        modelStatusLabel.setAccessibilityIdentifier("setup.modelStatus")
        modelSizeLabel.identifier = NSUserInterfaceItemIdentifier("setup.modelSize")
        modelSizeLabel.setAccessibilityIdentifier("setup.modelSize")
        configureWrappingLabel(modelDescriptionLabel)
        configureWrappingLabel(modelSizeLabel)
        configureWrappingLabel(modelStatusLabel)

        let sizeRow = NSStackView(views: [modelSizeLabel, modelSizeBadgeLabel, NSView()])
        sizeRow.orientation = .horizontal
        sizeRow.alignment = .centerY
        sizeRow.spacing = 8

        root.addArrangedSubview(modelDescriptionLabel)
        root.addArrangedSubview(sizeRow)
        root.addArrangedSubview(modelStatusLabel)
        NSLayoutConstraint.activate([
            modelDescriptionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
            sizeRow.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
            modelSizeLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            modelSizeBadgeLabel.widthAnchor.constraint(equalToConstant: 72),
            modelSizeBadgeLabel.heightAnchor.constraint(equalToConstant: 18),
            modelStatusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 620)
        ])

        consentCheckbox.target = self
        consentCheckbox.action = #selector(consentChanged)
        consentCheckbox.identifier = NSUserInterfaceItemIdentifier("setup.consentCheckbox")
        consentCheckbox.setAccessibilityIdentifier("setup.consentCheckbox")
        root.addArrangedSubview(consentCheckbox)

        modelSpinner.style = .spinning
        modelSpinner.isDisplayedWhenStopped = false

        downloadButton.target = self
        downloadButton.action = #selector(downloadSelectedModel)
        downloadButton.isEnabled = false
        downloadButton.identifier = NSUserInterfaceItemIdentifier("setup.downloadButton")
        downloadButton.setAccessibilityIdentifier("setup.downloadButton")

        let controls = NSStackView(views: [modelSpinner, NSView(), downloadButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 12
        root.addArrangedSubview(controls)

        updateModelDescriptionAndButtonLabel()
    }

    private func permissionInfoBlock(title: String, detail: String, statusLabel: NSTextField) -> NSView {
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 14, weight: .semibold)

        let detailField = NSTextField(wrappingLabelWithString: detail)
        detailField.font = .systemFont(ofSize: 12)
        detailField.textColor = .secondaryLabelColor

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)

        let stack = NSStackView(views: [titleField, detailField, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    private func updatePermissionStatusLabels() {
        let micStatus = permissionCoordinator.microphoneStatus
        switch micStatus {
        case .authorized:
            microphoneStatusLabel.stringValue = "Microphone: Allowed"
            microphoneStatusLabel.textColor = .systemGreen
        case .notDetermined:
            microphoneStatusLabel.stringValue = "Microphone: Not requested"
            microphoneStatusLabel.textColor = .secondaryLabelColor
        case .denied, .restricted:
            microphoneStatusLabel.stringValue = "Microphone: Blocked (enable in Settings)"
            microphoneStatusLabel.textColor = .systemOrange
        @unknown default:
            microphoneStatusLabel.stringValue = "Microphone: Unknown"
            microphoneStatusLabel.textColor = .secondaryLabelColor
        }

        if permissionCoordinator.accessibilityTrusted {
            accessibilityStatusLabel.stringValue = "Accessibility: Allowed"
            accessibilityStatusLabel.textColor = .systemGreen
        } else {
            accessibilityStatusLabel.stringValue = "Accessibility: Not allowed"
            accessibilityStatusLabel.textColor = .systemOrange
        }
    }

    private func updateModelSectionAvailability() {
        let enabled = permissionsGranted
        modelPicker.isEnabled = enabled
        consentCheckbox.isEnabled = enabled

        if !enabled {
            consentCheckbox.state = .off
        }

        downloadButton.isEnabled = enabled && consentCheckbox.state == .on && currentInfo != nil
        updateModelDescriptionAndButtonLabel()
    }

    private func defaultModelIndex() -> Int {
        if let activeID = modelManager.manifest.activeModelID,
           let activeIndex = ModelCatalog.all.firstIndex(where: { $0.id == activeID }) {
            return activeIndex
        }

        return ModelCatalog.all.firstIndex(where: { $0.id == ModelCatalog.defaultModelID }) ?? 0
    }

    private func updateModelDescriptionAndButtonLabel() {
        let variant = selectedVariant
        modelDescriptionLabel.stringValue = variant.plainDescription
        if variant.isRecommended {
            downloadButton.title = "Download Recommended"
        } else {
            downloadButton.title = "Download & Activate"
        }
    }

    private func refreshModelInfo() {
        guard permissionsGranted else { return }

        currentInfoFetchID = UUID()
        let fetchID = currentInfoFetchID
        let variant = selectedVariant

        currentInfo = nil
        modelSizeLabel.stringValue = "Checking runtime and download size..."
        modelSizeBadgeLabel.isHidden = true
        modelStatusLabel.stringValue = ""
        modelStatusLabel.textColor = .secondaryLabelColor
        downloadButton.isEnabled = false

        modelManager.checkRuntime(for: variant) { [weak self] runtimeResult in
            guard let self else { return }
            guard fetchID == self.currentInfoFetchID else { return }

            switch runtimeResult {
            case .success(let runtimeInfo):
                if variant.engine == .parakeetTDTV3 && runtimeInfo.isHardUnsupported {
                    self.applyParakeetFallback(reason: runtimeInfo.reason)
                    return
                }

                if variant.engine == .parakeetTDTV3 && runtimeInfo.requiresInstall {
                    self.modelSelectionNotice = "Additional Parakeet runtime components will be installed during setup."
                }

                self.modelManager.fetchRemoteInfo(for: self.selectedVariant) { [weak self] infoResult in
                    guard let self else { return }
                    guard fetchID == self.currentInfoFetchID else { return }

                    switch infoResult {
                    case .success(let info):
                        self.currentInfo = info
                        self.modelSizeLabel.stringValue = "Download size: \(ByteCountFormatter.string(fromByteCount: info.downloadBytes, countStyle: .file))"
                        self.modelSizeBadgeLabel.isHidden = (info.sizeSource == .exact)

                        if let notice = self.modelSelectionNotice {
                            self.modelStatusLabel.stringValue = notice
                            self.modelStatusLabel.textColor = .systemOrange
                        } else {
                            self.modelStatusLabel.stringValue = ""
                            self.modelStatusLabel.textColor = .secondaryLabelColor
                        }
                    case .failure(let error):
                        self.currentInfo = nil
                        self.modelSizeLabel.stringValue = "Download size unavailable"
                        self.modelSizeBadgeLabel.isHidden = true
                        self.modelStatusLabel.stringValue = "Could not reach model source. Check internet and try again.\n\(self.compactErrorMessage(error))"
                        self.modelStatusLabel.textColor = .systemRed
                    }

                    self.downloadButton.isEnabled = self.permissionsGranted && self.consentCheckbox.state == .on && self.currentInfo != nil
                }
            case .failure(let error):
                self.currentInfo = nil
                self.modelSizeLabel.stringValue = "Download size unavailable"
                self.modelSizeBadgeLabel.isHidden = true
                self.modelStatusLabel.stringValue = "Could not validate runtime compatibility.\n\(self.compactErrorMessage(error))"
                self.modelStatusLabel.textColor = .systemRed
                self.downloadButton.isEnabled = false
            }
        }
    }

    private func applyParakeetFallback(reason: String) {
        guard let fallbackIndex = ModelCatalog.all.firstIndex(where: { $0.id == ModelCatalog.smallEN.id }) else {
            currentInfo = nil
            modelSizeLabel.stringValue = "Download size unavailable"
            modelStatusLabel.textColor = .systemRed
            modelStatusLabel.stringValue = "Parakeet v3 is unsupported here and no fallback model is available."
            downloadButton.isEnabled = false
            return
        }

        let cleanReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanReason.isEmpty {
            modelSelectionNotice = "Parakeet v3 is unsupported on this machine. Switched to Small (Fallback)."
        } else {
            modelSelectionNotice = "Parakeet v3 is unsupported on this machine (\(cleanReason)). Switched to Small (Fallback)."
        }

        modelPicker.selectItem(at: fallbackIndex)
        updateModelDescriptionAndButtonLabel()
        consentCheckbox.state = .off
        downloadButton.isEnabled = false
        refreshModelInfo()
    }

    @objc private func requestMicrophone() {
        permissionCoordinator.requestMicrophoneAccess { [weak self] granted in
            guard let self else { return }
            if !granted && (self.permissionCoordinator.microphoneStatus == .denied || self.permissionCoordinator.microphoneStatus == .restricted) {
                self.permissionCoordinator.openMicrophoneSettings()
            }
            self.refreshState()
        }
    }

    @objc private func requestAccessibility() {
        permissionCoordinator.requestAccessibilityAccess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.refreshState()
        }
    }

    @objc private func modelSelectionChanged() {
        modelSelectionNotice = nil
        updateModelDescriptionAndButtonLabel()
        consentCheckbox.state = .off
        downloadButton.isEnabled = false
        refreshModelInfo()
    }

    @objc private func consentChanged() {
        downloadButton.isEnabled = permissionsGranted && consentCheckbox.state == .on && currentInfo != nil
    }

    @objc private func downloadSelectedModel() {
        guard permissionsGranted else {
            modelStatusLabel.textColor = .systemOrange
            modelStatusLabel.stringValue = "Complete permissions first."
            return
        }

        guard consentCheckbox.state == .on else { return }

        let variant = selectedVariant
        modelSpinner.startAnimation(nil)
        modelStatusLabel.textColor = .secondaryLabelColor
        modelStatusLabel.stringValue = "Downloading and preparing model..."

        setInstallControlsEnabled(false)

        modelManager.installModel(variant: variant) { [weak self] result in
            guard let self else { return }

            self.modelSpinner.stopAnimation(nil)
            self.setInstallControlsEnabled(true)
            self.downloadButton.isEnabled = self.permissionsGranted && self.consentCheckbox.state == .on && self.currentInfo != nil

            switch result {
            case .success:
                self.modelStatusLabel.textColor = .systemGreen
                self.modelStatusLabel.stringValue = "Setup complete. Speak is ready."
                self.onSetupCompleted?()
                self.close()
            case .failure(let error):
                self.modelStatusLabel.textColor = .systemRed
                self.modelStatusLabel.stringValue = "Model download failed. \(self.compactErrorMessage(error))"
            }
        }
    }

    private func setInstallControlsEnabled(_ enabled: Bool) {
        modelPicker.isEnabled = enabled && permissionsGranted
        consentCheckbox.isEnabled = enabled && permissionsGranted
        microphoneButton.isEnabled = enabled
        accessibilityButton.isEnabled = enabled
    }

    private func configureWrappingLabel(_ label: NSTextField) {
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let cell = label.cell as? NSTextFieldCell {
            cell.wraps = true
            cell.lineBreakMode = .byCharWrapping
            cell.truncatesLastVisibleLine = false
            cell.isScrollable = false
        }
    }

    private func compactErrorMessage(_ error: Error) -> String {
        let trimmed = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Unknown error."
        }

        let lines = trimmed
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .prefix(4)
            .joined(separator: "\n")

        if lines.count > 380 {
            return String(lines.prefix(380)) + "…"
        }
        return lines
    }

    var testSelectedModelID: String {
        selectedVariant.id
    }

    var testDownloadButtonEnabled: Bool {
        downloadButton.isEnabled
    }

    var testModelStatusText: String {
        modelStatusLabel.stringValue
    }

    func testSetConsent(agreed: Bool) {
        consentCheckbox.state = agreed ? .on : .off
        consentChanged()
    }

    func testSelectModel(id: String) {
        guard let index = ModelCatalog.all.firstIndex(where: { $0.id == id }) else { return }
        modelPicker.selectItem(at: index)
        modelSelectionChanged()
    }
}
