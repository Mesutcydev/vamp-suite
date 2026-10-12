import SwiftUI

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

    init(model: BeetCodeRemoteSessionViewModel) {
        self.model = model
        // Pairing adds a Mac. Existing Assistants reconnect from their own cards,
        // so never prefill this form with another saved Mac's address.
        _address = State(initialValue: "")
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
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text("Vamp Assistant")
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
                            .padding(.horizontal, AppSpacing.md)
                            .frame(minHeight: 44)
                            .background {
                                Capsule()
                                    .fill(Color.white.opacity(0.07))
                                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                            }
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
            .preferredColorScheme(.dark)
        }
        .background(Color.black.ignoresSafeArea())
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

    @ViewBuilder
    private var headerBlock: some View {
        HStack(spacing: AppSpacing.sm) {
            LinkBadge()

            Text("Pair Vamp Assistant")
                .font(.title2.weight(.semibold))
                .tracking(-0.4)
                .foregroundStyle(PR.fg)
                .lineLimit(2)
                .minimumScaleFactor(0.9)
        }
        .padding(.bottom, AppSpacing.sm)

        Text("Connect to your Mac securely.")
            .font(.subheadline)
            .foregroundStyle(StreamReading.secondary)
            .padding(.bottom, AppSpacing.xl)
    }

    private var scanBlock: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Button {
                scanError = nil
                showScanner = true
            } label: {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 18, weight: .medium))
                    Text("Scan QR Code")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(Color.black.opacity(0.92))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 54)
                .background {
                    let shape = RoundedRectangle(cornerRadius: PR.rCard, style: .continuous)

                    ZStack {
                        shape.fill(Color.white.opacity(0.90))
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.34),
                                Color.white.opacity(0),
                                Color.black.opacity(0.05)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .mask { shape }
                        shape.strokeBorder(Color.white.opacity(0.32), lineWidth: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: PR.rCard, style: .continuous))
            }
            .buttonStyle(PRGlassPressButtonStyle())
            .accessibilityLabel("Scan pairing QR code")
            .accessibilityHint("Scan the private Vamp Assistant QR code to fill the address and pairing code")
        }
    }

    private var manualDivider: some View {
        HStack(spacing: AppSpacing.sm) {
            line.opacity(0.08)
            Text("or enter manually")
                .font(.footnote.weight(.medium))
                .tracking(0.6)
                .foregroundStyle(StreamReading.secondary)
            line.opacity(0.08)
        }
        .padding(.top, AppSpacing.xl)
        .padding(.bottom, AppSpacing.xl)
    }

    private var line: some View {
        Rectangle()
            .fill(Color.white)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private var addressBlock: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("PRIVATE ADDRESS")
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
                .background {
                    let shape = RoundedRectangle(cornerRadius: PR.rCard, style: .continuous)

                    ZStack {
                        shape.fill(Color.white.opacity(0.055))
                        shape.strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                    }
                }
                .accessibilityLabel("Vamp Assistant private address")
                .accessibilityHint("Enter the local or Tailscale address of Vamp Assistant")

            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text("Vamp Assistant uses port 9575.")
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
            Text("PAIRING CODE")
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
                .background {
                    let shape = RoundedRectangle(cornerRadius: PR.rCard, style: .continuous)

                    ZStack {
                        shape.fill(Color.white.opacity(0.055))
                        shape.strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                        shape.strokeBorder(
                            Color.white.opacity(0.12),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                        )
                    }
                }
                .accessibilityLabel("Six-digit pairing code")
                .accessibilityHint("Enter the one-time code shown by Vamp Assistant")
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
        Button {
            focusedField = nil
            pairingTask?.cancel()
            pairingTask = Task { await model.pair(address: address, code: code) }
        } label: {
            HStack(spacing: AppSpacing.xs) {
                if model.isPairing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.black.opacity(0.92))
                }
                Text(model.isPairing ? "Pairing…" : "Pair Mac")
                    .font(.headline)
            }
            .foregroundStyle((canPair || model.isPairing) ? Color.black.opacity(0.92) : Color.white.opacity(0.60))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
            .background {
                let shape = RoundedRectangle(cornerRadius: PR.rCard, style: .continuous)

                ZStack {
                    shape.fill((canPair || model.isPairing) ? Color.white.opacity(0.90) : Color.white.opacity(0.070))
                    if canPair {
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.30),
                                Color.white.opacity(0),
                                Color.black.opacity(0.06)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .mask { shape }
                    }
                    shape.strokeBorder(Color.white.opacity(canPair ? 0.30 : 0.10), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: PR.rCard, style: .continuous))
        }
        .buttonStyle(PRGlassPressButtonStyle())
        .disabled(!canPair)
        .animation(.easeOut(duration: 0.18), value: canPair)
        .accessibilityLabel(model.isPairing ? "Pairing with Vamp Assistant" : "Pair with Vamp Assistant")
        .accessibilityHint("Connect using the private address and one-time code")
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
            Text("Keep Vamp Assistant on your LAN or private Tailscale network; never expose port 9575 to the public internet.")
                .font(.footnote)
                .foregroundStyle(StreamReading.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, AppSpacing.xxs)
                .transition(.opacity)
        }
    }

    private func applyScannedPayload(_ payload: String) {
        do {
            let endpoint = try BeetCodeRemoteEndpoint.parse(address: payload)
            guard endpoint.url.port == BeetCodeRemoteEndpoint.defaultPort else {
                throw BeetCodeRemoteError.invalidAddress
            }

            address = endpoint.url.absoluteString
            if let pairingCode = endpoint.pairingCode {
                code = pairingCode
            }
            scanError = nil
            showScanner = false
        } catch {
            showScanner = false
            scanError = "That QR code is not a Vamp Assistant pairing link. Scan the code shown by Vamp Assistant on your Mac."
        }
    }
}

private struct LinkBadge: View {
    var body: some View {
        Image(systemName: "link")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(PR.fg)
            .frame(width: 38, height: 38)
            .background {
                Circle()
                    .fill(Color.white.opacity(0.075))
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}
