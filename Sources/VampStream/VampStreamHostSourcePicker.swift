import SwiftUI

struct VampStreamHostSourceOnboarding: View {
    var nearbyMacNames: [String] = []
    let onContinue: (VampStreamHostSource) -> Void
    @State private var draft: VampStreamHostSource?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                Text(VampStreamHomeCopy.hostOnboardingTitle)
                    .font(.title2.weight(.semibold))
                Text(VampStreamHomeCopy.hostOnboardingDetail)
                    .font(.subheadline)
                    .foregroundStyle(StreamReading.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !nearbyMacNames.isEmpty {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Label(VampStreamHomeCopy.hostOnboardingNearbyTitle, systemImage: "network")
                            .font(.headline)
                        Text(nearbyMacNames.joined(separator: ", "))
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(VampStreamHomeCopy.hostOnboardingNearbyDetail)
                            .font(.footnote)
                            .foregroundStyle(StreamReading.secondary)
                    }
                    .padding(AppHostMetrics.cardPadding)
                    .background(
                        StreamReading.surface,
                        in: RoundedRectangle(cornerRadius: AppHostMetrics.cardRadius, style: .continuous))
                }
                VampStreamHostSourceOptions(selection: $draft)
                VampStreamDistributionInfo()
            }
            .padding(AppHostMetrics.screenInset)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: AppSpacing.xs) {
                if draft == nil {
                    Text(VampStreamHomeCopy.hostOnboardingPrompt)
                        .font(.footnote)
                        .foregroundStyle(StreamReading.secondary)
                }
                Button {
                    if let draft { onContinue(draft) }
                } label: {
                    Text(VampStreamHomeCopy.hostOnboardingContinue)
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: AppHostMetrics.controlHeight)
                        .contentShape(Rectangle())
                }
                .background(
                    draft == nil ? StreamReading.surface : PR.fg,
                    in: RoundedRectangle(cornerRadius: AppHostMetrics.controlRadius, style: .continuous))
                .foregroundStyle(draft == nil ? StreamReading.secondary : Color(uiColor: .systemBackground))
                .disabled(draft == nil)
            }
            .padding(AppHostMetrics.screenInset)
            .background(Color(uiColor: .systemBackground))
        }
    }
}

/// Stream's settings: which Mac app to show, appearance, and the background artwork.
/// Every choice applies as it is made, so there is nothing to confirm or cancel.
struct VampStreamSettingsSheet: View {
    @Binding var hostSource: VampStreamHostSource
    @Environment(\.dismiss) private var dismiss
    @AppStorage(VampStreamAppearance.key) private var appearance = VampStreamAppearance.dark
    @AppStorage(VampStreamAppearance.backgroundArtKey) private var showsBackgroundArt = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    section("Mac app") {
                        VampStreamHostSourceOptions(selection: Binding(
                            get: { hostSource },
                            set: { if let source = $0 { hostSource = source } }))
                    }
                    VampStreamDistributionInfo()
                    section("Appearance") {
                        Picker("Appearance", selection: $appearance) {
                            ForEach(VampStreamAppearance.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    section("Background") {
                        Toggle(isOn: $showsBackgroundArt) {
                            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                                Text("Background artwork")
                                    .font(.headline)
                                    .foregroundStyle(PR.fg)
                                Text("Turn off for a plain background with solid cards.")
                                    .font(.footnote)
                                    .foregroundStyle(StreamReading.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(AppHostMetrics.cardPadding)
                        .appQuietSurface()
                    }
                }
                .padding(AppHostMetrics.screenInset)
            }
            .background { VampStreamEnvironmentBackdrop() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        // A presented sheet does not pick up the root's scheme change until it is dismissed.
        .preferredColorScheme(appearance.colorScheme)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(StreamReading.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

struct VampStreamHostSourceOptions: View {
    @Binding var selection: VampStreamHostSource?

    var body: some View {
        VStack(spacing: AppHostMetrics.cardGap) {
            ForEach(VampStreamHostSource.allCases) { source in
                Button {
                    selection = source
                } label: {
                    HStack(alignment: .top, spacing: AppSpacing.sm) {
                        Image(systemName: source.icon)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(PR.fg)
                            .frame(
                                width: AppHostMetrics.providerIcon,
                                height: AppHostMetrics.providerIcon)
                            .prGlassSurface(
                                in: RoundedRectangle(
                                    cornerRadius: AppHostMetrics.chipRadius, style: .continuous))
                        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                            Text(source.title)
                                .font(.headline)
                                .foregroundStyle(PR.fg)
                            Text(source.detail)
                                .font(.footnote)
                                .foregroundStyle(StreamReading.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: AppSpacing.xs)
                        Image(systemName: selection == source ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(PR.fg)
                    }
                    .padding(AppHostMetrics.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .vampHomeLiveGlass(
                        in: RoundedRectangle(cornerRadius: PR.rCard, style: .continuous),
                        phaseOffset: source == .sync ? 0.2 : (source == .assistant ? 0.9 : 1.6)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: PR.rCard, style: .continuous)
                            .strokeBorder(selection == source ? PR.fg.opacity(0.28) : Color.clear, lineWidth: 1.5)
                    }
                }
                .buttonStyle(PRGlassPressButtonStyle())
                .accessibilityAddTraits(selection == source ? [.isSelected] : [])
                .accessibilityLabel(source.title)
                .accessibilityHint(source.detail)
            }
        }
    }
}
