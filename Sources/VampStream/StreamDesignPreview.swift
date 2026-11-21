#if DEBUG
import SwiftUI
import SharedProtocol
import UIKit

/// Isolated design fixtures. Never connects to a host or enters a release build.
/// Launch with --stream-design-preview=welcome|library|player|connecting.
struct StreamDesignPreview: View {
    let route: String
    @State private var filter = StreamLibraryFilter.all
    @State private var search = ""
    @State private var favorites: Set<String> = ["notes"]
    @State private var showsHelp = false
    @State private var showsPlayer = false
    @State private var controlsHidden = false
    @State private var adjustsView = false
    @State private var keyboard = false
    @State private var markup = false

    static var route: String? {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--stream-design-preview=") }
            .map { String($0.dropFirst("--stream-design-preview=".count)) }
    }

    var body: some View {
        ZStack {
            VampStreamEnvironmentBackdrop()
            switch route {
            case "welcome":
                VStack(spacing: 0) {
                    StreamHomeMasthead(onSettings: {})
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            StreamHomeIntroduction(hasMacs: false)
                            StreamWorkspaceIllustration()
                            StreamFirstConnectionGuide()
                        }
                        .frame(maxWidth: 620)
                        .padding(24).frame(maxWidth: .infinity)
                    }
                }
                .safeAreaInset(edge: .bottom) { StreamHomeFooter(hasMacs: false, onAdd: {}) }
            case "connecting":
                VampStreamConnectingView(name: "Studio Mac", detail: "Compare the fingerprint on your Mac before approving this device.",
                                         fingerprint: String(repeating: "0123456789abcdef", count: 4), onCancel: {})
            case "player": player
            case "help-view-only": AppStreamGestureHelpView(isViewOnly: true)
            case "settings": VampStreamSettingsSheet(hostSource: .constant(.both))
            default: library
            }
        }
        .sheet(isPresented: $showsHelp) { AppStreamGestureHelpView() }
        .fullScreenCover(isPresented: $showsPlayer) { player }
    }

    private var visible: [RemoteApplication] {
        Self.apps.filter {
            (search.isEmpty || $0.name.localizedStandardContains(search))
            && (filter == .all || (filter == .running && $0.isRunning) || (filter == .favorites && favorites.contains($0.id)))
        }
    }

    private var library: some View {
        VStack(spacing: 0) {
            StreamLibraryHeader(macName: "Studio Mac", onClose: {})
            VStack(spacing: 14) {
                VampAppSearchField(text: $search)
                StreamLibraryFilters(selection: $filter)
            }
            .padding(.horizontal, 24)
            ScrollView {
                LazyVStack(spacing: 12) {
                    if visible.isEmpty {
                        StreamLibraryEmptyState(filter: filter, isSearching: !search.isEmpty)
                    } else {
                        StreamLibrarySectionHeading(title: filter == .all ? "On your Mac" : filter.title, count: visible.count)
                        LazyVStack(spacing: 0) {
                            ForEach(visible) { app in
                                AppStreamApplicationRow(application: app, isFavorite: favorites.contains(app.id)) { showsPlayer = true }
                                    .contextMenu {
                                        Button(favorites.contains(app.id) ? "Remove from Favorites" : "Add to Favorites", systemImage: "star") {
                                            if favorites.contains(app.id) { favorites.remove(app.id) } else { favorites.insert(app.id) }
                                        }
                                    }
                                if app.id != visible.last?.id {
                                    Rectangle().fill(StreamDesign.line).frame(height: 0.5).padding(.leading, 80)
                                }
                            }
                        }
                        .appQuietSurface()
                    }
                    Text("DESIGN PREVIEW · SAMPLE APPS")
                        .font(.system(.caption2, design: .monospaced)).tracking(1.5)
                        .foregroundStyle(StreamDesign.secondary).padding(.top, 16)
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .frame(maxWidth: StreamDesign.maxWidth)
        .frame(maxWidth: .infinity)
    }

    private var player: some View {
        ZStack {
            StreamAtmosphere().opacity(0.4)
            VStack(spacing: 20) {
                HStack {
                    Text("Notes").font(.headline)
                    Spacer()
                    Text("DESIGN PREVIEW").font(.caption2.monospaced()).tracking(1)
                }
                .foregroundStyle(StreamDesign.secondary).padding(.horizontal, 24)
                StreamPreviewDocument().padding(.horizontal, 14)
                Spacer(minLength: 0)
            }
            .padding(.top, 24)
        }
        .safeAreaInset(edge: .bottom) {
            if controlsHidden {
                AppStreamChromeRevealButton(bottomInset: 0) { controlsHidden = false }
            } else {
                AppStreamChromePill {
                    AppStreamChromeButton(systemName: "square.grid.2x2", accessibilityLabel: "Back to apps") { showsPlayer = false }
                    AppStreamChromeButton(systemName: "pencil.tip", isActive: markup, accessibilityLabel: "Markup") { markup.toggle() }
                    AppStreamChromeButton(systemName: "keyboard", isActive: keyboard, accessibilityLabel: "Keyboard") { keyboard.toggle() }
                    AppStreamChromeButton(systemName: "viewfinder", isActive: adjustsView, accessibilityLabel: "Adjust view") { adjustsView.toggle() }
                    AppStreamChromeMenu(systemName: "aspectratio", accessibilityLabel: "Window size") {
                        Button("Adaptive resize") {}
                        Button("Original size") {}
                    }
                    AppStreamChromeMenu(systemName: "ellipsis", accessibilityLabel: "Stream options") {
                        Button("Gesture help", systemImage: "hand.draw") { showsHelp = true }
                    }
                } trailing: {
                    AppStreamChromeDivider()
                    AppStreamChromeButton(systemName: "eye.slash", accessibilityLabel: "Hide controls") { controlsHidden = true }
                }
                .padding(.horizontal, 18).padding(.bottom, 12)
            }
        }
        .vampStreamVideoSurface()
    }

    private static let apps: [RemoteApplication] = [
        sample("safari", "Safari", "safari.fill", .systemBlue, running: true, active: true),
        sample("notes", "Notes", "note.text", .systemOrange, running: true),
        sample("xcode", "Xcode", "hammer.fill", .systemBlue, running: true),
        sample("terminal", "Terminal", "terminal.fill", .darkGray, running: true),
        sample("music", "Music", "music.note", .systemPink),
        sample("photos", "Photos", "camera.macro", .systemPurple)
    ]

    private static func sample(_ id: String, _ name: String, _ symbol: String, _ color: UIColor,
                               running: Bool = false, active: Bool = false) -> RemoteApplication {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96))
        let image = renderer.image { _ in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(x: 3, y: 3, width: 90, height: 90), cornerRadius: 22).fill()
            UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 48, weight: .regular))?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: 24, y: 24, width: 48, height: 48))
        }
        return RemoteApplication(bundleIdentifier: id, name: name, isRunning: running, isActive: active,
                                 iconPNGBase64: image.pngData()?.base64EncodedString(), windowIDs: running ? [id] : [])
    }
}

private struct StreamPreviewDocument: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            HStack {
                ForEach(0..<3) { _ in Circle().fill(Color.black.opacity(0.15)).frame(width: 7, height: 7) }
                Spacer()
                Image(systemName: "square.and.pencil").font(.subheadline)
            }
            .foregroundStyle(Color(hex: 0x7C6753))
            Text("A little room\nto think.")
                .font(.system(size: 38, weight: .medium, design: .serif)).tracking(-1.5)
            Text("STUDIO NOTES / 001").font(.caption.monospaced()).tracking(2).foregroundStyle(Color(hex: 0x8D735A))
            Rectangle().fill(Color.black.opacity(0.1)).frame(height: 1)
            Text("Keep the good ideas close.\nGive the next one a little space.")
                .font(.body).lineSpacing(7)
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.065))
                    .frame(maxWidth: i == 3 ? 140 : .infinity).frame(height: 6)
            }
            Spacer(minLength: 30)
        }
        .foregroundStyle(Color(hex: 0x3D332E)).padding(28)
        .frame(maxWidth: 620, minHeight: 490, alignment: .topLeading)
        .background(Color(hex: 0xF5EDE0), in: RoundedRectangle(cornerRadius: 18))
    }
}
#endif
