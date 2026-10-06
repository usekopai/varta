import AppKit
import VartaCore

/// Keeps the status button clickable while model preparation is visible.
private final class MenuSpinner: NSProgressIndicator {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class SpeechMenuIndicator {
    private weak var button: NSStatusBarButton?
    private let logo: NSImage?
    private let spinner = MenuSpinner()
    private var state: SpeechPreparation = .preparing
    private var accessibilityObserver: NSObjectProtocol?

    init(button: NSStatusBarButton) {
        self.button = button
        logo = button.image
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16)
        ])
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.update(self.state)
        }
    }

    deinit {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    func update(_ state: SpeechPreparation) {
        self.state = state
        button?.toolTip = "Varta — \(state.status)"
        button?.setAccessibilityLabel("Varta")
        button?.setAccessibilityValue(state.status)
        if state.isBusy && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            button?.image = nil
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            if state.isBusy {
                button?.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: state.status)
            } else if case .failed = state {
                button?.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: state.status)
            } else {
                button?.image = logo
            }
        }
    }
}
