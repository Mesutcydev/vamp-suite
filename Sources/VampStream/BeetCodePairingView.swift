import SwiftUI
import SharedModels

struct BeetCodePairingView: View {
    private enum PairingField: Hashable {
        case address
        case code
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: BeetCodeRemoteSessionViewModel
    @State private var address: String
    @State private var code = ""
    @State private var showScanner = false
    @State private var showSecurityDetails = false
    @State private var scanError: String?
    @State private var pairingTask: Task<Void, Never>?
    @FocusState private var focusedField: PairingField?

    init(model: BeetCodeRemoteSessionViewModel, initialEndpoint: BeetCodeRemoteEndpoint? = nil) {
        self.model = model
        // Only a newly scanned QR can prefill this form; saved Macs reconnect
        // from their own cards and must not leak their address into new pairing.
        _address = State(initialValue: initialEndpoint?.url.absoluteString ?? "")
        _code = State(initialValue: initialEndpoint?.pairingCode ?? "")
    }

    private var canPair: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && code.count == 6
            && !model.isPairing
    }

    var body: some View {
        ZStack {
            VampStreamPairingGridBackdrop()

            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        headerBlock
                        scanBlock.disabled(model.isPairing)
                        manualDivider
                        addressBlock.disabled(model.isPairing)
                        codeBlock.disabled(model.isPairing)

                        if let scanError {
                            errorBlock(scanError)
                            Button("Scan again") { showScanner = true }
                                .frame(minHeight: 44)
                        }

                        if let error = model.lastError {
                            errorBlock(error)
                        }

                        pairButton
                        securityBlock
                    }
                    .padding(.horizontal, AppSpacing.xl)
                    .padding(.top, AppSpacing.xl)
                    .padding(.bottom, AppSpacing.xxl)
                }
                .scrollDismissesKeyboard(.interactively)
                .background { VampStreamEnvironmentBackdrop() }
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text("Assistant / Companion")
                            .font(.headline)
                            .foregroundStyle(PR.fg)
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            pairingTask?.cancel()
                            model.cancelConnectionAttempt()
                            dismiss()
                        }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(PR.fg.opacity(0.72))
                            .accessibilityHint("Close Vamp Assistant pairing")
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { focusedField = nil }
                            .font(.subheadline.weight(.semibold))
                            .accessibilityHint("Hide the keyboard and continue pairing")
                    }
                }
            }
        }
        .background { VampStreamEnvironmentBackdrop() }
        .onDisappear {
            pairingTask?.cancel()
        }
        .onChangeCompat(of: model.session?.address) { newAddress in
            if newAddress != nil { dismiss() }
        }
        .fullScreenCover(isPresented: $showScanner) {
            NavigationStack {
                BeetCodeQRScannerView { payload in
                    applyScannedPayload(payload)
                }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Scan QR code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showScanner = false }
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var headerBlock: some View {
        StreamAssistantPairingHeader()
            .padding(.bottom, 26)
    }

    private var scanBlock: some View {
        StreamPrimaryButton(title: "Scan pairing code", symbol: "qrcode.viewfinder") {
            scanError = nil
            showScanner = true
        }
    }

    private var manualDivider: some View {
        HStack(spacing: AppSpacing.sm) {
            line.opacity(0.08)
            Text("or enter manually")
                .font(.footnote.weight(.medium))
                .layoutPriority(1)
                .tracking(0.6)
                .foregroundStyle(StreamReading.secondary)
            line.opacity(0.08)
        }
        .padding(.top, AppSpacing.xl)
        .padding(.bottom, AppSpacing.xl)
    }

    private var line: some View {
        Rectangle()
            .fill(StreamDesign.text)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private var addressBlock: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Private address")
                .font(.footnote.weight(.medium))
                .tracking(0.6)
                .foregroundStyle(StreamReading.secondary)

            TextField("192.168.1.20:9575", text: $address)
                .focused($focusedField, equals: .address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                .submitLabel(.next)
                .onSubmit { focusedField = .code }
                .font(.body.weight(.medium))
                .padding(.horizontal, AppSpacing.md)
                .frame(minHeight: 54)
                .streamGlass(radius: 20)
                .accessibilityLabel("Assistant or Companion private address")
                .accessibilityHint("Enter the local or Tailscale address of Assistant or Companion on your own Mac")

            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text("Assistant uses port 9575; Companion uses port 9675.")
                Button("Local/private network connections only.") {
                    showSecurityDetails = true
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(PR.fg.opacity(0.72))
                .buttonStyle(.plain)
            }
            .font(.footnote)
            .foregroundStyle(StreamReading.secondary)
        }
        .padding(.bottom, AppSpacing.xl)
    }

    private var codeBlock: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("One-time pairing code")
                .font(.footnote.weight(.medium))
                .tracking(0.6)
                .foregroundStyle(StreamReading.secondary)

            TextField("000000", text: $code)
                .focused($focusedField, equals: .code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .onChangeCompat(of: code) { newValue in
                    let digits = String(newValue.filter(\.isNumber).prefix(6))
                    if digits != newValue { code = digits }
                }
                .font(.title2.weight(.semibold).monospacedDigit())
                .tracking(8)
                .multilineTextAlignment(.center)
                .frame(minHeight: 58)
                .streamGlass(radius: 20)
                .accessibilityLabel("Six-digit pairing code")
                .accessibilityHint("Enter the one-time code shown by Assistant or Companion")
        }
        .padding(.bottom, AppSpacing.md)
    }

    private func errorBlock(_ message: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .medium))
            Text(message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(PR.fg.opacity(0.78))
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: AppHostMetrics.controlRadius, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .padding(.bottom, AppSpacing.md)
    }

    private var pairButton: some View {
        VStack(spacing: 12) {
            if model.isPairing { ProgressView("Pairing with your Mac…").font(.footnote).tint(StreamDesign.accent) }
            StreamPrimaryButton(title: "Pair Mac", symbol: "link", isDisabled: !canPair) {
                focusedField = nil
                pairingTask?.cancel()
                pairingTask = Task { await model.pair(address: address, code: code) }
            }
            .accessibilityHint("Connect using the private address and one-time code")
        }
        .padding(.bottom, AppSpacing.md)
    }

    @ViewBuilder
    private var securityBlock: some View {
        HStack(spacing: AppSpacing.xs) {
            Image(systemName: "lock.shield")
                .font(.system(size: 13, weight: .medium))
            Text("Only pair with a Mac you recognize.")
                .font(.footnote)
        }
        .foregroundStyle(StreamReading.secondary)
        .accessibilityElement(children: .combine)

        if showSecurityDetails {
            Text("Connect to Assistant or Companion on your own Mac over trusted Wi-Fi or your private Tailscale network. Never expose a host port to the public internet.")
                .font(.footnote)
                .foregroundStyle(StreamReading.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, AppSpacing.xxs)
                .transition(.opacity)
        }
    }

    private func applyScannedPayload(_ payload: String) {
        do {
            let endpoint = try BeetCodeRemoteEndpoint.parsePairingLink(payload)

            address = endpoint.url.absoluteString
            if let pairingCode = endpoint.pairingCode {
                code = pairingCode
            }
            scanError = nil
            showScanner = false
        } catch {
            showScanner = false
            scanError = "That QR code is not an Assistant or Companion pairing link. Scan the code shown by Assistant or Companion on your Mac."
        }
    }
}

private struct StreamAssistantPairingHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StreamEyebrow(title: "ASSISTANT / COMPANION")
            Text("Pair your Mac.")
                .font(.largeTitle.weight(.medium)).tracking(-1.5)
                .foregroundStyle(StreamDesign.text)
            Text("Use the private address and one-time code shown on your Mac.")
                .font(.subheadline).foregroundStyle(StreamDesign.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
