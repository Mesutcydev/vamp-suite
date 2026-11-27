import SwiftUI
import SharedModels
import SharedUtilities
import AVFoundation
import VisionKit

enum ControlMacSource: String, CaseIterable, Identifiable {
    case sync, companion
    var id: String { rawValue }
    var title: LocalizedStringKey { self == .sync ? "Vamp Sync" : "Vamp Companion" }
}

/// QR contents populate a reviewable form. Scanning never connects or approves a device.
enum ControlPairingRoute: Equatable {
    /// Address plus the host fingerprint the code carried, when it has one.
    case sync(String, fingerprint: String?)
    case companion(BeetCodeRemoteEndpoint)

    static func parse(_ payload: String) -> Self? {
        if let endpoint = try? BeetCodeRemoteEndpoint.parsePairingLink(payload) {
            return .companion(endpoint)
        }
        if let link = VampHostPairingLink.parse(payload) { return .sync(link.address, fingerprint: link.fingerprint) }
        return nil
    }
}

struct ControlAddMacView: View {
    @ObservedObject var hosts: HostsListViewModel
    @ObservedObject var companion: BeetCodeRemoteSessionViewModel
    let onConnectSync: (DiscoveredHostRow) -> Void
    /// Set when the view is a page of an open Duo rather than a sheet: Cancel calls it.
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var source = ControlMacSource.sync
    /// Vamp Companion pairing is an experimental option for a future app, off by default.
    @AppStorage(ControlExperiments.companionKey) private var companionEnabled = false
    @State private var syncAddress = ""
    /// The scanned code's address and host fingerprint. The fingerprint is used only while the
    /// address field still holds exactly what was scanned.
    @State private var scannedSync: (address: String, fingerprint: String)?
    @State private var companionAddress = ""
    @State private var code = ""
    @State private var error: String?
    @State private var showsScanner = false
    @State private var pairingTask: Task<Void, Never>?
    @FocusState private var field: Field?
    private enum Field { case address, code }

