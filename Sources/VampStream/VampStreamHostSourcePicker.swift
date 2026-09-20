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
                    draft == nil ? StreamReading.surface : Color.white,
                    in: RoundedRectangle(cornerRadius: AppHostMetrics.controlRadius, style: .continuous))
                .foregroundStyle(draft == nil ? StreamReading.secondary : .black)
                .disabled(draft == nil)
            }
            .padding(AppHostMetrics.screenInset)
            .background(Color.black)
        }
    }
}

struct VampStreamHostSourcePickerSheet: View {
    let current: VampStreamHostSource
    let onSelect: (VampStreamHostSource) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: VampStreamHostSource?

    init(current: VampStreamHostSource, onSelect: @escaping (VampStreamHostSource) -> Void) {
        self.current = current
        self.onSelect = onSelect
        _draft = State(initialValue: current)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VampStreamHostSourceOptions(selection: $draft)
                    .padding(AppHostMetrics.screenInset)
            }
            .navigationTitle(VampStreamHomeCopy.changeHost)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let draft {
                            onSelect(draft)
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
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
