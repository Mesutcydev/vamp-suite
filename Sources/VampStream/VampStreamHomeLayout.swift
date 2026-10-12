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

enum VampStreamSyncConnectCardStore {
    static let collapsedKey = "vampstream.syncConnectCollapsed"

    static func showsCollapsed(isPaired: Bool, preference: Bool) -> Bool {
        isPaired && preference
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
        case syncHostCard
        case syncMacs
        case syncEmptyHint
        case syncPromo
        case assistantError
        case assistantHostCard
        case assistantMacs

        var id: String { rawValue }
    }

    static func sections(
        source: VampStreamHostSource,
        hasSyncHosts: Bool,
        hasAssistants: Bool,
        hasAssistantError: Bool,
        showsSyncPromo: Bool = true
    ) -> [Section] {
        var result: [Section] = []
        if source.showsSync {
            result.append(.syncHostCard)
            result.append(hasSyncHosts ? .syncMacs : .syncEmptyHint)
            if showsSyncPromo {
                result.append(.syncPromo)
            }
        }
        if source.showsAssistant {
            if hasAssistantError {
                result.append(.assistantError)
            }
            result.append(.assistantHostCard)
            if hasAssistants {
                result.append(.assistantMacs)
            }
        }
        return result
    }
}

enum VampStreamHomeCopy {
    static let headerTitle = "Stream an app from your Mac"
    static let headerTitleLead = "Stream an app"
    static let headerTitleTrail = "from your Mac"
    static let headerDetail = "Choose a trusted Mac, then open and control one app at a time."
    static let headerDetailSync = "Connect with Vamp Sync, then open and control one app at a time."
    static let headerDetailAssistant = "Pair Assistant or Companion, then open and control one app at a time."
    static let changeHost = "Change host"
    static let showGrid = "Show rectangular cards"
    static let showList = "Show list cards"

    static let hostOnboardingTitle = "How do you connect?"
    static let hostOnboardingDetail = "Pick the Mac host you use. You can change this later."
    static let hostOnboardingContinue = "Continue"
    static let hostSourceSyncDetail = "App windows from Vamp Sync on your Mac."
    static let hostSourceAssistantDetail = "App streams from Vamp Assistant or Vamp Companion on your Mac."
    static let hostSourceBothTitle = "Both"
    static let hostSourceBothDetail = "Show Sync, Assistant, and Companion hosts on the home screen."

    static let syncTitle = "Vamp Sync"
    static let syncDetail = "Scan the pairing QR on your Mac, or enter the private address shown by Vamp Sync."
    static let scanSync = "Scan Vamp Sync"
    static let scanSyncHint = "Scan a Vamp Sync pairing code"
    static let orConnectByAddress = "Or connect by address"
    static let addressPlaceholder = "Vamp Sync private address"
    static let connectByAddress = "Connect by address"
    static let addressError = "Enter the private address shown by Vamp Sync, including its port."
    static let syncMacsHeading = "VAMP SYNC MACS"
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

    static let assistantTitle = "Assistant / Companion"
    static let assistantDetail = "Pair Vamp Assistant or Vamp Companion to stream apps from your Mac."
    static let pairAssistant = "Pair Assistant or Companion"
    static let pairAnotherAssistant = "Pair another Mac"
    static let pairAssistantHint = "Enter the private address and one-time code shown by Assistant or Companion"
    static let assistantMacsHeading = "ASSISTANT APP STREAMS"

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