    private var nearby: [DiscoveredHostRow] {
        hosts.displayHosts.filter { $0.isAvailable && !$0.isTerminalOnlyHost }
    }
    private var canConnect: Bool {
        if companion.isPairing { return false }
        return source == .sync
            ? !syncAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : !companionAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && code.count == 6
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ControlDesign.section) {
                    header
                    if companionEnabled { sourcePicker }
                    scanTile
                    if source == .sync && !nearby.isEmpty { nearbyList }
                    addressCard
                    if let message = error ?? companion.lastError {
                        ControlNotice(message: ControlDesign.companionMessage(message))
                            .accessibilityIdentifier("control.pairingError")
                    }
                    editionsCard
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, ControlDesign.gutter).padding(.top, ControlDesign.gap).padding(.bottom, ControlDesign.section)
                .frame(maxWidth: .infinity)
                .animation(.smooth, value: source)
                .animation(.smooth, value: canConnect)
            }
            .scrollDismissesKeyboard(.interactively)
            .background { ControlBackground() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if canConnect && field == nil { connectBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        pairingTask?.cancel()
                        companion.cancelConnectionAttempt()
                        if let onClose { onClose() } else { dismiss() }
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    if canConnect {
                        Button(source == .sync ? "Connect" : "Pair", action: connect).fontWeight(.semibold)
                    } else {
                        Button("Done") { field = nil }
                    }
                }
            }
            .disabled(companion.isPairing)
            .overlay(alignment: .bottom) {
                if companion.isPairing {
                    HStack(spacing: ControlDesign.stack) {
                        ProgressView().tint(ControlDesign.accent)
                        Text("Pairing with your Mac…").font(.subheadline.weight(.medium))
                        Spacer(minLength: 0)
                        Button("Cancel") { pairingTask?.cancel(); companion.cancelConnectionAttempt() }
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(ControlDesign.ink)
                    .padding(ControlDesign.inset).controlGlass(emphasis: .control).padding(ControlDesign.inset)
                }
            }
        }
        .tint(ControlDesign.accent)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(companion.isPairing)
        .onDisappear { pairingTask?.cancel() }
        .onChange(of: source) { _, _ in error = nil; companion.cancelConnectionAttempt() }
        .onAppear { if !companionEnabled { source = .sync } }
        .sheet(isPresented: $showsScanner) {
            ControlScannerView { payload in
                showsScanner = false
                switch ControlPairingRoute.parse(payload) {
                case .sync(let address, let fingerprint):
                    source = .sync; syncAddress = address; error = nil
                    scannedSync = fingerprint.map { (address, $0) }
                case .companion where !companionEnabled:
                    error = String(localized: "That’s a Vamp Companion code. Turn on Vamp Companion pairing in Settings > Experimental to use it.")
                case .companion(let endpoint):
                    source = .companion
                    companionAddress = endpoint.url.absoluteString
                    code = endpoint.pairingCode ?? ""
                    error = nil
                case nil:
                    error = String(localized: "That isn’t a Sync or Companion pairing code. Scan the code shown on your Mac, or enter its address below.")
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: ControlDesign.stack) {
            ControlGlassLogo()
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a Mac").font(.title2.weight(.bold))
                    .foregroundStyle(ControlDesign.ink)
                    .accessibilityAddTraits(.isHeader)
                ControlMono(text: companionEnabled ? "Choose what runs on your Mac" : "Pair with Vamp Sync", size: 9)
            }
        }
    }

    private var sourcePicker: some View {
        HStack(spacing: ControlDesign.gap) {
            ForEach(ControlMacSource.allCases) { option in
                ControlSourceTile(source: option, isSelected: source == option) { source = option }
            }
        }
        .accessibilityIdentifier("control.source")
    }

    private var scanTile: some View {
        Button {
            field = nil
            showsScanner = true
        } label: {
            HStack(spacing: ControlDesign.stack) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 20, weight: .light)).foregroundStyle(ControlDesign.ink)
                    .frame(width: ControlDesign.tile, height: ControlDesign.tile)
                    .controlGlass(radius: ControlDesign.innerRadius, emphasis: .control)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scan your Mac’s code").font(.headline).foregroundStyle(ControlDesign.ink)
                    Text(source == .sync ? "Vamp Sync shows it in its menu bar panel."
                                         : "Vamp Companion shows it with the pairing code.")
                        .font(.footnote).foregroundStyle(ControlDesign.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: ControlDesign.gap)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(ControlDesign.secondary)
            }
            .padding(ControlDesign.inset)
            .contentShape(RoundedRectangle(cornerRadius: ControlDesign.radius, style: .continuous))
            .controlGlass(interactive: true)
        }
        .buttonStyle(ControlPressStyle())
        .accessibilityIdentifier("control.scan")
    }

    private var nearbyList: some View {
        VStack(alignment: .leading, spacing: ControlDesign.gap) {
            HStack(spacing: ControlDesign.gap) {
                ControlPulseDot(color: ControlDesign.available, size: 6)
                ControlMono(text: "Nearby on your network")
            }
            .padding(.leading, ControlDesign.inset)
            ForEach(nearby) { host in
                Button {
                    field = nil
                    onConnectSync(host)
                } label: {
                    HStack(spacing: ControlDesign.stack) {
                        ControlSymbol().fill(ControlDesign.ink).frame(width: 18, height: 18)
                            .frame(width: ControlDesign.tile, height: ControlDesign.tile)
                            .controlGlass(radius: ControlDesign.innerRadius, emphasis: .control)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(host.title).font(.headline).foregroundStyle(ControlDesign.ink).lineLimit(1)
                            ControlMono(text: "Vamp Sync · Local network", size: 9)
                        }
                        Spacer(minLength: ControlDesign.gap)
                        Image(systemName: "arrow.right").font(.footnote.weight(.bold))
                            .foregroundStyle(ControlDesign.buttonInk)
                            .frame(width: ControlDesign.smallButtonHeight, height: ControlDesign.smallButtonHeight)
                            .background(ControlDesign.accent, in: Circle())
                    }
                    .padding(ControlDesign.inset)
                    .contentShape(RoundedRectangle(cornerRadius: ControlDesign.radius, style: .continuous))
                    .controlGlass(interactive: true)
                }
                .buttonStyle(ControlPressStyle())
                .accessibilityLabel(Text("\(host.title), Vamp Sync, local network"))
            }
        }
    }

    private var addressCard: some View {
        VStack(alignment: .leading, spacing: ControlDesign.stack) {
            ControlMono(text: source == .sync ? "Or enter its address" : "Address and pairing code")
            Group {
                if source == .sync {
                    TextField("Mac’s private address", text: $syncAddress, prompt: Text(verbatim: "192.168.1.20:9471"))
                        .focused($field, equals: .address)
                        .accessibilityIdentifier("control.syncAddress")
                        .onSubmit(connect)
                } else {
                    TextField("Mac’s private address", text: $companionAddress, prompt: Text(verbatim: "192.168.1.20:9675"))
                        .focused($field, equals: .address)
                        .accessibilityIdentifier("control.companionAddress")
                        .onSubmit { field = .code }
                }
            }
            .font(.system(.body, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .textContentType(.URL)
            .submitLabel(source == .sync ? .go : .next)
            .padding(.horizontal, ControlDesign.inset).frame(minHeight: ControlDesign.lineHeight)
            .controlGlass(radius: ControlDesign.innerRadius, emphasis: .control)
            .overlay {
                RoundedRectangle(cornerRadius: ControlDesign.innerRadius, style: .continuous)
                    .strokeBorder(ControlDesign.ink.opacity(field == .address ? 0.45 : 0), lineWidth: 1)
            }

            if source == .companion {
                TextField("Six-digit pairing code", text: $code, prompt: Text(verbatim: "000000"))
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .font(.system(size: 22, weight: .medium, design: .monospaced)).tracking(8)
                    .multilineTextAlignment(.center)
                    .focused($field, equals: .code)
                    .accessibilityIdentifier("control.pairingCode")
                    .onChange(of: code) { _, value in
                        code = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
                    }
                    .frame(minHeight: ControlDesign.rowHeight)
                    .controlGlass(radius: ControlDesign.innerRadius, emphasis: .control)
                    .overlay {
                        RoundedRectangle(cornerRadius: ControlDesign.innerRadius, style: .continuous)
                            .strokeBorder(ControlDesign.ink.opacity(field == .code ? 0.45 : 0), lineWidth: 1)
                    }
            }

            Text(source == .sync
                 ? "Use the address in Vamp Sync’s menu bar panel. A local IP or Tailscale address works."
                 : "Use the address and code shown in Vamp Companion. Its usual port is 9675.")
                .font(.footnote).foregroundStyle(ControlDesign.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(ControlDesign.inset)
        .controlGlass()
    }

    private var editionsCard: some View {
        ControlPromoCard(title: "Need Vamp Sync?",
                         detail: "The free website edition adds keyboard and pointer control. The Mac App Store edition is View Only.")
    }

    /// Appears only once there is something to connect to; never a disabled slab.
    private var connectBar: some View {
        VStack(spacing: ControlDesign.gap) {
            ControlPrimaryButton(title: companion.isPairing ? "Pairing…" : (source == .sync ? "Connect" : "Pair Mac"),
                                 symbol: source == .sync ? "arrow.right" : "link",
                                 fillsWidth: false, action: connect)
                .accessibilityIdentifier("control.connect")
            ControlMono(text: source == .sync ? "Approve this device in Vamp Sync" : "Only pair with a Mac you recognize", size: 8.5)
        }
        .padding(.vertical, ControlDesign.stack)
        .frame(maxWidth: .infinity)
    }

    private func connect() {
        guard canConnect else { return }
        field = nil
        error = nil
        if source == .sync {
            let scannedFingerprint = scannedSync?.address == syncAddress ? scannedSync?.fingerprint : nil
            guard let host = hosts.addManualHost(address: syncAddress, scannedFingerprint: scannedFingerprint),
                  !host.isTerminalOnlyHost else {
                error = String(localized: "Enter your Mac’s IP address or hostname, with a valid port if needed.")
                return
            }
            onConnectSync(host)
        } else {
            do {
                let address = companionAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                let candidate = address.contains("://") ? address : "http://\(address)"
                guard var components = URLComponents(string: candidate) else { throw BeetCodeRemoteError.invalidAddress }
                if components.port == nil { components.port = 9675 }
                let endpoint = try BeetCodeRemoteEndpoint.parse(address: components.string ?? candidate, pairingCode: code)
                pairingTask = Task { await companion.pair(address: endpoint.url.absoluteString, code: code) }
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct ControlSourceTile: View {
    let source: ControlMacSource
    let isSelected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: ControlDesign.stack) {
                HStack {
                    Image(systemName: source == .sync ? "macwindow.on.rectangle" : "sparkles.rectangle.stack")
                        .font(.system(size: 18, weight: .medium))
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17))
                        .foregroundStyle(isSelected ? ControlDesign.ink : ControlDesign.secondary.opacity(0.6))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.title).font(.subheadline.weight(.semibold))
                    ControlMono(text: source == .sync ? "Desktop · Apps" : "Code pairing", size: 8.5)
                }
            }
            .foregroundStyle(ControlDesign.ink)
            .padding(ControlDesign.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: ControlDesign.radius, style: .continuous))
            .controlGlass(interactive: true, emphasis: isSelected ? .control : .surface)
            .overlay {
                RoundedRectangle(cornerRadius: ControlDesign.radius, style: .continuous)
                    .strokeBorder(ControlDesign.ink.opacity(isSelected ? 0.55 : 0), lineWidth: 1.2)
            }
        }
        .buttonStyle(ControlPressStyle())
        .accessibilityLabel(Text(source.title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct ControlScannerView: View {
    let onPayload: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var authorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    @State private var checkedAccess = false
    @State private var scanningError: String?

    var body: some View {
        NavigationStack {
            Group {
                if authorized && DataScannerViewController.isSupported && DataScannerViewController.isAvailable && scanningError == nil {
                    ControlNativeScanner(onPayload: onPayload, onError: { scanningError = $0 })
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView {
                        Label("Use your Mac’s address", systemImage: "qrcode.viewfinder")
                    } description: {
                        Text(scanningError ?? (checkedAccess && !authorized
                             ? "Allow camera access in Settings to scan, or enter the address and code manually."
                             : "Camera scanning isn’t available here. You can still enter your Mac’s address and pairing code."))
                    } actions: {
                        if checkedAccess && !authorized {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }.buttonStyle(.bordered)
                        }
                        if authorized && scanningError != nil {
                            Button("Try again") { scanningError = nil }.buttonStyle(.bordered)
                        }
                        Button("Enter manually") { dismiss() }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .background { ControlBackground() }
            .navigationTitle("Scan Mac’s code").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task {
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                authorized = await AVCaptureDevice.requestAccess(for: .video)
            }
            checkedAccess = true
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                authorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            }
        }
    }
}

private struct ControlNativeScanner: UIViewControllerRepresentable {
    let onPayload: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPayload: onPayload, onError: onError) }
    func makeUIViewController(context: Context) -> Container {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return Container(scanner: scanner, coordinator: context.coordinator)
    }
    func updateUIViewController(_ controller: Container, context: Context) {}
    static func dismantleUIViewController(_ controller: Container, coordinator: Coordinator) { controller.scanner.stopScanning() }

    final class Container: UIViewController {
        let scanner: DataScannerViewController
        let coordinator: Coordinator
        init(scanner: DataScannerViewController, coordinator: Coordinator) {
            self.scanner = scanner
            self.coordinator = coordinator
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func viewDidLoad() {
            super.viewDidLoad()
            addChild(scanner)
            scanner.view.frame = view.bounds
            scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(scanner.view)
            scanner.didMove(toParent: self)
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !coordinator.didRead else { return }
            do { try scanner.startScanning() }
            catch { coordinator.onError(error.localizedDescription) }
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            scanner.stopScanning()
        }
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onPayload: (String) -> Void
        let onError: (String) -> Void
        var didRead = false
        init(onPayload: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onPayload = onPayload
            self.onError = onError
        }
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !didRead else { return }
            for case .barcode(let barcode) in addedItems {
                guard let value = barcode.payloadStringValue else { continue }
                didRead = true
                scanner.stopScanning()
                onPayload(value)
                break
            }
        }
        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            onError(error.localizedDescription)
        }
    }
}
