import SwiftUI
import SharedModels

/// Settings uses the same canvas and materials as home. Changes apply immediately.
struct VampStreamSettingsSheet: View {
    @Binding var hostSource: VampStreamHostSource
    @Environment(\.dismiss) private var dismiss
    @AppStorage(VampStreamAppearance.key) private var appearance = VampStreamAppearance.dark
    @AppStorage(VampStreamAppearance.backgroundArtKey) private var showsBackgroundArt = true
    @State private var showsEditions = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    StreamSettingsIntroduction()
                    StreamAppIconSettings()
                    StreamAppearanceSettings(appearance: $appearance, showsBackgroundArt: $showsBackgroundArt)
                    VStack(alignment: .leading, spacing: 14) {
                        StreamEyebrow(title: "YOUR MAC APPS")
                        VampStreamHostSourceOptions(selection: Binding(get: { hostSource }, set: { if let source = $0 { hostSource = source } }))
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        StreamEyebrow(title: "GOOD TO KNOW")
                        DisclosureGroup("Sync editions & connection privacy", isExpanded: $showsEditions) {
                            VampStreamDistributionInfo().padding(.top, 16)
                        }
                        .font(.subheadline.weight(.medium))
                        .tint(StreamDesign.text)
                        .padding(22).streamGlass()
                        Text("Designed around your Mac. Made for your hands.")
                            .font(.caption).foregroundStyle(StreamDesign.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 10)
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(24).frame(maxWidth: .infinity)
            }
            .background { VampStreamEnvironmentBackdrop() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold).tint(StreamDesign.text)
                }
            }
        }
        .preferredColorScheme(appearance.colorScheme)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

private struct StreamSettingsIntroduction: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StreamBrandMark().frame(width: 38, height: 38)
            Text("Make it yours.")
                .font(.largeTitle.weight(.medium)).tracking(-1.5).foregroundStyle(StreamDesign.text)
            Text("A space that feels like you.")
                .font(.body).foregroundStyle(StreamDesign.secondary)
        }
    }
}

private struct StreamAppearanceSettings: View {
    @Binding var appearance: VampStreamAppearance
    @Binding var showsBackgroundArt: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StreamEyebrow(title: "ATMOSPHERE")
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                ForEach(VampStreamAppearance.allCases) { option in
                    StreamAppearanceChoice(option: option, selected: appearance == option) { appearance = option }
                }
            }
            Toggle(isOn: $showsBackgroundArt) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ribbon background").font(.subheadline.weight(.medium)).foregroundStyle(StreamDesign.text)
                    Text("Warm light, flowing behind the glass.")
                        .font(.footnote).foregroundStyle(StreamDesign.secondary)
                }
            }
            .tint(StreamDesign.accent).padding(22).streamGlass()
        }
    }
}

private struct StreamAppearanceChoice: View {
    let option: VampStreamAppearance
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack(alignment: .bottom) {
                    StreamAtmosphere().environment(\.colorScheme, option == .light ? .light : .dark)
                    if option == .system {
                        StreamAtmosphere().environment(\.colorScheme, .light).mask { HStack(spacing: 0) { Color.black; Color.clear } }
                    }
                    RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.3)).frame(height: 25).padding(10)
                }
                .frame(height: 90).clipShape(RoundedRectangle(cornerRadius: 16))
                HStack(spacing: 5) {
                    Text(option.title).font(.caption.weight(.medium))
                    if selected { Image(systemName: "checkmark.circle.fill").font(.caption) }
                }
                .foregroundStyle(selected ? StreamDesign.accent : StreamDesign.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 23).strokeBorder(selected ? StreamDesign.accent.opacity(0.7) : StreamDesign.line, lineWidth: selected ? 1.5 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 23))
        }
        .buttonStyle(StreamPressStyle())
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct VampStreamHostSourceOptions: View {
    @Binding var selection: VampStreamHostSource?
    var body: some View {
        VStack(spacing: 0) {
            ForEach(VampStreamHostSource.allCases) { source in
                Button { selection = source } label: {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: source.icon)
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(StreamDesign.accent).frame(width: 32)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(source.title).font(.subheadline.weight(.medium)).foregroundStyle(StreamDesign.text)
                            Text(source.detail).font(.caption).foregroundStyle(StreamDesign.secondary)
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: selection == source ? "checkmark.circle.fill" : "circle")
                            .font(.title3.weight(.light))
                            .foregroundStyle(selection == source ? StreamDesign.accent : StreamDesign.secondary.opacity(0.6))
                    }
                    .padding(20).frame(minHeight: 80).contentShape(Rectangle())
                }
                .buttonStyle(StreamPressStyle())
                .accessibilityAddTraits(selection == source ? .isSelected : [])
                if source != VampStreamHostSource.allCases.last {
                    Rectangle().fill(StreamDesign.line).frame(height: 0.5).padding(.leading, 65)
                }
            }
        }
        .streamGlass()
    }
}
