import AppKit
import Combine
import OSLog

/// Owns the optional status item outside SwiftUI's scene graph. The icon is
/// resolved once, retained, and assigned once per status-item installation.
@MainActor
final class MacMenuBarController: NSObject, ObservableObject {
    private static let templateImage: NSImage? = {
        let image = NSImage(
            systemSymbolName: "display",
            accessibilityDescription: "Vamp Control"
        )
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        return image
    }()

    private let logger = Logger(
        subsystem: "com.mesutcy.remotedesktop.client",
        category: "MenuBar"
    )
    private var statusItem: NSStatusItem?
    private weak var environment: ClientAppEnvironment?
    private weak var coordinator: ClientSessionCoordinator?
    private var subscriptions = Set<AnyCancellable>()
    private var stateGate = MacMenuBarStateGate()
    private var currentHostName: String?

    #if DEBUG
    private(set) var iconAssignmentCount = 0
    private(set) var effectiveSemanticUpdateCount = 0
    #endif

    func configure(environment: ClientAppEnvironment) {
        guard self.environment !== environment else { return }
        self.environment = environment
        coordinator = environment.sessionCoordinator
        subscriptions.removeAll()

        environment.sessionCoordinator.$phase
            .map(Self.semanticState(for:))
            .removeDuplicates()
            .sink { [weak self] state in self?.apply(state) }
            .store(in: &subscriptions)

        environment.sessionCoordinator.$connectedHostName
            .removeDuplicates()
            .sink { [weak self] hostName in
                guard let self, currentHostName != hostName else { return }
                currentHostName = hostName
                refreshTextOnly()
            }
            .store(in: &subscriptions)
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            installIfNeeded()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            logger.debug("Status item removed")
        }
    }

    func apply(_ newState: MacMenuBarSemanticState) {
        guard stateGate.accept(newState) else { return }
        #if DEBUG
        effectiveSemanticUpdateCount += 1
        #endif
        refreshTextOnly()
        logger.debug("Semantic state changed")
    }

    static func semanticState(
        for phase: ClientSessionCoordinator.SessionPhase
    ) -> MacMenuBarSemanticState {
        switch phase {
        case .idle:
            return .disconnected
        case .connecting, .signalingConnected, .negotiating, .waitingForMedia:
            return .connecting
        case .receiving:
            return .connected
        case .error:
            return .warning
        }
    }

    private func installIfNeeded() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        guard let button = item.button else { return }
        button.image = Self.templateImage
        button.imagePosition = .imageOnly
        #if DEBUG
        iconAssignmentCount += 1
        #endif
        item.menu = makeMenu()
        refreshTextOnly()
        logger.debug("Status item installed; icon assigned once")
    }

    private func refreshTextOnly() {
        guard let statusItem else { return }
        statusItem.button?.toolTip = tooltip
        if let status = statusItem.menu?.item(at: 0) {
            status.title = tooltip
        }
        statusItem.menu?.item(withTag: 2)?.isEnabled = stateGate.current != .disconnected
    }

    private var tooltip: String {
        switch stateGate.current ?? .disconnected {
        case .disconnected:
            return "Vamp Control — Disconnected"
        case .connecting:
            return "Vamp Control — Connecting"
        case .connected:
            if let currentHostName, !currentHostName.isEmpty {
                return "Vamp Control — Connected to \(currentHostName)"
            }
            return "Vamp Control — Connected"
        case .warning:
            return "Vamp Control — Attention Required"
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Connection Controls")
        let status = NSMenuItem(title: tooltip, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let show = NSMenuItem(
            title: "Show Vamp Control",
            action: #selector(showApplication),
            keyEquivalent: ""
        )
        show.target = self
        show.tag = 1
        menu.addItem(show)

        let disconnect = NSMenuItem(
            title: "Disconnect",
            action: #selector(disconnectSession),
            keyEquivalent: ""
        )
        disconnect.target = self
        disconnect.tag = 2
        menu.addItem(disconnect)
        return menu
    }

    @objc private func showApplication() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: \.canBecomeKey)?.makeKeyAndOrderFront(nil)
    }

    @objc private func disconnectSession() {
        guard let coordinator else { return }
        Task { await coordinator.endSession() }
    }
}
