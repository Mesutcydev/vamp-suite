#if canImport(FoundationModels)
import FoundationModels
#endif
import Foundation
import SharedModels

/// Turns a Vamp connection/event log into a plain-language "what happened + what to try"
/// using Apple's Foundation Models.
///
/// Engine selection (best first):
/// - **Private Cloud Compute** (iOS/macOS 26+ *with the iOS 27 SDK*): a far larger model with a
///   32K context, so it reasons over the whole log and is much less prone to the small on-device
///   model's hallucinations. The log is processed on Apple's Private Cloud Compute — privacy-
///   preserving (not stored, not readable by Apple), but it does leave the device, so the UI copy
///   must say so. Free for App Store Small Business Program apps under 2M downloads (requires the
///   PCC entitlement; until granted, `isAvailable` is false and we fall back).
/// - **On-device** (iOS/macOS 26): the small ~3B model. Works offline, no quota, but weaker.
///
/// Additive + availability-gated + weak-linked (`canImport` + `#available`), so this still
/// compiles/runs on the app's iOS 16 / macOS 13 deployment targets and only touches a model on 26+.
public enum LogExplainer {
    public enum Availability: Sendable, Equatable {
        case available
        case unavailable(String)   // human-readable reason for the UI

        public var isAvailable: Bool { if case .available = self { return true }; return false }
    }

    /// Which model actually produced the answer — surfaced in the UI footnote.
    public enum Engine: Sendable, Equatable {
        case privateCloudCompute
        case onDevice
        /// Short label for the privacy/credit footnote.
        public var label: String {
            switch self {
            case .privateCloudCompute: return "Apple Private Cloud Compute"
            case .onDevice: return "the on-device model"
            }
        }
    }

    public struct Explanation: Sendable, Equatable {
        public let text: String
        public let engine: Engine
    }

    public static var availability: Availability {
        #if canImport(FoundationModels)
        // Prefer Private Cloud Compute when the device + entitlement allow it (iOS/macOS 27+).
        // Gated behind ENABLE_PCC: PrivateCloudComputeLanguageModel is a 27-SDK-only symbol, so
        // without the flag this compiles on the GM Xcode (26.x) the App Store requires. Build the
        // PCC variant with ENABLE_PCC + Xcode 27; the default falls back to the on-device model.
        #if ENABLE_PCC
        if #available(iOS 27.0, macOS 27.0, *), pccIsAvailable() {
            return .available
        }
        #endif
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.deviceNotEligible):
                return .unavailable("This device doesn’t support Apple Intelligence.")
            case .unavailable(.appleIntelligenceNotEnabled):
                return .unavailable("Turn on Apple Intelligence in Settings to use this.")
            case .unavailable(.modelNotReady):
                return .unavailable("The on-device model is still downloading — try again soon.")
            case .unavailable:
                return .unavailable("On-device model unavailable.")
            }
        }
        #endif
        return .unavailable("Requires iOS 26 / macOS 26 with Apple Intelligence.")
    }

    /// Explain the given log items. Tries Private Cloud Compute first (bigger model, fewer
    /// hallucinations), then falls back to the on-device model. Returns nil if neither is usable.
    public static func explain(_ items: [EventLogItem]) async -> Explanation? {
        guard !items.isEmpty else { return nil }
        #if canImport(FoundationModels)
        let prompt = Self.prompt(for: items)

        // 1. Private Cloud Compute (iOS/macOS 27+) — only when built with ENABLE_PCC (see availability).
        #if ENABLE_PCC
        if #available(iOS 27.0, macOS 27.0, *), let pcc = Self.pccModel(), pcc.isAvailable {
            do {
                let session = LanguageModelSession(model: pcc, instructions: Self.instructions)
                let text = try await session.respond(to: prompt).content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return Explanation(text: text, engine: .privateCloudCompute) }
            } catch {
                // Quota reached / network / service error → fall through to on-device.
            }
        }
        #endif

        // 2. On-device fallback.
        if #available(iOS 26.0, macOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let text = try await session.respond(to: prompt).content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : Explanation(text: text, engine: .onDevice)
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    #if canImport(FoundationModels) && ENABLE_PCC
    // PrivateCloudComputeLanguageModel ships only in the iOS/macOS 27 SDK, so every reference to it
    // lives behind ENABLE_PCC — the default (and the App Store GM build) compiles without it.
    @available(iOS 27.0, macOS 27.0, *)
    private static func pccModel() -> PrivateCloudComputeLanguageModel? {
        PrivateCloudComputeLanguageModel()
    }

    @available(iOS 27.0, macOS 27.0, *)
    private static func pccIsAvailable() -> Bool {
        PrivateCloudComputeLanguageModel().isAvailable
    }
    #endif

    private static let instructions = """
    You are a support assistant inside "Vamp Host", a Mac remote-control app: a Mac "host" is \
    screen-shared and controlled by an iPhone or Mac "client", usually over Tailscale. You are \
    given the client's recent connection log — a tally of repeated errors followed by recent lines.

    Answer in 2 to 4 short, calm, plain-language sentences: what most likely happened, and the \
    single most useful thing to try. Base your answer ONLY on evidence in the log. Do NOT invent a \
    cause the log doesn't support — if no clear cause is present, say the cause isn't clear from the \
    log and suggest simply reconnecting. Never blame permissions or a macOS update unless a \
    permission/capture line actually appears.

    Decide using these signatures, only when they appear in the log:
    - Repeated "Peer connection failed — transport-level error" / "connection lost" / "reconnecting": \
    the network link dropped, usually a Wi-Fi or Tailscale-relay hiccup. It typically recovers on its \
    own; suggest a more stable network or moving closer to Wi-Fi.
    - "Liveness timeout — no pong for <N>s" where N is tens of seconds or more: the phone app was \
    most likely backgrounded; it reconnects when reopened. This is normal, not a fault.
    - "Screen Recording" / "capture failed" / "permission": the host Mac's Screen Recording \
    permission needs to be re-granted in System Settings.
    - Signaling never connects, or "host asleep" / "unreachable": the host Mac is asleep or off the \
    network — wake it or check it's online.
    - "trust" / "pairing" rejected: approve this device on the host Mac.
    - Connects, video starts, and there are no repeated errors: say the connection looks healthy.
    """

    private static func prompt(for items: [EventLogItem]) -> String {
        let sorted = items.sorted { $0.timestamp < $1.timestamp }
        // Tally repeated error/warning signatures so the model reasons over structure, not raw spam.
        // This is what turns it from a free-associating generator into a classifier.
        var tally: [String: Int] = [:]
        for it in sorted where it.severity == .error || it.severity == .warning {
            tally[it.message, default: 0] += 1
        }
        let summary = tally.sorted { $0.value > $1.value }
            .prefix(12)
            .map { "\($0.value)× \($0.key)" }
            .joined(separator: "\n")
        // Keep a generous tail (PCC has a 32K context; on-device truncates harmlessly).
        let recent = sorted.suffix(80)
        let lines = recent.map { "[\($0.severity.rawValue)] \($0.category): \($0.message)" }
        return """
        Repeated errors/warnings in this log (count × message):
        \(summary.isEmpty ? "(none)" : summary)

        Recent log lines (oldest to newest):
        \(lines.joined(separator: "\n"))
        """
    }
}
