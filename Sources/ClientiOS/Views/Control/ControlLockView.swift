import SwiftUI

struct ControlLockView: View {
    @ObservedObject var lockService: AppLockService
    var body: some View {
        VStack(spacing: 28) {
            ControlWordmark().padding(.top, 20)
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 56, weight: .ultraLight)).foregroundStyle(ControlDesign.accent)
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("Just for you.").font(.largeTitle.weight(.bold)).tracking(-1.2)
                Text("Unlock Control to return to your Mac.")
                    .font(.subheadline).foregroundStyle(ControlDesign.secondary)
            }
            .multilineTextAlignment(.center)
            if let error = lockService.authError {
                Text(error).font(.subheadline).foregroundStyle(ControlDesign.accent)
                    .multilineTextAlignment(.center)
            }
            ControlPrimaryButton(title: lockService.isAuthenticating ? "Unlocking…" : "Unlock Control",
                                 symbol: "lock.open", isDisabled: lockService.isAuthenticating) {
                Task { await lockService.authenticate() }
            }.frame(maxWidth: 320)
            Spacer()
            ControlPrivacyFootnote().padding(.bottom, 24)
        }
        .foregroundStyle(ControlDesign.ink).padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { ControlBackground() }
        .task { await lockService.authenticate() }
    }
}
