import SwiftUI

struct ControlLockView: View {
    @ObservedObject var lockService: AppLockService
    var body: some View {
        VStack(spacing: ControlDesign.section) {
            ControlWordmark().padding(.top, ControlDesign.gutter)
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 56, weight: .ultraLight)).foregroundStyle(ControlDesign.accent)
                .accessibilityHidden(true)
            VStack(spacing: ControlDesign.gap) {
                Text("Just for you.").font(.largeTitle.weight(.bold))
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
            ControlPrivacyFootnote().padding(.bottom, ControlDesign.section)
        }
        .foregroundStyle(ControlDesign.ink).padding(.horizontal, ControlDesign.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { ControlBackground() }
        .task { await lockService.authenticate() }
    }
}
