#if os(macOS)
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Generates the one-time private browser pairing link shown by both host
/// products. The QR contains only the host URL. The operator types the
/// 12-digit code shown on the Mac; the browser exchanges it for a token.
struct HostBrowserPairingQRCode: View {
    let pairingURL: String
    let accessibilityLabelText: String
    let displaySize: CGFloat

    @State private var image: NSImage?

    init(
        pairingURL: String,
        accessibilityLabel: String = "QR code for Safari pairing",
        size: CGFloat = 156
    ) {
        self.pairingURL = pairingURL
        self.accessibilityLabelText = accessibilityLabel
        self.displaySize = size
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: displaySize, height: displaySize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
        .task(id: pairingURL) {
            image = Self.makeImage(from: pairingURL)
        }
    }

    private static let context = CIContext()

    private static func makeImage(from value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let extent = output.extent.integral
        let scale = 512 / max(extent.width, extent.height)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: scaled.extent.width, height: scaled.extent.height)
        )
    }
}

/// Shared host-side Tailscale status surface used by both Vamp Host products.
/// The activation action opens the official Tailscale app, then refreshes the
/// daemon state so the address list updates without requiring a host restart.
struct HostTailscaleStatusView: View {
    @Binding var info: TailscaleConnectionInfo?
    @Binding var installed: Bool
    let compact: Bool

