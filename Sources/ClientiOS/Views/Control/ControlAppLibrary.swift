import SwiftUI
import SharedProtocol
import UIKit

/// Vamp Control's app-window library. Vamp Stream browses the same `AppStreamViewModel` with its
/// own `StreamLibraryHeader` and rows; this draws that list in Control's language: the ambient
/// canvas, clear glass surfaces, monospaced meta labels, capsule actions, and color only for status.
struct ControlAppLibrary: View {
    let macName: String
    /// Already filtered and ordered by the caller, so the list and its count agree.
    let apps: [RemoteApplication]
    let isLoading: Bool
    let failure: String?
    let isViewOnly: Bool
    let favoriteIDs: [String]
    let leaveTitle: LocalizedStringKey
    let leaveSymbol: String
    @Binding var searchText: String
    @Binding var filter: StreamLibraryFilter
    let onOpen: (RemoteApplication, String?) -> Void
    let onToggleFavorite: (RemoteApplication) -> Void
    let onRequestClose: (RemoteApplication) -> Void
    let onRefresh: () -> Void
    let onLeave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(spacing: 12) {
                search
                filters
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let failure { notice(failure) }
                    if apps.isEmpty {
                        emptyState
                    } else {
                        sectionLabel
                        list
                        ControlMono(text: "Tap an app to stream its window. Hold for windows and favorites.", size: 8.5)
                            .padding(.leading, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { onRefresh() }
        }
        .frame(maxWidth: ControlDesign.maxWidth, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { ControlBackground().ignoresSafeArea() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ControlMono(text: isViewOnly ? "Apps · View only" : "Apps")
                Text(macName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(ControlDesign.ink)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button(action: onLeave) {
                Label(leaveTitle, systemImage: leaveSymbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ControlDesign.ink)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .controlGlass(radius: 22, interactive: true, emphasis: .control)
            }
            .buttonStyle(ControlPressStyle())
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var search: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ControlDesign.secondary)
            TextField("Search apps", text: $searchText)
                .font(.body)
                .foregroundStyle(ControlDesign.ink)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(ControlDesign.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
        .controlGlass(radius: 23, interactive: false, emphasis: .control)
    }

    private var filters: some View {
        HStack(spacing: 8) {
            ForEach(StreamLibraryFilter.allCases) { option in
                let selected = option == filter
                Button {
                    withAnimation(.smooth) { filter = option }
                } label: {
                    ControlMono(text: option.title, size: 9.5,
                                color: selected ? ControlDesign.buttonInk : ControlDesign.secondary)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 34)
                        .background(Capsule().fill(selected ? ControlDesign.ink : Color.clear))
                        .overlay { Capsule().strokeBorder(ControlDesign.line, lineWidth: 0.5) }
                }
                .buttonStyle(ControlPressStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    private var sectionLabel: some View {
        HStack {
            ControlMono(text: filter == .all ? "On your Mac" : filter.title)
            Spacer()
            ControlMono(text: "\(apps.count)")
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                let isFavorite = favoriteIDs.contains(app.id)
                ControlAppRow(application: app, isFavorite: isFavorite) {
                    onOpen(app, nil)
                }
                .contextMenu {
                    if app.windowIDs.count > 1 {
                        Menu("Windows", systemImage: "macwindow.on.rectangle") {
                            ForEach(Array(app.windowIDs.enumerated()), id: \.element) { position, id in
                                Button(app.windowTitles?[id] ?? "Window \(position + 1)") {
                                    onOpen(app, id)
                                }
                            }
                        }
                    }
                    Button(isFavorite ? "Remove from Favorites" : "Add to Favorites",
                           systemImage: isFavorite ? "star.slash" : "star") {
                        onToggleFavorite(app)
                    }
                    if !isViewOnly, app.isRunning, ApplicationClosePolicy.canClose(app.bundleIdentifier) {
                        Button("Close \(app.name)", systemImage: "xmark.app", role: .destructive) {
                            onRequestClose(app)
                        }
                    }
                }
                if index < apps.count - 1 {
                    Rectangle()
                        .fill(ControlDesign.line)
                        .frame(height: 0.5)
                        .padding(.leading, 72)
                }
            }
        }
        .padding(.vertical, 6)
        .controlGlass(radius: 24, interactive: false, emphasis: .surface)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLoading {
                ProgressView().tint(ControlDesign.ink)
                ControlMono(text: "Reading apps")
                Text("Asking \(macName) for its apps…")
                    .font(.callout)
                    .foregroundStyle(ControlDesign.secondary)
            } else {
                ControlMono(text: searchText.isEmpty ? "Nothing to stream yet" : "No matches")
                Text(searchText.isEmpty
                     ? "Open an app on your Mac, then pull down to refresh."
                     : "No app matches “\(searchText)”.")
                    .font(.callout)
                    .foregroundStyle(ControlDesign.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .controlGlass(radius: 24)
    }

    private func notice(_ reason: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ControlDesign.caution)
            Text(reason)
                .font(.footnote)
                .foregroundStyle(ControlDesign.ink)
            Spacer(minLength: 8)
            Button("Retry") { onRefresh() }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ControlDesign.ink)
        }
        .padding(16)
        .controlGlass(radius: 20)
    }
}

/// Opening a window: the same states as the Stream launch view, in Control's glass card.
struct ControlAppLaunching: View {
    let name: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
                .tint(ControlDesign.ink)
            ControlMono(text: "Opening")
            Text(name)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ControlDesign.ink)
                .multilineTextAlignment(.center)
            Button(action: onCancel) {
                Text("Cancel")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ControlDesign.ink)
                    .padding(.horizontal, 22)
                    .frame(minHeight: 44)
                    .controlGlass(radius: 22, interactive: true, emphasis: .control)
            }
            .buttonStyle(ControlPressStyle())
        }
        .padding(28)
        .frame(maxWidth: 360)
        .controlGlass(radius: ControlDesign.radius)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { ControlBackground().ignoresSafeArea() }
    }
}

private struct ControlAppRow: View {
    let application: RemoteApplication
    let isFavorite: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                ControlAppIcon(encoded: application.iconPNGBase64)
                VStack(alignment: .leading, spacing: 5) {
                    Text(application.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ControlDesign.ink)
                        .lineLimit(1)
                    ControlMono(text: status.text, size: 8.5, color: status.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(ControlDesign.ink.opacity(0.7))
                        .accessibilityLabel("Favorite")
                }
                if application.windowIDs.count > 1 {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ControlDesign.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ControlPressStyle())
        .accessibilityLabel(application.name)
        .accessibilityValue(Text(status.text))
        .accessibilityHint("Streams this app's window. Hold for more actions.")
    }

    /// Running state is the only color on the row, matching the rest of Control's status language.
    private var status: (text: LocalizedStringKey, color: Color) {
        if application.isActive { return ("Active now", ControlDesign.available) }
        guard application.isRunning else { return ("Not open", ControlDesign.secondary) }
        switch application.windowIDs.count {
        case 0: return ("Running · no window", ControlDesign.available)
        case 1: return ("Running · 1 window", ControlDesign.available)
        default: return ("Running · \(application.windowIDs.count) windows", ControlDesign.available)
        }
    }
}

/// The app's own icon as the Mac sent it, decoded once per payload.
private struct ControlAppIcon: View {
    let encoded: String?
    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        Group {
            if let image = decoded() {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(ControlDesign.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }

    private func decoded() -> UIImage? {
        guard let encoded, !encoded.isEmpty else { return nil }
        let key = "\(encoded.count):\(encoded.hashValue)" as NSString
        if let cached = Self.cache.object(forKey: key) { return cached }
        guard let data = Data(base64Encoded: encoded), let image = UIImage(data: data) else { return nil }
        Self.cache.setObject(image, forKey: key)
        return image
    }
}
