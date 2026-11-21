import SwiftUI
import UIKit

/// iOS owns the selected Home Screen icon. Mirror it for the in-app brand mark only
/// after a successful change, including when returning from the background.
enum StreamAppIcon: String, CaseIterable, Identifiable {
    case ribbon, classic

    var id: String { rawValue }
    var alternateName: String? { self == .classic ? "VampStreamClassic" : nil }
    var previewAsset: String { self == .classic ? "StreamIconClassic" : "StreamIconRibbon" }
    var title: LocalizedStringKey { self == .classic ? "Classic" : "Ribbon" }

    @MainActor static var current: Self {
        UIApplication.shared.alternateIconName == Self.classic.alternateName ? .classic : .ribbon
    }

    @MainActor static func synchronizeBrandMark() {
        UserDefaults.standard.set(current == .classic, forKey: StreamBrandMark.preferenceKey)
    }
}

struct StreamAppIconSettings: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var selected = StreamAppIcon.current
    @State private var isChanging = false
    @State private var changeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StreamEyebrow(title: "APP ICON")
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                ForEach(StreamAppIcon.allCases) { icon in
                    Button { change(to: icon) } label: {
                        VStack(spacing: 12) {
                            Image(icon.previewAsset)
                                .resizable().scaledToFit().frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                                .accessibilityHidden(true)
                            HStack(spacing: 7) {
                                Text(icon.title).font(.subheadline.weight(.medium))
                                Image(systemName: selected == icon ? "checkmark.circle.fill" : "circle")
                                    .accessibilityHidden(true)
                            }
                            .foregroundStyle(selected == icon ? StreamDesign.accent : StreamDesign.secondary)
                        }
                        .padding(20).frame(maxWidth: .infinity)
                        .streamGlass(radius: 24)
                        .overlay(RoundedRectangle(cornerRadius: 24)
                            .strokeBorder(selected == icon ? StreamDesign.accent.opacity(0.7) : .clear, lineWidth: 1.5))
                        .contentShape(RoundedRectangle(cornerRadius: 24))
                    }
                    .buttonStyle(StreamPressStyle())
                    .disabled(isChanging || !UIApplication.shared.supportsAlternateIcons)
                    .accessibilityLabel(icon.title)
                    .accessibilityHint("Change the Home Screen icon and app logo")
                    .accessibilityAddTraits(selected == icon ? .isSelected : [])
                }
            }
            if isChanging {
                ProgressView("Changing icon…").font(.footnote).tint(StreamDesign.accent)
            } else {
                Text("Your Home Screen icon and the logo inside the app.")
                    .font(.footnote).foregroundStyle(StreamDesign.secondary)
            }
        }
        .onAppear(perform: refreshSelection)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !isChanging { refreshSelection() }
        }
        .alert("Couldn’t change the icon", isPresented: Binding(
            get: { changeError != nil }, set: { if !$0 { changeError = nil } }
        )) {
            Button("OK", role: .cancel) { changeError = nil }
        } message: {
            Text(changeError ?? "Please try again.")
        }
    }

    private func refreshSelection() {
        selected = .current
        StreamAppIcon.synchronizeBrandMark()
    }

    private func change(to icon: StreamAppIcon) {
        guard icon != selected, !isChanging else { return }
        isChanging = true
        Task { @MainActor in
            defer { isChanging = false }
            do {
                try await UIApplication.shared.setAlternateIconName(icon.alternateName)
                refreshSelection()
            } catch {
                changeError = error.localizedDescription
            }
        }
    }
}