    @State private var isActivating = false
    @State private var activationMessage: String?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.16))
                        .frame(width: 30, height: 30)
                    Circle()
                        .fill(statusColor)
                        .frame(width: 9, height: 9)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Tailscale")
                        .font(.headline)
                    Text(statusTitle)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                    if let info {
                        Text(info.dnsName ?? info.ipAddress)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if let activationMessage {
                        Text(activationMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text("Required for Safari access away from this Mac")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                activateTailscale()
            } label: {
                if isActivating {
                    ProgressView()
                        .controlSize(.small)
                        .frame(minWidth: compact ? 22 : 102)
                } else {
                    Label(buttonTitle, systemImage: info == nil ? "power" : "arrow.up.forward.app")
                        .lineLimit(1)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(compact ? .small : .regular)
            .disabled(isActivating)
            .help(info == nil ? "Open Tailscale and wait for a tailnet connection" : "Open Tailscale")
        }
        .padding(compact ? 11 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hostGlassSurface(
            in: RoundedRectangle(cornerRadius: compact ? AppRadius.medium : AppRadius.large, style: .continuous),
            tint: statusColor
        )
        .task {
            await refreshTailscale()
        }
        .accessibilityElement(children: .contain)
    }

    private var statusTitle: String {
        if info != nil { return "Connected to tailnet" }
        if installed { return "Not connected" }
        return "Not installed"
    }

    private var statusColor: Color {
        if info != nil { return .green }
        if installed { return .orange }
        return .secondary
    }

    private var buttonTitle: String {
        if info != nil { return "Open Tailscale" }
        if installed { return "Activate Tailscale" }
        return "Open Tailscale"
    }

    private func refreshTailscale() async {
        let snapshot = await Task.detached(priority: .utility) {
            getTailscaleDetectionSnapshot()
        }.value
        guard !Task.isCancelled else { return }
        info = snapshot.info
        installed = snapshot.installed
    }

    private func activateTailscale() {
        isActivating = true
        let didOpen = openTailscaleApplication()
        activationMessage = didOpen
            ? "Tailscale opened. Waiting for the VPN…"
            : "Tailscale could not be opened. Install it, then try again."

        Task {
            for _ in 0..<12 {
                await refreshTailscale()
                if info != nil { break }
                try? await Task.sleep(for: .seconds(1))
            }
            isActivating = false
        }
    }
}

/// Focused dashboard for the separate Vamp Terminal Host product.
///
/// This deliberately does not expose screen capture, remote input, file
/// transfer, widgets, or full-host settings. The underlying environment still
/// reuses the signed Vamp transport and pairing stack, while the product mode
/// rejects non-terminal clients and never starts a capture pipeline.
struct VampTerminalHostShellView: View {
    @ObservedObject var environment: HostAppEnvironment

    @State private var tailscaleInfo: TailscaleConnectionInfo?
    @State private var tailscaleInstalled = false
    @State private var copiedValue: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let prompt = environment.pendingTrustPrompt {
                    VampTerminalTrustApprovalCard(
                        prompt: prompt,
                        onReject: { environment.resolveTrustPrompt(approved: false) },
                        onApprove: { environment.resolveTrustPrompt(approved: true) }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                VampTerminalHostConnectionCard(
                    environment: environment,
                    tailscaleInfo: $tailscaleInfo,
                    tailscaleInstalled: $tailscaleInstalled,
                    copiedValue: copiedValue,
                    onCopy: copy
                )
                HostHomepagePairingCard(
                    environment: environment,
                    tailscaleInfo: tailscaleInfo,
                    copiedValue: copiedValue,
                    browserPairingURL: browserPairingURL,
                    onCopy: copy,
                    onRotate: { environment.rotateBrowserPairingCode() }
                )
                Text("Terminal-only host · up to 8 independent tabs · port 9475")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(minWidth: 500, idealWidth: 560, maxWidth: 680, alignment: .topLeading)
        }
        .frame(minWidth: 500, idealWidth: 560, minHeight: 480, idealHeight: 620, maxHeight: 760)
        .background(VampTerminalHostBackdrop())
        .task {
            await environment.startRuntimeIfNeeded()
            let snapshot = await Task.detached(priority: .utility) {
                getTailscaleDetectionSnapshot()
            }.value
            tailscaleInfo = snapshot.info
            tailscaleInstalled = snapshot.installed
            await environment.discoveryAdvertiserViewModel.updateTailscaleIdentity(
                hostname: snapshot.info?.dnsName,
                ip: snapshot.info?.ipAddress
            )
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Section("Host") {
                        Button {
                            environment.chooseAdditionalWorkspaceFolder()
                        } label: {
                            Label("Add workspace folder…", systemImage: "folder.badge.plus")
                        }
                        Button {
                            Task {
                                await environment.stopRuntime()
                                await environment.startRuntimeIfNeeded()
                            }
                        } label: {
                            Label("Restart host", systemImage: "arrow.clockwise")
                        }
                    }

                    Section("Startup") {
                        Toggle("Start at Login", isOn: Binding(
                            get: { environment.startAtLoginEnabled },
                            set: { environment.setStartAtLogin($0) }
                        ))

                        Button {
                            environment.openStartAtLoginSettings()
                        } label: {
                            Label("Open Login Items", systemImage: "gearshape")
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            NSApp.terminate(nil)
                        } label: {
                            Label("Quit Vamp Terminal Host", systemImage: "power")
                        }
                    }
                } label: {
                    Label("Host menu", systemImage: "ellipsis.circle")
                }
                .help("Host actions")
            }
        }
        .animation(.snappy(duration: 0.22), value: environment.pendingTrustPrompt?.id)
    }

    private var header: some View {
        VampTerminalHostHeader(
            statusTitle: statusTitle,
            statusColor: statusColor,
            statusIcon: statusIcon
        )
    }

    private var browserPairingURL: String? {
        guard environment.browserControlStatus.running,
              let port = environment.browserControlStatus.port,
              !environment.browserControlStatus.pairingCode.isEmpty else { return nil }

        let baseURL: String
        if let tailscaleInfo {
            baseURL = tailscaleInfo.browserControlURL(port: port)
        } else {
            baseURL = "http://127.0.0.1:\(port)"
        }
        return HostBrowserPairingLink.make(baseURL: baseURL)
    }

    private var statusTitle: String {
        switch environment.sessionCoordinator.phase {
        case .streaming: return "CONNECTED"
        case .advertising, .awaitingClient: return "READY"
        case .idle: return "STOPPED"
        case .error: return "ERROR"
        default: return "CONNECTING"
        }
    }

    private var statusIcon: String {
        switch statusTitle {
        case "CONNECTED", "READY": return "checkmark.circle.fill"
        case "ERROR": return "exclamationmark.triangle.fill"
        case "STOPPED": return "pause.circle.fill"
        default: return "circle.fill"
        }
    }

    private var statusColor: Color {
        switch statusTitle {
        case "CONNECTED", "READY": return .green
        case "ERROR": return .orange
        default: return .secondary
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedValue = value
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copiedValue == value { copiedValue = nil }
        }
    }

}

private struct VampTerminalTrustApprovalCard: View {
    let prompt: HostAppEnvironment.TrustPrompt
    let onReject: () -> Void
    let onApprove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "iphone.and.arrow.forward.inward")
                .font(.title2.weight(.medium))
                .foregroundStyle(.orange)
                .frame(width: 40, height: 40)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("Allow \(prompt.displayName)?")
                    .font(.headline)
                Text("A new signed device wants to use terminal sessions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(prompt.fingerprint)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            Button("Reject", role: .destructive, action: onReject)
                .buttonStyle(.bordered)
            Button("Allow", action: onApprove)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hostGlassSurface(
            in: RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous),
            tint: .orange
        )
        .accessibilityElement(children: .contain)
    }
}

