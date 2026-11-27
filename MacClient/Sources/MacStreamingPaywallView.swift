import SwiftUI

/// Vamp Pro on the Mac App Store build: the daily allowance, the one-time unlock, and restore.
/// Shown when a new session would exceed the free 15 minutes, and from the Vamp Pro settings tab.
struct MacStreamingPaywallView: View {
    @ObservedObject var unlock: StreamingUnlockStore
    @ObservedObject var usage: DailyStreamingUsage
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                MacMarkTile(size: 52, arc: .control, badge: unlock.isEffectivelyUnlocked ? "checkmark" : "sparkles")
                VStack(alignment: .leading, spacing: 3) {
                    MacMetaLabel(text: "Vamp Pro · one-time")
                    Text("Vamp Pro")
                        .font(.system(size: 20, weight: .bold))
                    Text(unlock.isEffectivelyUnlocked ? "Unlocked on this Mac" : "Free: 15 minutes of streaming a day")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if !unlock.isEffectivelyUnlocked {
                MacUsageMeter(usage: usage)
            }

            Text("One-time purchase. No subscription. Removes the daily limit for Vamp Control.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = unlock.purchaseError {
                HStack(alignment: .top, spacing: 6) {
                    MacStatusDot(tone: .attention)
                    Text(error).font(.callout)
                }
            } else if let notice = unlock.purchaseNotice {
                HStack(alignment: .top, spacing: 6) {
                    MacStatusDot(tone: .idle)
                    Text(notice).font(.callout).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button("Restore Purchase") { Task { await unlock.restore() } }
                    .buttonStyle(MacCapsuleButtonStyle(kind: .quiet, large: true))
                    .disabled(unlock.isLoading)
                Spacer()
                Button("Done", action: onDismiss)
                    .buttonStyle(MacCapsuleButtonStyle(kind: .glass, large: true))
                    .keyboardShortcut(.cancelAction)
                if !unlock.isEffectivelyUnlocked {
                    Button {
                        Task { await unlock.purchase() }
                    } label: {
                        Text("Unlock for \(unlock.product?.displayPrice ?? "$14.99")")
                    }
                    .buttonStyle(MacCapsuleButtonStyle(kind: .primary, large: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(unlock.isLoading || unlock.product == nil)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(MacBrand.pageBackdrop)
        .task {
            if unlock.product == nil { await unlock.refresh() }
        }
        .onChange(of: unlock.isEffectivelyUnlocked) { unlocked in
            guard unlocked else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: onDismiss)
        }
    }
}
