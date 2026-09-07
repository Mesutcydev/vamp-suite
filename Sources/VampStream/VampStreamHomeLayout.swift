import Foundation

/// Which Mac host Stream should offer on the connect home.
enum VampStreamHostSource: String, CaseIterable, Identifiable, Equatable {
    case sync
    case assistant
    case both

    var id: String { rawValue }

    var showsSync: Bool { self != .assistant }
    var showsAssistant: Bool { self != .sync }

    var title: String {
        switch self {
        case .sync: return VampStreamHomeCopy.syncTitle
        case .assistant: return VampStreamHomeCopy.assistantTitle
        case .both: return VampStreamHomeCopy.hostSourceBothTitle
        }
    }

    var detail: String {
        switch self {
        case .sync: return VampStreamHomeCopy.hostSourceSyncDetail
        case .assistant: return VampStreamHomeCopy.hostSourceAssistantDetail
        case .both: return VampStreamHomeCopy.hostSourceBothDetail
        }
    }

    var icon: String {
        switch self {
        case .sync: return "macbook.and.iphone"
        case .assistant: return "sparkles.tv"
        case .both: return "rectangle.on.rectangle"
        }
    }
}

enum VampStreamHostSourceStore {
    static let key = "vampstream.hostSource"

    static func load(defaults: UserDefaults = .standard) -> VampStreamHostSource? {
        defaults.string(forKey: key).flatMap(VampStreamHostSource.init(rawValue:))
    }

    static func save(_ source: VampStreamHostSource, defaults: UserDefaults = .standard) {
        defaults.set(source.rawValue, forKey: key)
    }
}

enum VampStreamHomeLinks {
    static let syncDownload = URL(string: "https://thevamp.app/sync/#download")!
}

enum VampStreamSyncPromoStore {
    static let installedKey = "vampstream.syncInstalled"

    static func isInstalled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: installedKey)
    }

    static func setInstalled(_ installed: Bool, defaults: UserDefaults = .standard) {
        defaults.set(installed, forKey: installedKey)
    }
}

/// Expansion state for the two pairing cards on Stream's connect home.
///
/// Each provider gets its own key, so collapsing Vamp Sync never collapses Vamp Assistant and
/// neither is derived from array positions, IP addresses, or live reachability. The stored value
/// is tri-state: `nil` means "no explicit choice yet", which is what lets the first-run default be
/// computed once and then latched — recomputing it from discovery would flip the cards open again
/// every time a host momentarily drops off the network.
enum VampStreamPairingCardStore {
    enum Provider: String, CaseIterable {
        case sync
        case assistant

        static func key(for provider: Provider) -> String {
            "vampstream.pairingCard.\(provider.rawValue).expanded"
        }
    }

    /// The user's explicit choice, or nil when they have never toggled this card.
    static func explicitPreference(
        _ provider: Provider,
        defaults: UserDefaults = .standard
    ) -> Bool? {
        let key = Provider.key(for: provider)
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.bool(forKey: key)
    }

    static func setExpanded(
        _ expanded: Bool,
        provider: Provider,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(expanded, forKey: Provider.key(for: provider))
    }

    /// Resolve what a card should show.
    ///
    /// 1. An explicit saved preference always wins.
    /// 2. Otherwise, once any host is configured both cards start collapsed — a returning user
    ///    wants their Macs, not a setup form.
    /// 3. Otherwise this is a first run: expand the provider the user is actually setting up and
    ///    leave the other collapsed.
    static func showsExpanded(
        explicitPreference: Bool?,
        hasConfiguredHost: Bool,
        isSetupProvider: Bool
    ) -> Bool {
        if let explicitPreference { return explicitPreference }
        if hasConfiguredHost { return false }
        return isSetupProvider
    }

    /// Latch a resolved first-run default into storage so it is never recomputed from a
    /// fluctuating discovery list. Writing it makes the value an explicit preference, which is
    /// what stops the cards flipping open again the next time a host drops off the network.
    static func latchDefaultIfNeeded(
        provider: Provider,
        hasConfiguredHost: Bool,
        isSetupProvider: Bool,
        defaults: UserDefaults = .standard
    ) {
        guard explicitPreference(provider, defaults: defaults) == nil else { return }
        setExpanded(
            showsExpanded(
                explicitPreference: nil,
                hasConfiguredHost: hasConfiguredHost,
                isSetupProvider: isSetupProvider),
            provider: provider,
            defaults: defaults)
    }
}

enum VampStreamHomeCardStyle: String, CaseIterable, Equatable {
    case list
    case grid

    var toggled: VampStreamHomeCardStyle {
        self == .list ? .grid : .list
    }

    var toggleSystemImage: String {
        self == .grid ? "list.bullet" : "square.grid.2x2"
    }
}

enum VampStreamHomeCardStyleStore {
    static let key = "vampstream.homeCardStyle"

    static func load(defaults: UserDefaults = .standard) -> VampStreamHomeCardStyle {
        defaults.string(forKey: key).flatMap(VampStreamHomeCardStyle.init(rawValue:)) ?? .list
    }

    static func save(_ style: VampStreamHomeCardStyle, defaults: UserDefaults = .standard) {
        defaults.set(style.rawValue, forKey: key)
    }
}

/// Canonical order and copy for Vamp Stream's connect home.
/// The home is built from the host the user picked at onboarding.
enum VampStreamHomeLayout {
    enum Section: String, CaseIterable, Identifiable, Equatable {
        /// The two provider *pairing* cards. Both collapse to a header.
        case syncHostCard
        case assistantHostCard
        case syncMacs
        case syncEmptyHint
        case syncPromo
        case assistantError
        case assistantMacs
        /// "Pair a host" divider above the collapsible pairing cards.
        case pairHeading
        /// Subdued version/build footer. Stream has no About or settings screen, so the version
        /// string lives here instead of crowding the page title.
        case versionFooter

