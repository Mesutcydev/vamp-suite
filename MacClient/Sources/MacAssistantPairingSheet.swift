import SwiftUI

struct MacAssistantPairingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MacAssistantSession
    @State private var address: String
    @State private var code = ""

    init(model: MacAssistantSession) {
        self.model = model
        _address = State(initialValue: model.savedAddress ?? "")
    }

    private var canPair: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && code.count == 6
            && !model.isWorking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 54, height: 54)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pair Vamp Assistant")
                        .font(.title2.weight(.semibold))
                    Text("Enter the private address and single-use code shown by Vamp Assistant. LAN and private Tailscale addresses are supported.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Private address").font(.callout.weight(.semibold))
                TextField("192.168.1.20:9575", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Vamp Assistant private address")
                Text("Plain HTTP is accepted only for private LAN, local, or Tailscale addresses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Six-digit pairing code").font(.callout.weight(.semibold))
                TextField("000000", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3.monospacedDigit())
                    .onChange(of: code) { value in
                        let digits = String(value.filter(\.isNumber).prefix(6))
                        if digits != value { code = digits }
                    }
                    .accessibilityLabel("Six-digit pairing code")
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    Task { await model.pair(address: address, code: code) }
                } label: {
                    if model.isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Pair Mac")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canPair)
            }
        }
        .padding(26)
        .frame(width: 520)
        .background(MacBrand.pageBackdrop)
        .onChange(of: model.connected?.address) { address in
            if address != nil { dismiss() }
        }
    }
}
