import Foundation
import SharedModels

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
}

/// Vamp Sync Macs the user removed from the home. Discovery keeps re-announcing a Mac that is on
/// the network, so deleting only its saved record would bring it straight back. The removal is
/// remembered by the Mac's stable identity (host ID and key fingerprint) until the user adds that
/// Mac again by QR code or address.
enum VampStreamForgottenHosts {
    static let key = "vampstream.forgottenSyncHosts"

    static func identities(hostID: UUID, fingerprint: String?) -> Set<String> {
        var ids: Set<String> = [hostID.uuidString]
        let fingerprint = fingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let fingerprint, !fingerprint.isEmpty { ids.insert(fingerprint) }
        return ids
    }

    static func decode(_ raw: String) -> Set<String> {
        Set(raw.split(separator: "\n").map(String.init))
    }

    // Pure string transforms, written back through each view's own `@AppStorage`. A direct
    // `UserDefaults.set` is not observed by `@AppStorage` for a dotted key (KVO reads the dot as
    // a key path), so the list would only update after a relaunch.
    static func forgetting(_ ids: Set<String>, in raw: String) -> String {
        encode(decode(raw).union(ids))
    }

    static func restoring(_ ids: Set<String>, in raw: String) -> String {
        encode(decode(raw).subtracting(ids))
    }

    private static func encode(_ ids: Set<String>) -> String {
        ids.sorted().joined(separator: "\n")
    }
}

enum VampStreamHomeLinks {
    static let syncDownload = VampProductLinks.syncDownload
}

enum VampStreamSyncPromoStore {
    static let installedKey = "vampstream.syncInstalled"
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
        /// A Sync connection failure, scoped to the Sync hosts rather than shown as an
        /// Assistant error or as an unrelated page-wide card.
        case syncError
        case assistantMacs
        /// "Connect a Mac" divider above the collapsible pairing cards.
        case pairHeading
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
        hasSyncError: Bool = false,
        showsSyncPromo: Bool = true
    ) -> [Section] {
        var hosts: [Section] = []
        var pairing: [Section] = []

        if source.showsSync {
            hosts.append(hasSyncHosts ? .syncMacs : .syncEmptyHint)
            // Scoped next to the Sync hosts it refers to. A Sync failure used to fall through
            // into the Assistant error slot, labelling a Vamp Sync problem as an Assistant one.
            if hasSyncError {
                hosts.append(.syncError)
            }
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

        guard !pairing.isEmpty else { return hosts }
        return hosts + [.pairHeading] + pairing
    }
}

/// Copy and detection for the host-busy rejection.
///
/// The two providers fail through different objects — Assistant through its own session view
/// model, Sync through the shared session coordinator — so the coordinator's message is routed to
/// the Sync slot rather than merged into the Assistant one. That merge is what used to label a
/// Vamp Sync problem as a Vamp Assistant problem.
enum VampStreamHostBusy {
    /// "Mac is in use" is a per-host condition: one busy Mac must not disable the others, so the
    /// message is scoped to the host that refused and phrased as something the user can act on.
    static let title = "Mac is in use"
    static let detail = "Disconnect the other device, then try again."

    /// Recognises the host-busy rejection. The coordinator emits a single well-known sentence for
    /// it; matching on that keeps the compact host-scoped copy instead of repeating the long one.
    static func isHostBusy(_ message: String?) -> Bool {
        guard let message else { return false }
        let lower = message.lowercased()
        return lower.contains("already connected to another device")
            || lower.contains("in use")
            || lower.contains("another client")
    }
}

enum VampStreamHomeCopy {
    static let headerTitle = "Stream"
    static let headerSubtitle = "Choose a Mac to browse its apps."
    static let settings = "Settings"
    static let showGrid = "Show grid view"
    static let showList = "Show list view"
    static let pairHeading = "Connect a Mac"

