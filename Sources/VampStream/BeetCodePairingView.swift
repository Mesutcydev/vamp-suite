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
    @State private var scanError: String?
    @FocusState private var focusedField: PairingField?

    init(model: BeetCodeRemoteSessionViewModel) {
        self.model = model
        // Pairing adds a Mac. Existing Assistants reconnect from their own cards,
        // so never prefill this form with another saved Mac's address.
        _address = State(initialValue: "")
    }

    private var canPair: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && code.count == 6 && !model.isPairing
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "link.circle.fill")
                            .font(.system(size: 42, weight: .medium))
                            .foregroundStyle(PR.accent)
                        Text("Pair Assistant or Companion")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(PR.fg)
                        Text("Use the private address and six-digit code shown by Vamp Assistant or Vamp Companion on your Mac. The code is single-use and expires shortly.")
                            .font(.subheadline)
                            .foregroundStyle(PR.fg2)
                    }

                    VampGlassActionButton(
                        title: "Scan pairing QR code",
                        systemImage: "qrcode.viewfinder",
                        action: {
                            scanError = nil
                            showScanner = true
                        }
                    )
                    .accessibilityHint("Scan the private Assistant or Companion QR code to fill the address and pairing code")

                    if let scanError {
                        Label(scanError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(PR.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Private address")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PR.dim)
                        TextField("192.168.1.20:9575", text: $address)
                            .focused($focusedField, equals: .address)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .code }
                            .padding(14)
                            .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
                            .accessibilityLabel("Vamp Assistant private address")
                            .accessibilityHint("Enter the local or Tailscale address of Vamp Assistant")
                        Text("Vamp Assistant uses port 9575. Plain HTTP is accepted only for local or private network addresses.")
                            .font(.caption)
                            .foregroundStyle(PR.dim)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pairing code")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PR.dim)
                        TextField("000000", text: $code)
                            .focused($focusedField, equals: .code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .onChangeCompat(of: code) { newValue in
                                let digits = String(newValue.filter(\.isNumber).prefix(6))
                                if digits != newValue { code = digits }
                            }
                            .padding(14)
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .tracking(4)
                            .multilineTextAlignment(.center)
                            .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
                            .accessibilityLabel("Six-digit pairing code")
                            .accessibilityHint("Enter the one-time code shown by Vamp Assistant")
                    }

                    if let error = model.lastError {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(PR.warn)
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(PR.fg)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
                        .accessibilityElement(children: .combine)
                    }

                    Button {
                        Task { await model.pair(address: address, code: code) }
                    } label: {
                        HStack {
                            if model.isPairing { ProgressView().tint(PR.bg) }
                            Text(model.isPairing ? "Pairing…" : "Pair Mac")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(PR.bg)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(PR.fg)
                        )
                    }
                    .buttonStyle(PRGlassPressButtonStyle())
                    .disabled(!canPair)
                    .opacity(canPair ? 1 : 0.4)
                    .accessibilityLabel(model.isPairing ? "Pairing with Vamp Assistant" : "Pair with Vamp Assistant")
                    .accessibilityHint("Connect using the private address and one-time code")

                    Text("Only pair with a Mac you recognize. Keep Assistant or Companion on your LAN or private Tailscale network; never expose its host port to the public internet.")
                        .font(.caption)
                        .foregroundStyle(PR.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(22)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(pairingBackground)
            .navigationTitle("Vamp Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityHint("Close Vamp Assistant pairing")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                        .fontWeight(.semibold)
                        .accessibilityHint("Hide the keyboard and continue pairing")
                }
            }
        }
        .onChangeCompat(of: model.session?.address) { newAddress in
            if newAddress != nil { dismiss() }
        }
        .preferredColorScheme(.dark)
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

    private var pairingBackground: some View {
        ZStack {
            Color(red: 0.035, green: 0.05, blue: 0.075)
            Image("AppBackdrop")
                .resizable()
                .scaledToFill()
                .opacity(0.68)
            LinearGradient(
                colors: [
                    Color.black.opacity(0.48),
                    Color.black.opacity(0.18),
                    Color.black.opacity(0.66)
                ],
                startPoint: .top,
                endPoint: .bottom)
        }
        .ignoresSafeArea()
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
            scanError = "That QR code is not an Assistant or Companion pairing link. Scan the code shown by either app on your Mac."
        }
    }
}