private struct VampTerminalHostConnectionCard: View {
    @ObservedObject var environment: HostAppEnvironment
    @Binding var tailscaleInfo: TailscaleConnectionInfo?
    @Binding var tailscaleInstalled: Bool
    let copiedValue: String?
    let onCopy: (String) -> Void

    @State private var isActivatingTailscale = false
    @State private var tailscaleMessage: String?

    var body: some View {
        VampTerminalHostSection(title: "Connection") {
            HStack(spacing: 12) {
                VampTerminalHostMark(size: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(environment.hostIdentity.displayName)
                        .font(.headline)
                    Text("Ready for Vamp Terminal and Safari")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                VampTerminalHostStatusPill(
                    text: statusTitle,
                    color: statusColor,
                    systemImage: statusIcon
                )
            }

            if let error = environment.sessionCoordinator.errorMessage, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 10) {
                Circle()
                    .fill(tailscaleInfo == nil ? (tailscaleInstalled ? .orange : .secondary) : .green)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Tailscale")
                        .font(.subheadline.weight(.semibold))
                    if let tailscaleInfo {
                        Text(tailscaleInfo.connectAddress)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(tailscaleInstalled ? "Installed but offline" : "Install to connect remotely")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if let tailscaleInfo {
                    Button(copiedValue == tailscaleInfo.connectAddress ? "Copied" : "Copy") {
                        onCopy(tailscaleInfo.connectAddress)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button {
                    activateTailscale()
                } label: {
                    if isActivatingTailscale {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(tailscaleInfo == nil ? "Activate" : "Open")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isActivatingTailscale)
                .help(tailscaleInfo == nil ? "Open Tailscale and wait for a connection" : "Open Tailscale")
            }

            if let tailscaleMessage {
                Text(tailscaleMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Vamp Host is for remote screen control. This light host is terminal-only.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusTitle: String {
        switch environment.sessionCoordinator.phase {
        case .streaming: return "CONNECTED"
        case .advertising, .awaitingClient: return "READY"
        case .idle: return "STOPPED"
        case .error: return "ERROR"
        default: return "STARTING"
        }
    }

    private var statusIcon: String {
        switch statusTitle {
        case "CONNECTED", "READY": return "checkmark.circle.fill"
        case "ERROR": return "exclamationmark.triangle.fill"
        case "STOPPED": return "pause.circle.fill"
        default: return "circle.fill"
        }
    }

    private var statusColor: Color {
        switch statusTitle {
        case "CONNECTED", "READY": return .green
        case "ERROR": return .orange
        default: return .secondary
        }
    }

    private func activateTailscale() {
        isActivatingTailscale = true
        let didOpen = openTailscaleApplication()
        tailscaleMessage = didOpen
            ? "Waiting for the tailnet…"
            : "Install Tailscale, then try again."

        Task {
            for _ in 0..<12 {
                let snapshot = await Task.detached(priority: .utility) {
                    getTailscaleDetectionSnapshot()
                }.value
                tailscaleInfo = snapshot.info
                tailscaleInstalled = snapshot.installed
                if tailscaleInfo != nil { break }
                try? await Task.sleep(for: .seconds(1))
            }
            isActivatingTailscale = false
        }
    }
}

/// Shared homepage pairing card used by both Vamp Host products. Keeping this
/// in the common host source guarantees QR/code behavior and copy actions stay
/// identical while each product can use its own surrounding dashboard.
struct HostHomepagePairingCard: View {
    let sectionTitle: String
    let title: String
    let subtitle: String
    @ObservedObject var environment: HostAppEnvironment
    let tailscaleInfo: TailscaleConnectionInfo?
    let copiedValue: String?
    let browserPairingURL: String?
    let onCopy: (String) -> Void
    let onRotate: () -> Void

    init(
        sectionTitle: String = "Open Safari",
        title: String = "Scan to open Safari",
        subtitle: String = "Or enter this code in Safari. It expires after ten minutes.",
        environment: HostAppEnvironment,
        tailscaleInfo: TailscaleConnectionInfo?,
        copiedValue: String?,
        browserPairingURL: String?,
        onCopy: @escaping (String) -> Void,
        onRotate: @escaping () -> Void
    ) {
        self.sectionTitle = sectionTitle
        self.title = title
        self.subtitle = subtitle
        self.environment = environment
        self.tailscaleInfo = tailscaleInfo
        self.copiedValue = copiedValue
        self.browserPairingURL = browserPairingURL
        self.onCopy = onCopy
        self.onRotate = onRotate
    }

    var body: some View {
        VampTerminalHostSection(title: sectionTitle) {
            HStack(alignment: .top, spacing: 18) {
                if let browserPairingURL {
                    HostBrowserPairingQRCode(pairingURL: browserPairingURL)
                        .frame(width: 148, height: 148)
                        .accessibilityHint("Scan this code with the iPhone or iPad camera")
                } else if environment.browserControlStatus.lastError != nil {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.orange.opacity(0.12))
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)
                    }
                    .frame(width: 148, height: 148)
                    .accessibilityLabel("Safari control is unavailable")
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.quaternary.opacity(0.35))
                        ProgressView()
                            .controlSize(.small)
                    }
                    .frame(width: 148, height: 148)
                    .accessibilityLabel("Pairing QR code is starting")
                }

                pairingDetails
            }
        }
    }

    private var pairingDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "safari")
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Circle()
                    .fill(environment.browserControlStatus.running ? .green : .orange)
                    .frame(width: 7, height: 7)
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 9) {
                if environment.browserControlStatus.running {
                    Text(environment.browserControlStatus.pairingCode)
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)

                    Button(copiedValue == environment.browserControlStatus.pairingCode ? "Copied" : "Copy") {
                        onCopy(environment.browserControlStatus.pairingCode)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer(minLength: 0)

                    Button("New code") {
                        onRotate()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if environment.browserControlStatus.lastError != nil {
                    Text("Unavailable")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    Text("Starting…")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }

            if let directURL {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Safari address")
                            .font(.caption2.weight(.semibold))
                        Text(directURL)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Button(copiedValue == directURL ? "Copied" : "Copy") {
                        onCopy(directURL)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else if environment.browserControlStatus.lastError == nil, tailscaleInfo == nil {
                Label("Activate Tailscale above for a remote address.", systemImage: "network.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = environment.browserControlStatus.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") {
                    environment.retryBrowserControl()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var directURL: String? {
        guard let port = environment.browserControlStatus.port else { return nil }
        if let tailscaleInfo {
            return tailscaleInfo.browserControlURL(port: port)
        }
        return "http://127.0.0.1:\(port) · local Mac only"
    }
}

private struct VampTerminalHostHeader: View {
    let statusTitle: String
    let statusColor: Color
    let statusIcon: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            regularHeader
            compactHeader
        }
        .accessibilityElement(children: .combine)
    }

    private var regularHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VampTerminalHostMark(size: 46)

            VStack(alignment: .leading, spacing: 4) {
                Text("Vamp Terminal Host")
                    .font(.title2.weight(.semibold))
                Text("Terminal tabs · Safari control")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
            statusPill
        }
    }

    private var compactHeader: some View {
        HStack(spacing: 10) {
            VampTerminalHostMark(size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("Vamp Terminal Host")
                    .font(.headline)
                Text("Terminal tabs · Safari")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            statusPill
        }
    }

    private var statusPill: some View {
        VampTerminalHostStatusPill(
            text: statusTitle,
            color: statusColor,
            systemImage: statusIcon
        )
    }
}

private struct VampTerminalHostSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(16)
        .vampTerminalHostGlass(.card, cornerRadius: 18)
    }
}

private struct VampTerminalHostAddress: View {
    let title: String
    let value: String
    let systemImage: String
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help("Copy address")
        }
    }
}

private struct VampTerminalHostStatusPill: View {
    let text: String
    let color: Color
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(color.opacity(0.10), in: Capsule())
            .overlay { Capsule().stroke(color.opacity(0.26), lineWidth: 0.5) }
    }
}

private struct VampTerminalHostBackdrop: View {
    var body: some View {
        AppBackground()
    }
}

private enum VampTerminalHostGlassRole {
    case card
    case icon

    var radius: CGFloat {
        switch self {
        case .card: return 18
        case .icon: return 16
        }
    }
}

private struct VampTerminalHostGlassModifier: ViewModifier {
    let role: VampTerminalHostGlassRole
    let cornerRadius: CGFloat?

    func body(content: Content) -> some View {
        let radius = cornerRadius ?? role.radius
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.primary.opacity(0.16), lineWidth: 0.6)
            }
    }
}

private extension View {
    func vampTerminalHostGlass(
        _ role: VampTerminalHostGlassRole,
        cornerRadius: CGFloat? = nil
    ) -> some View {
        modifier(VampTerminalHostGlassModifier(role: role, cornerRadius: cornerRadius))
    }
}

#endif