        var id: String { rawValue }
    }

    /// Hosts are the primary content: a returning user wants to pick a Mac, not re-read a setup
    /// form. The pairing cards therefore sit *below* the configured hosts and collapse to headers.
    ///
    /// For a first-time user with nothing configured there are no host rows, so the pairing group
    /// is all there is — and `VampStreamPairingCardStore` expands the relevant provider for them.
    static func sections(
        source: VampStreamHostSource,
        hasSyncHosts: Bool,
        hasAssistants: Bool,
        hasAssistantError: Bool,
        showsSyncPromo: Bool = true
    ) -> [Section] {
        var hosts: [Section] = []
        var pairing: [Section] = []

        if source.showsSync {
            hosts.append(hasSyncHosts ? .syncMacs : .syncEmptyHint)
            // The download promo only earns its place while Sync is not set up yet.
            if !hasSyncHosts, showsSyncPromo {
                pairing.append(.syncPromo)
            }
            pairing.append(.syncHostCard)
        }
        if source.showsAssistant {
            if hasAssistants {
                hosts.append(.assistantMacs)
            }
            // Scoped next to the Assistant hosts it refers to, never as an unrelated
            // page-wide card sitting between provider sections.
            if hasAssistantError {
                hosts.append(.assistantError)
            }
            pairing.append(.assistantHostCard)
        }

        let sections = pairing.isEmpty ? hosts : hosts + [.pairHeading] + pairing
        return sections + [.versionFooter]
    }
}

enum VampStreamHomeCopy {
    static let headerTitle = "Stream"
    static let headerSubtitle = "Choose a Mac to browse its apps."
    static let headerDetail = "Choose a trusted Mac, then open and control one app at a time."
    static let headerDetailSync = "Connect with Vamp Sync, then open and control one app at a time."
    static let headerDetailAssistant = "Pair Vamp Assistant, then open and control one app at a time."
    static let changeHost = "Change host"
    static let showGrid = "Show grid view"
    static let showList = "Show list view"
    static let pairHeading = "Pair a host"

    static let hostOnboardingTitle = "How do you connect?"
    static let hostOnboardingDetail = "Pick the Mac host you use. You can change this later."
    static let hostOnboardingContinue = "Continue"
    static let hostSourceSyncDetail = "App windows from Vamp Sync on your Mac."
    static let hostSourceAssistantDetail = "App streams from a Vamp Assistant workspace."
    static let hostSourceBothTitle = "Both"
    static let hostSourceBothDetail = "Show Vamp Sync and Vamp Assistant on the home screen."

    static let syncTitle = "Vamp Sync"
    static let syncDetail = "Scan the pairing QR on your Mac, or enter the private address shown by Vamp Sync."
    static let scanSync = "Scan Vamp Sync"
    static let scanSyncHint = "Scan a Vamp Sync pairing code"
    static let orConnectByAddress = "Or connect by address"
    static let addressPlaceholder = "Vamp Sync private address"
    static let connectByAddress = "Connect by address"
    static let addressError = "Enter the private address shown by Vamp Sync, including its port."
    static let syncMacsHeading = "Macs"
    static let lookingForSync = "Looking for Vamp Sync…"
    static let noSyncFound = "No Vamp Sync found"
    static let syncNetworkHint = "Open Vamp Sync on your Mac and keep both devices on the same LAN or private Tailscale network."
    static let retryDiscovery = "Retry discovery"
    static let unavailableSync = "A saved host is unavailable. Check that it is running and reachable on a trusted network."
    static let syncPromoEyebrow = "MAC HOST"
    static let syncPromoTitle = "Keep the host in sync."
    static let syncPromoDetail = "Download Vamp Sync for your Mac, then pair Stream with its QR code."
    static let syncPromoCTA = "Get Vamp Sync"
    static let syncPromoHint = "Opens the Vamp Sync download page"
    static let syncPromoDismiss = "Dismiss Vamp Sync promotion"
    static let syncPromoInstalledTitle = "Is Vamp Sync installed on your Mac?"
    static let syncPromoInstalledMessage = "Vamp Sync is the Mac host Stream uses. If it is already installed, this card will stop appearing. Scan QR and connect by address stay on this screen."
    static let syncPromoInstalledYes = "Yes, it’s installed"
    static let syncPromoInstalledNotYet = "Not yet"
    static let syncConnectCollapse = "Minimize Vamp Sync connection"
    static let syncConnectExpand = "Show Vamp Sync connection"
    static let syncConnectCollapsedDetail = "Scan QR or connect by address"

    static let assistantConnectCollapse = "Minimize Vamp Assistant pairing"
    static let assistantConnectExpand = "Show Vamp Assistant pairing"
    static let assistantConnectCollapsedDetail = "Connect an Assistant workspace"

    static let assistantTitle = "Vamp Assistant"
    static let assistantDetail = "Pair a workspace when you want app streams from Vamp Assistant."
    static let pairAssistant = "Pair Vamp Assistant"
    static let pairAnotherAssistant = "Pair another Assistant"
    static let pairAssistantHint = "Enter the private address and one-time pairing code shown by Vamp Assistant"
    static let assistantMacsHeading = "Assistant Macs"

    static func headerDetail(for source: VampStreamHostSource) -> String {
        switch source {
        case .sync: return headerDetailSync
        case .assistant: return headerDetailAssistant
        case .both: return headerDetail
        }
    }

    static func pairAssistantTitle(hasSavedAssistants: Bool) -> String {
        hasSavedAssistants ? pairAnotherAssistant : pairAssistant
    }
}
