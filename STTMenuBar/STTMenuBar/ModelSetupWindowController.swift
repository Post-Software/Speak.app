import Cocoa

final class ModelSetupWindowController: NSWindowController {
    var onComplete: (() -> Void)?

    private let modelManager = ModelManager.shared

    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let optionLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let runtimeLabel = NSTextField(labelWithString: "")
    private let consentCheckbox = NSButton(checkboxWithTitle: "Download this model now", target: nil, action: nil)
    private let actionButton = NSButton(title: "Continue", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")

    private var currentInfo: RemoteModelInfo?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Select your model"
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        buildUI()
        refreshModelInfo()
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
        refreshModelInfo()
    }

    private var selectedVariant: ModelVariant {
        let idx = max(0, picker.indexOfSelectedItem)
        return ModelCatalog.all[idx]
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
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            root.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24)
        ])

        let title = NSTextField(labelWithString: "Set Up Speak")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        root.addArrangedSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString: "Choose your model once, and Speak will finish setup. Most people should keep the recommended option.")
        subtitle.maximumNumberOfLines = 0
        subtitle.textColor = .secondaryLabelColor
        root.addArrangedSubview(subtitle)

        picker.addItems(withTitles: ModelCatalog.all.map { $0.displayName })
        picker.target = self
        picker.action = #selector(modelSelectionChanged)
        picker.selectItem(at: currentInitialSelectionIndex())
        root.addArrangedSubview(picker)

        optionLabel.maximumNumberOfLines = 0
        optionLabel.font = .systemFont(ofSize: 13, weight: .medium)

        sizeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        runtimeLabel.textColor = .secondaryLabelColor
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 0

        root.addArrangedSubview(optionLabel)
        root.addArrangedSubview(sizeLabel)
        root.addArrangedSubview(runtimeLabel)
        root.addArrangedSubview(statusLabel)

        consentCheckbox.target = self
        consentCheckbox.action = #selector(consentChanged)
        root.addArrangedSubview(consentCheckbox)

        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        spinner.controlSize = .regular

        actionButton.target = self
        actionButton.action = #selector(installSelectedModel)
        actionButton.isEnabled = false

        let controls = NSStackView(views: [spinner, NSView(), actionButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 12
        root.addArrangedSubview(controls)

        updateSelectionCopy()
    }

    private func currentInitialSelectionIndex() -> Int {
        guard let active = modelManager.manifest.activeModelID,
              let idx = ModelCatalog.all.firstIndex(where: { $0.id == active }) else {
            return 0
        }
        return idx
    }

    @objc private func consentChanged() {
        actionButton.isEnabled = consentCheckbox.state == .on && currentInfo != nil
    }

    @objc private func modelSelectionChanged() {
        consentCheckbox.state = .off
        actionButton.isEnabled = false
        updateSelectionCopy()
        refreshModelInfo()
    }

    private func updateSelectionCopy() {
        let variant = selectedVariant
        optionLabel.stringValue = variant.plainDescription
        if variant.isRecommended {
            actionButton.title = "Use Recommended Model"
        } else {
            actionButton.title = "Use Better Accuracy Model"
        }
    }

    private func refreshModelInfo() {
        currentInfo = nil
        sizeLabel.stringValue = "Checking exact download size..."
        runtimeLabel.stringValue = ""
        statusLabel.stringValue = ""

        modelManager.fetchRemoteInfo(for: selectedVariant) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let info):
                self.currentInfo = info
                self.modelManager.recordModelSize(id: info.id, bytes: info.downloadBytes)
                self.sizeLabel.stringValue = "Download size: \(ByteCountFormatter.string(fromByteCount: info.downloadBytes, countStyle: .file))"
                self.runtimeLabel.stringValue = "Estimated memory while running: \(ByteCountFormatter.string(fromByteCount: info.estimatedRuntimeMemoryBytes, countStyle: .memory))"
                self.statusLabel.stringValue = ""
                self.statusLabel.textColor = .secondaryLabelColor
                self.actionButton.isEnabled = self.consentCheckbox.state == .on
            case .failure:
                self.statusLabel.textColor = .systemRed
                self.statusLabel.stringValue = "Could not check model size right now. Please check your internet connection and try again."
            }
        }
    }

    @objc private func installSelectedModel() {
        guard consentCheckbox.state == .on else { return }

        let variant = selectedVariant
        let oldModelID = modelManager.manifest.activeModelID
        var deletePreviousModelID: String?

        if let oldModelID,
           oldModelID != variant.id,
           modelManager.isInstalled(modelID: oldModelID) {
            let alert = NSAlert()
            alert.messageText = "Keep the previous model?"
            alert.informativeText = "You can keep the old model for quick switching, or remove it to save disk space."
            alert.addButton(withTitle: "Keep It")
            alert.addButton(withTitle: "Remove It")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            if response == .alertThirdButtonReturn {
                return
            }
            if response == .alertSecondButtonReturn {
                deletePreviousModelID = oldModelID
            }
        }

        spinner.startAnimation(nil)
        actionButton.isEnabled = false
        picker.isEnabled = false
        consentCheckbox.isEnabled = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Downloading and preparing your model..."

        modelManager.installModel(variant: variant, deletePreviousModelID: deletePreviousModelID) { [weak self] result in
            guard let self else { return }
            self.spinner.stopAnimation(nil)
            self.picker.isEnabled = true
            self.consentCheckbox.isEnabled = true
            self.actionButton.isEnabled = self.consentCheckbox.state == .on

            switch result {
            case .success:
                self.statusLabel.textColor = .systemGreen
                self.statusLabel.stringValue = "Setup complete. Speak is ready."
                self.onComplete?()
                self.close()
            case .failure:
                self.statusLabel.textColor = .systemRed
                self.statusLabel.stringValue = "Download failed. Please try again."
            }
        }
    }
}