    static let hostOnboardingTitle = "Connect your Mac"
    static let hostOnboardingDetail = "Choose the app installed on your Mac. You can change this later."
    static let hostOnboardingContinue = "Continue"
    static let hostOnboardingPrompt = "Select your Mac app to continue."
    static let hostOnboardingNearbyTitle = "\(VampProductIdentity.syncName) Macs found nearby"
    static let hostOnboardingNearbyDetail = "Approve new devices on your Mac."
    static let hostSourceSyncDetail = "App windows from \(VampProductIdentity.syncName) on your Mac."
    static let hostSourceAssistantDetail = "App streams from a Vamp Assistant workspace."
    static let hostSourceBothTitle = "Both"
    static let hostSourceBothDetail = "Show \(VampProductIdentity.syncName) and Vamp Assistant on the home screen."

    static let syncTitle = "\(VampProductIdentity.syncName)"
    static let syncDetail = "Scan the pairing QR on your Mac, or enter the private address shown by \(VampProductIdentity.syncName)."
    static let scanSync = "Scan \(VampProductIdentity.syncName)"
    static let scanSyncHint = "Scan a \(VampProductIdentity.syncName) pairing code"
    static let orConnectByAddress = "Or connect by address"
    static let addressPlaceholder = "\(VampProductIdentity.syncName) private address"
    static let connectByAddress = "Connect by address"
    static let addressError = "Enter the private address shown by \(VampProductIdentity.syncName), including its port."
    static let syncMacsHeading = "Macs"
    static let lookingForSync = "Looking for \(VampProductIdentity.syncName)…"
    static let noSyncFound = "No \(VampProductIdentity.syncName) found"
    static var syncNetworkHint: String {
        VampProductIdentity.isStoreDistribution
            ? "Open App Sync or Vamp Sync on your own Mac and keep both devices on the same Wi-Fi or Ethernet network."
            : "Open Vamp Sync on your Mac and keep both devices on the same LAN or private Tailscale network."
    }
    static let retryDiscovery = "Retry discovery"
    static let unavailableSync = "A saved host is unavailable. Check that it is running and reachable on a trusted network."
    static let syncPromoEyebrow = "MAC HOST"
    static let syncPromoTitle = "Keep the host in sync."
    static let syncPromoDetail = "Download \(VampProductIdentity.syncName) for your Mac, then pair Stream with its QR code."
    static let syncPromoCTA = "Get \(VampProductIdentity.syncName)"
    static let syncPromoHint = "Opens the \(VampProductIdentity.syncName) download page"
    static let syncPromoDismiss = "Dismiss \(VampProductIdentity.syncName) promotion"
    static let syncPromoInstalledTitle = "Is \(VampProductIdentity.syncName) installed on your Mac?"
    static let syncPromoInstalledMessage = "\(VampProductIdentity.syncName) is the Mac host Stream uses. If it is already installed, this card will stop appearing. Scan QR and connect by address stay on this screen."
    static let syncPromoInstalledYes = "Yes, it’s installed"
    static let syncPromoInstalledNotYet = "Not yet"
    static let syncConnectCollapse = "Minimize \(VampProductIdentity.syncName) connection"
    static let syncConnectExpand = "Show \(VampProductIdentity.syncName) connection"
    static let syncConnectCollapsedDetail = "Scan QR or connect by address"

    static let assistantConnectCollapse = "Minimize Vamp Assistant pairing"
    static let assistantConnectExpand = "Show Vamp Assistant pairing"
    static let assistantConnectCollapsedDetail = "Connect an Assistant workspace"

    static let assistantTitle = "Vamp Assistant"
    static let assistantDetail = "Pair your Mac to browse and stream its apps."
    static let pairAssistant = "Pair Vamp Assistant"
    static let pairAnotherAssistant = "Pair another Assistant"
    static let pairAssistantHint = "Enter the private address and one-time pairing code shown by Vamp Assistant"
    static let assistantMacsHeading = "Assistant Macs"

    static func pairAssistantTitle(hasSavedAssistants: Bool) -> String {
        hasSavedAssistants ? pairAnotherAssistant : pairAssistant
    }
}
