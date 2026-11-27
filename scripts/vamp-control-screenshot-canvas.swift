// Historical component-preview fixture only. Do not upload these renders to ASC.
// Store screenshots now use actual app-window captures through render-vamp-control-store-screenshots.py.
// Authoring-only sample models. These files are never compiled into Control.
private struct ScreenshotCapabilities: OptionSet {
    let rawValue: Int
    static let supportsAppStreaming = Self(rawValue: 1)
    static let supportsMultiDisplay = Self(rawValue: 2)
    static let supportsDesktopControl = Self(rawValue: 4)
}
private struct ScreenshotMetadata {
    let displayName: String
    let capabilities: ScreenshotCapabilities = [.supportsAppStreaming, .supportsDesktopControl]
}
private struct ScreenshotEndpoint { let metadata: ScreenshotMetadata }
private struct DiscoveredHostRow {
    let endpoint: ScreenshotEndpoint
    let subtitle: String
    let isSaved: Bool
    let isAvailable = true
}
private struct ScreenshotIdentity {
    let displayName = "Studio MacBook"
    let publicKeyFingerprint = "a1b2c3d4e5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcdef00"
}
@MainActor
private final class ScreenshotEnvironment: ObservableObject {
    @Published var preferredQualityPreset = StreamQualityPreset.quality
    @Published var showsStatsOverlay = true
    @Published var prefersViewOnly = false
    @Published var lowPowerModeEnabled = false
    let isUltraQualityEntitled = true
    let ultraQualityAvailabilityMessage: String? = nil
    let clientIdentity = ScreenshotIdentity()
}
@MainActor
final class AppStreamViewModel: ObservableObject {
    enum Status { case ready, loadingApps, launching(String), failed(String), targetLost(String) }
    @Published var status: Status = .ready
    @Published var applications: [RemoteApplication] = []
    init() {
        for (name, identifier, path) in [
            ("TextEdit", "com.apple.TextEdit", "/System/Applications/TextEdit.app"),
            ("Preview", "com.apple.Preview", "/System/Applications/Preview.app"),
            ("Notes", "com.apple.Notes", "/System/Applications/Notes.app"),
            ("Calendar", "com.apple.iCal", "/System/Applications/Calendar.app"),
            ("Calculator", "com.apple.calculator", "/System/Applications/Calculator.app"),
            ("Safari", "com.apple.Safari", "/Applications/Safari.app")
        ] {
            let image = NSWorkspace.shared.icon(forFile: path)
            let png = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
                .representation(using: .png, properties: [:])?.base64EncodedString()
            applications.append(.init(bundleIdentifier: identifier, name: name, isRunning: true,
                isActive: name == "TextEdit", iconPNGBase64: png, windowIDs: ["1"]))
        }
    }
    func backToApps() {}
    func select(_ app: RemoteApplication) {}
    func close(_ app: RemoteApplication) {}
}

private struct ScreenshotCopy {
    let titles: [String]
    let subtitles: [String]
    let details: [String]
}
private let copyByLocale: [String: ScreenshotCopy] = [
    "en-US": .init(
        titles: ["Your Mac.\nWithin reach.", "One app.\nAll your focus.", "Your keyboard.\nRight at home.", "Make it\nyour own.", "Start with\nVamp Sync."],
        subtitles: ["Connect to Vamp Sync for desktop and app-window streaming.", "Choose an available app from your remote Mac.", "Use familiar shortcuts and precise keyboard control.", "Set stream quality, session behavior, and sharing preferences.", "A clear setup guide, with your approval for every new device."],
        details: ["LAN OR PRIVATE TAILSCALE", "CHOOSE THE WINDOW YOU NEED", "INPUT DEPENDS ON HOST PERMISSION", "NATIVE MAC SETTINGS", "THE MAC APP STORE HOST IS VIEW ONLY"]),
    "tr": .init(
        titles: ["Mac’iniz.\nElinizin altında.", "Tek uygulama.\nTam odak.", "Klavyeniz.\nBildiğiniz gibi.", "Size göre\nayarlayın.", "Vamp Sync ile\nbaşlayın."],
        subtitles: ["Masaüstü ve uygulama penceresi yayını için Vamp Sync’e bağlanın.", "Uzak Mac’inizdeki açık uygulamalardan birini seçin.", "Tanıdık kısayolları ve hassas klavye kontrolünü kullanın.", "Yayın kalitesini, oturum davranışını ve paylaşım tercihlerini seçin.", "Her yeni cihaz için sizin onayınızla, anlaşılır bir kurulum rehberi."],
        details: ["LAN VEYA ÖZEL TAILSCALE AĞI", "İHTİYACINIZ OLAN PENCEREYİ SEÇİN", "KONTROL, UZAK MAC’İN İZİNLERİNE BAĞLIDIR", "YEREL MAC AYARLARI", "MAC APP STORE ANA BİLGİSAYARI YALNIZCA GÖRÜNTÜLEME SUNAR"])
]

private struct ScreenshotWindow<Content: View>: View {
    var title = "Vamp Control"
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.26)], id: \.self) { color in
                    Circle().fill(color).frame(width: 11, height: 11)
                }
                Spacer()
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Color.clear.frame(width: 49, height: 1)
            }.padding(.horizontal, 14).frame(height: 34).background(.bar)
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
    }
}

