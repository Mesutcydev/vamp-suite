import SwiftUI

struct OnboardingFlow: View {
    @StateObject private var vm = OnboardingViewModel()
    let knownHosts: [Host]
    let onSkip: () -> Void
    let onComplete: (Host) -> Void

    var body: some View {
        ZStack {
            PR.bg.ignoresSafeArea()

            switch vm.step {
            case .welcome:
                WelcomeStep(
                    knownHostCount: knownHosts.count,
                    start: { vm.step = .stream },
                    skip: onSkip
                )
            case .stream:
                StreamStep(vm: vm) { host in
                    Task { await vm.pick(host) }
                }
                .task {
                    await vm.startStream(known: knownHosts)
                }
            case .done:
                if let host = vm.pickedHost {
                    DoneStep(host: host) {
                        onComplete(host)
                    }
                }
            }
        }
        .onChangeCompat(of: vm.pairingDone) { done in
            if done {
                Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    withAnimation(.linear(duration: 0.2)) {
                        vm.step = .done
                    }
                }
            }
        }
        .onAppear {
            vm.updateKnownHosts(knownHosts)
        }
        .onChangeCompat(of: knownHosts) { hosts in
            vm.updateKnownHosts(hosts)
            guard vm.step == .stream, vm.pickedHost == nil, vm.foundNoHosts, !hosts.isEmpty else {
                return
            }
            Task { await vm.rescan() }
        }
    }
}

#Preview("OnboardingFlow") {
    OnboardingFlow(
        knownHosts: [],
        onSkip: {},
        onComplete: { _ in }
    )
}
