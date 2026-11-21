import SwiftUI

/// Vamp Pro on the Mac App Store build: the daily allowance, the one-time unlock, and restore.
/// Shown when a new session would exceed the free 15 minutes, and from the Vamp Pro settings tab.
struct MacStreamingPaywallView: View {
    @ObservedObject var unlock: StreamingUnlockStore
    @ObservedObject var usage: DailyStreamingUsage
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: unlock.isEffectivelyUnlocked ? "checkmark.seal.fill" : "sparkles")
                    .font(.title)
                    .foregroundStyle(unlock.isEffectivelyUnlocked ? Color.green : MacBrand.accent)
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vamp Pro")
                        .font(.title2.weight(.semibold))
                    Text(unlock.isEffectivelyUnlocked ? "Unlocked on this Mac" : "Free: 15 minutes of streaming a day")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if !unlock.isEffectivelyUnlocked {
                usageMeter
            }

            Text("One-time purchase. No subscription. Removes the daily limit for Vamp Control.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let error = unlock.purchaseError {
                Label(error, systemImage: "xmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if let notice = unlock.purchaseNotice {
                Label(notice, systemImage: "clock.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Restore Purchase") { Task { await unlock.restore() } }
                    .disabled(unlock.isLoading)
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                if !unlock.isEffectivelyUnlocked {
                    Button {
                        Task { await unlock.purchase() }
                    } label: {
                        Text("Unlock for \(unlock.product?.displayPrice ?? "$14.99")")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(unlock.isLoading || unlock.product == nil)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(MacBrand.pageBackdrop)
        .task {
            if unlock.product == nil { await unlock.refresh() }
        }
        .onChange(of: unlock.isEffectivelyUnlocked) { unlocked in
            guard unlocked else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: onDismiss)
        }
    }

    private var usageMeter: some View {
        let minutesUsed = Int(usage.secondsUsedToday / 60)
        let minutesLeft = max(0, Int(DailyStreamingUsage.dailyLimitSeconds / 60) - minutesUsed)
        return VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: min(usage.secondsUsedToday / DailyStreamingUsage.dailyLimitSeconds, 1))
            Text(minutesLeft == 0 ? "Daily limit reached. Resets at midnight." : "\(minutesLeft) minutes left today")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
