import Cocoa
import AVFoundation

final class PermissionSetupWindowController: NSWindowController {
    var onRequestMicrophone: (() -> Void)?
    var onRequestAccessibility: (() -> Void)?
    var onContinue: (() -> Void)?

    private let microphoneStatusLabel = NSTextField(labelWithString: "")
    private let accessibilityStatusLabel = NSTextField(labelWithString: "")

    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    private let microphoneButton = NSButton(title: "Grant Microphone", target: nil, action: nil)
    private let accessibilityButton = NSButton(title: "Enable Accessibility", target: nil, action: nil)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Speak Permissions"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refreshStatuses() {
        updateMicrophoneStatus(AVCaptureDevice.authorizationStatus(for: .audio))
        updateAccessibilityStatus(AccessibilityHelper.isTrusted())
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
            root.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20)
        ])

        let title = NSTextField(labelWithString: "Allow Permissions for Speak")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.alignment = .left
        root.addArrangedSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString: "Speak needs Microphone and Accessibility to record audio and use the global hotkey.")
        subtitle.alignment = .left
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 0
        root.addArrangedSubview(subtitle)

        microphoneButton.bezelStyle = .rounded
        accessibilityButton.bezelStyle = .rounded
        microphoneButton.target = self
        microphoneButton.action = #selector(microphonePressed)
        accessibilityButton.target = self
        accessibilityButton.action = #selector(accessibilityPressed)

        let grid = NSGridView(views: [
            [makePermissionInfo(title: "Microphone", detail: "Lets Speak capture your voice for local transcription.", statusLabel: microphoneStatusLabel), microphoneButton],
            [makePermissionInfo(title: "Accessibility", detail: "Lets Speak listen for your hotkey and paste text at your cursor.", statusLabel: accessibilityStatusLabel), accessibilityButton]
        ])
        grid.columnSpacing = 14
        grid.rowSpacing = 10
        grid.xPlacement = .fill
        grid.yPlacement = .center
        grid.column(at: 0).xPlacement = .fill
        grid.column(at: 1).xPlacement = .trailing
        grid.column(at: 1).width = 170
        root.addArrangedSubview(grid)

        let footer = NSTextField(wrappingLabelWithString: "You can change these later in System Settings.")
        footer.alignment = .left
        footer.textColor = .tertiaryLabelColor
        footer.maximumNumberOfLines = 0
        root.addArrangedSubview(footer)

        continueButton.target = self
        continueButton.action = #selector(continuePressed)
        continueButton.bezelStyle = .rounded
        continueButton.keyEquivalent = "\r"

        let buttonRow = NSStackView(views: [NSView(), continueButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(buttonRow)

        refreshStatuses()
    }

    private func makePermissionInfo(title: String, detail: String, statusLabel: NSTextField) -> NSView {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 14, weight: .semibold)
        header.alignment = .left

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.alignment = .left
        detailLabel.maximumNumberOfLines = 0

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.alignment = .left

        let stack = NSStackView(views: [header, detailLabel, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func updateMicrophoneStatus(_ status: AVAuthorizationStatus) {
        switch status {
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
    }

    private func updateAccessibilityStatus(_ trusted: Bool) {
        if trusted {
            accessibilityStatusLabel.stringValue = "Accessibility: Allowed"
            accessibilityStatusLabel.textColor = .systemGreen
        } else {
            accessibilityStatusLabel.stringValue = "Accessibility: Not allowed"
            accessibilityStatusLabel.textColor = .systemOrange
        }
    }

    @objc private func microphonePressed() {
        onRequestMicrophone?()
    }

    @objc private func accessibilityPressed() {
        onRequestAccessibility?()
    }

    @objc private func continuePressed() {
        onContinue?()
        close()
    }
}