private struct ScreenshotHome: View {
    private func card(_ name: String, address: String, saved: Bool) -> some View {
        HostCardView(row: .init(endpoint: .init(metadata: .init(displayName: name)), subtitle: address, isSaved: saved),
            displayName: name, isRenamed: false, isBusy: false, canWake: false, isWaking: false,
            onConnect: {}, onWake: {}, onRename: {}, onResetName: {}, onToggleSave: {})
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                MacDiscoveryStatus(title: "2 online", tint: .green, isScanning: false, differentiateWithoutColor: false)
                Spacer(); MacBrandWordmark(); Spacer()
                Button {} label: { Image(systemName: "sparkles.rectangle.stack") }
                Button {} label: { Image(systemName: "arrow.clockwise") }
            }.padding(.horizontal, 22).frame(height: 40)
            VStack(alignment: .leading, spacing: 14) {
                Text("On your network").font(.subheadline.weight(.semibold))
                card("Studio Mac", address: "192.0.2.10:9471", saved: true)
                card("MacBook Pro", address: "100.64.0.42:9471", saved: false)
                Spacer()
            }.padding(.horizontal, 54).padding(.top, 24)
            Divider()
            HStack {
                TextField("Add a Mac by IP or hostname  (e.g. 192.168.1.20:9471)", text: .constant(""))
                    .textFieldStyle(.roundedBorder)
                Button("Add") {}.disabled(true)
            }.padding(.horizontal, 54).padding(.vertical, 10).background(.bar)
        }.background(MacBrand.pageBackdrop)
    }
}

private struct ScreenshotCanvas: View {
    let panel: NSImage
    let scene: Int
    let locale: String
    private var copy: ScreenshotCopy { copyByLocale[locale]! }
    private var compact: Bool { scene >= 2 }
    var body: some View {
        ZStack {
            Color(red: 0.965, green: 0.958, blue: 0.978)
            RadialGradient(colors: [Color(red: 0.86, green: 0.83, blue: 0.95).opacity(0.75), .clear],
                center: .topTrailing, startRadius: 0, endRadius: 950)
            RadialGradient(colors: [Color(red: 0.98, green: 0.87, blue: 0.89).opacity(0.7), .clear],
                center: .bottomLeading, startRadius: 0, endRadius: 700)
            HStack(spacing: compact ? 90 : 46) {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 11) {
                        Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit().frame(width: 44, height: 44)
                        Text("Vamp Control").font(.system(size: 20, weight: .semibold)).tracking(-0.5)
                    }.padding(.bottom, 28)
                    Text(copy.titles[scene]).font(.system(size: compact ? 53 : 46, weight: .bold))
                        .tracking(-2.1).lineSpacing(0).fixedSize(horizontal: false, vertical: true)
                    Text(copy.subtitles[scene]).font(.system(size: 20)).lineSpacing(5)
                        .foregroundStyle(Color.black.opacity(0.64)).fixedSize(horizontal: false, vertical: true)
                    Text(copy.details[scene]).font(.system(size: 10, weight: .semibold)).tracking(0.8)
                        .lineSpacing(4).foregroundStyle(Color(red: 0.43, green: 0.31, blue: 0.61))
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 15)
                }.frame(width: compact ? 390 : 310, alignment: .leading)
                Image(nsImage: panel).resizable().scaledToFit().frame(width: compact ? 520 : 765)
                    .shadow(color: .black.opacity(0.15), radius: 23, x: 0, y: 18)
            }.padding(.horizontal, compact ? 110 : 75)
        }.frame(width: 1280, height: 800)
        .foregroundStyle(Color(red: 0.16, green: 0.13, blue: 0.21))
        .environment(\.colorScheme, .light)
    }
}

@main
private enum ControlScreenshotRenderer {
    @MainActor
    static func render<V: View>(_ root: V, size: NSSize, to url: URL) throws -> NSImage {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear; window.isOpaque = false; window.alphaValue = 0
        let view = NSHostingView(rootView: root.environment(\.colorScheme, .light)
            .environment(\.controlActiveState, .active)
            .tint(Color(red: 0.39, green: 0.29, blue: 0.66)))
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        window.orderBack(nil)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.65))
        view.layoutSubtreeIfNeeded()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        let image = NSImage(size: size); image.addRepresentation(bitmap)
        window.close()
        return image
    }

    @MainActor
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .aqua)
        app.applicationIconImage = NSImage(contentsOf: Bundle.main.url(forResource: "ControlGlassIcon", withExtension: "icns")!)!
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let raw = output.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let panels: [(AnyView, NSSize)] = [
            (AnyView(ScreenshotWindow { ScreenshotHome() }), NSSize(width: 860, height: 550)),
            (AnyView(ScreenshotWindow { MacAppStreamPicker(vm: AppStreamViewModel(), hostName: "Studio Mac", onDisconnect: {}) }), NSSize(width: 860, height: 550)),
            (AnyView(MacKeyboardHelp(keepsDisplayShortcutsLocal: .constant(true)).background(Color(nsColor: .windowBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 14))), NSSize(width: 480, height: 485)),
            (AnyView(ScreenshotWindow(title: "Settings") { ScreenshotPreferences() }), NSSize(width: 540, height: 734)),
            (AnyView(MacOnboardingView(onDone: {}).clipShape(RoundedRectangle(cornerRadius: 14))), NSSize(width: 520, height: 540))
        ]
        let filenames = ["01-connect-to-vamp-sync.png", "02-stream-an-app.png", "03-keyboard-control.png", "04-your-preferences.png", "05-simple-setup.png"]
        for (scene, entry) in panels.enumerated() {
            let panel = try render(entry.0, size: entry.1, to: raw.appendingPathComponent(filenames[scene]))
            for locale in copyByLocale.keys.sorted() {
                let directory = output.appendingPathComponent("localizations/\(locale)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                _ = try render(ScreenshotCanvas(panel: panel, scene: scene, locale: locale), size: NSSize(width: 1280, height: 800), to: directory.appendingPathComponent(filenames[scene]))
                print("Rendered \(locale)/\(filenames[scene])")
            }
        }
    }
}
