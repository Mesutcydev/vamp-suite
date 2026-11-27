import AppKit
import SharedModels
import SwiftUI
import CoreImage

/// Neutral, appearance-adaptive design tokens for the Mac client.
///
/// Reskinned to match the host's native macOS redesign: the app follows the
/// system appearance (light/dark) and uses the user's system accent color
/// rather than a fixed brand color. Tokens map to system colors so everything
/// adapts for free.
enum MacBrand {
    static let accent = Color.accentColor

    /// Neutral adaptive page backdrop — the native window background, no wash.
    static var pageBackdrop: some View {
        MacWindowBackdrop()
    }

    static let cardCornerRadius: CGFloat = 12

    /// Display face for the "Vamp Control" wordmark.
    ///
    /// Luminari ships with macOS and is the gothic face the Vamp brand leans on.
    /// `Font.custom(_:size:)` falls back to the system font *silently* when a
    /// face is missing, which would leave the wordmark looking like an
    /// accidentally oversized label — so resolve it through AppKit first and
    /// pick the fallback deliberately. Fixed size: this is chrome, and a
    /// wordmark that grows with the text-size setting would break the toolbar.
    static func wordmarkFont(size: CGFloat) -> Font {
        for name in ["Luminari", "Trattatello"] where NSFont(name: name, size: size) != nil {
            return .custom(name, fixedSize: size)
        }
        return .system(size: size, weight: .semibold, design: .serif)
    }
}

/// Centred toolbar wordmark. Replaces the native window title on the host list,
/// which AppKit crams in beside the leading toolbar items.
struct MacBrandWordmark: View {
    var body: some View {
        Text("Vamp Control")
            .font(MacBrand.wordmarkFont(size: 17))
            .foregroundStyle(.primary)
            .kerning(0.5)
            .lineLimit(1)
            .fixedSize()
            .accessibilityAddTraits(.isHeader)
    }
}

/// The shared Vamp architectural backdrop, matching Vamp Host and Vamp Sync.
///
/// This is what makes the glass work. The window used to be genuinely
/// transparent so Liquid Glass could refract the desktop — but that handed the
/// contrast behind every label to whatever wallpaper the user happened to have,
/// and on a dark one in Light Mode the text became unreadable. Painting the
/// product's own artwork instead gives the glass something rich to sample *and*
/// a predictable contrast floor, via the adaptive veil below.
private struct MacWindowBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(nsColor: .windowBackgroundColor)

                Image("HostBackdrop")
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .saturation(colorScheme == .dark ? 0.82 : 0.96)
                    .contrast(colorScheme == .dark ? 1.04 : 1.02)
                    .opacity(reduceTransparency || contrast == .increased ? 0.12 : (colorScheme == .dark ? 0.42 : 0.40))

                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color.black.opacity(0.18), Color.black.opacity(0.36)]
                        : [Color.white.opacity(0.08), Color(nsColor: .windowBackgroundColor).opacity(0.20)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: colorScheme == .dark
                        ? [Color.black.opacity(0.18), .clear]
                        : [Color.white.opacity(0.14), .clear],
                    center: .center,
                    startRadius: 10,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.72
                )

                // The faint 40 pt grid from the brand kit: something for glass to
                // refract, fading out toward the bottom so it never sits under text.
                if !reduceTransparency {
                    MacBackdropGrid(color: colorScheme == .dark ? .white : .black)
                        .opacity(colorScheme == .dark ? 0.035 : 0.045)
                }

                if reduceTransparency {
                    Color(nsColor: .windowBackgroundColor).opacity(0.32)
                }
            }
            .accessibilityHidden(true)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct MacGlassSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let isInteractive: Bool
    let role: MacGlassSurfaceRole

    @ViewBuilder
    func body(content: Content) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.background {
                GeometryReader { proxy in
                    Color.clear
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .glassEffect(nativeGlass, in: shape)
                        .allowsHitTesting(false)
                }
            }
        } else {
            content.background(role == .content ? .thinMaterial : .ultraThinMaterial, in: shape)
        }
#else
        content.background(role == .content ? .thinMaterial : .ultraThinMaterial, in: shape)
#endif
    }

#if compiler(>=6.2)
    @available(macOS 26.0, *)
    private var nativeGlass: Glass {
        // Chrome can stay highly transparent and let the backdrop art read
        // through; rows carrying text use Apple's denser neutral glass so they
        // keep a contrast floor over the busiest part of the artwork. Neither
        // variant applies a tint.
        let glass: Glass = role == .content ? .regular : .clear
        return glass.interactive(isInteractive)
    }
#endif
}

enum MacGlassSurfaceRole {
    /// Highly transparent — for surfaces that are mostly decoration.
    case chrome
    /// Denser neutral glass — for anything carrying text or controls.
    case content
}

extension View {
    /// Native, colorless Liquid Glass over the Vamp backdrop. The effect is
    /// rendered in a geometry-locked background so it never steals the first
    /// click from its controls.
    func macGlassSurface<S: InsettableShape>(
        in shape: S,
        isInteractive: Bool = false,
        contentLegibility: Bool = true
    ) -> some View {
        modifier(
            MacGlassSurfaceModifier(
                shape: shape,
                isInteractive: isInteractive,
                role: contentLegibility ? .content : .chrome
            )
        )
    }

    /// High-contrast session chrome that stays readable over bright remote video.
    func sessionControlSurface<S: InsettableShape>(in shape: S) -> some View {
        self
            .macGlassSurface(in: shape, isInteractive: true)
            .background {
                shape.fill(.black.opacity(0.42))
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.38), radius: 10, y: 4)
            .environment(\.colorScheme, .dark)
    }
}

/// A reusable native glass card shared by the hosts and connection screens.
struct BrandCard<Content: View>: View {
    var hovering: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .macGlassSurface(
                in: RoundedRectangle(cornerRadius: MacBrand.cardCornerRadius, style: .continuous),
                isInteractive: true
            )
            .brightness(hovering ? 0.025 : 0)
    }
}

// MARK: - Redesign system (shared with Vamp Sync and Vamp Control iOS)

extension MacBrand {
    /// The one accent: reserved for the single primary action on a screen.
    static let crimson = Color(red: 209 / 255, green: 46 / 255, blue: 87 / 255)
    /// Crimson for text and small glyphs: lighter in dark mode so it keeps contrast.
    static let crimsonText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1, green: 0.64, blue: 0.72, alpha: 1)
            : NSColor(red: 0.69, green: 0.12, blue: 0.27, alpha: 1)
    })
    /// Status colours live only in dots, never in text or fills.
    static let live = Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255)
    static let attention = Color(red: 251 / 255, green: 191 / 255, blue: 36 / 255)
    static let idle = Color.secondary.opacity(0.55)
    static let hairline = Color.primary.opacity(0.11)

    /// Monospaced metadata face: labels, addresses, codes, numbers.
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// The faint 40 pt grid behind every Vamp surface.
struct MacBackdropGrid: View {
    var color: Color
    var spacing: CGFloat = 40

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += spacing
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += spacing
            }
            context.stroke(path, with: .color(color), lineWidth: 1)
        }
        .mask(LinearGradient(colors: [.black, .black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Monospaced small-caps metadata ("LOCAL NETWORK · TAILSCALE").
struct MacMetaLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(MacBrand.mono(10.5))
            .tracking(0.9)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

enum MacStatusTone {
    case live, attention, idle

    var color: Color {
        switch self {
        case .live: return MacBrand.live
        case .attention: return MacBrand.attention
        case .idle: return MacBrand.idle
        }
    }
}

struct MacStatusDot: View {
    let tone: MacStatusTone
    var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: 7, height: 7)
            .background {
                if tone != .idle {
                    Circle().fill(tone.color.opacity(0.22)).frame(width: 13, height: 13)
                }
            }
            .frame(width: 13, height: 13)
            .accessibilityHidden(true)
    }
}

/// Mono caps capsule. Colour stays in the dot so the label reads in any theme.
struct MacStatusPill: View {
    let title: String
    var tone: MacStatusTone = .live
    var isWorking = false

    var body: some View {
        HStack(spacing: 6) {
            if isWorking {
                ProgressView().controlSize(.mini).scaleEffect(0.75).frame(width: 13, height: 13)
            } else {
                MacStatusDot(tone: tone)
            }
            Text(title.uppercased())
                .font(MacBrand.mono(10.5))
                .tracking(0.8)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(height: 24)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(MacBrand.hairline, lineWidth: 0.5))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// Compact capsule buttons. Never full width; one `.primary` per screen.
struct MacCapsuleButtonStyle: ButtonStyle {
    enum Kind { case primary, glass, quiet, inverse, end }
    var kind: Kind = .glass
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        MacCapsuleBody(label: configuration.label, kind: kind, large: large, isPressed: configuration.isPressed)
    }
}

private struct MacCapsuleBody<Label: View>: View {
    let label: Label
    let kind: MacCapsuleButtonStyle.Kind
    let large: Bool
    let isPressed: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        label
            .font(.system(size: large ? 13 : 12, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .padding(.horizontal, kind == .quiet ? 6 : (large ? 16 : 12))
            .frame(height: large ? 30 : 26)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .overlay(Capsule().strokeBorder(border, lineWidth: 0.5))
            .shadow(color: kind == .primary ? MacBrand.crimson.opacity(isEnabled ? 0.35 : 0) : .clear, radius: 8, y: 3)
            .opacity(isEnabled ? (isPressed ? 0.78 : 1) : 0.45)
            .contentShape(Capsule())
    }

    private var foreground: AnyShapeStyle {
        switch kind {
        case .primary: return AnyShapeStyle(Color.white)
        case .glass: return AnyShapeStyle(Color.primary)
        case .quiet: return AnyShapeStyle(Color.secondary)
        case .inverse: return AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
        case .end: return AnyShapeStyle(MacBrand.crimsonText)
        }
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .primary: return AnyShapeStyle(MacBrand.crimson)
        case .glass: return AnyShapeStyle(Color.primary.opacity(isPressed ? 0.14 : 0.08))
        case .quiet: return AnyShapeStyle(Color.clear)
        case .inverse: return AnyShapeStyle(Color.primary)
        case .end: return AnyShapeStyle(MacBrand.crimson.opacity(0.16))
        }
    }

    private var border: Color {
        switch kind {
        case .primary: return .white.opacity(0.2)
        case .glass: return MacBrand.hairline
        case .quiet, .inverse: return .clear
        case .end: return MacBrand.crimson.opacity(0.5)
        }
    }
}

extension View {
    /// A Vamp glass card: content glass plus a hairline rim.
    func macCard(radius: CGFloat = 18, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .macGlassSurface(in: shape, isInteractive: interactive)
            .overlay(shape.strokeBorder(MacBrand.hairline, lineWidth: 0.5).allowsHitTesting(false))
    }
}

/// The Vamp fang mark. Control's arc smiles; Sync's arc reaches out with an arrow.
struct MacVampMark: View {
    enum Arc { case control, sync }
    var arc: Arc = .control
    var ink: Color = .primary

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 48
            context.translateBy(x: (size.width - 48 * scale) / 2, y: (size.height - 48 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            var lip = Path()
            lip.move(to: CGPoint(x: 8, y: 15))
            lip.addCurve(to: CGPoint(x: 40, y: 15), control1: CGPoint(x: 12.5, y: 19), control2: CGPoint(x: 35.5, y: 19))
            context.stroke(lip, with: .color(ink), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
            var fangs = Path()
            fangs.move(to: CGPoint(x: 14.5, y: 18.3)); fangs.addLine(to: CGPoint(x: 17.7, y: 29.8))
            fangs.addLine(to: CGPoint(x: 21, y: 19.4)); fangs.closeSubpath()
            fangs.move(to: CGPoint(x: 27, y: 19.4)); fangs.addLine(to: CGPoint(x: 30.3, y: 29.8))
            fangs.addLine(to: CGPoint(x: 33.5, y: 18.3)); fangs.closeSubpath()
            context.fill(fangs, with: .color(ink))
            var smile = Path()
            switch arc {
            case .control:
                smile.move(to: CGPoint(x: 10, y: 30))
                smile.addCurve(to: CGPoint(x: 38, y: 30), control1: CGPoint(x: 13.5, y: 37), control2: CGPoint(x: 34.5, y: 37))
            case .sync:
                smile.move(to: CGPoint(x: 38, y: 31))
                smile.addCurve(to: CGPoint(x: 12.5, y: 35), control1: CGPoint(x: 34, y: 40.5), control2: CGPoint(x: 19, y: 42))
                smile.move(to: CGPoint(x: 12, y: 39.5)); smile.addLine(to: CGPoint(x: 12, y: 34.5))
                smile.addLine(to: CGPoint(x: 17, y: 34.5))
            }
            context.stroke(smile, with: .color(MacBrand.crimson),
                           style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// The dark glass tile that carries a Vamp mark, like a small app icon.
struct MacMarkTile: View {
    var size: CGFloat = 48
    var arc: MacVampMark.Arc = .sync
    /// SF Symbol for the crimson action badge (download, cursor, unlock), if any.
    var badge: String?

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.15, green: 0.15, blue: 0.18), Color(red: 0.07, green: 0.07, blue: 0.09)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            .overlay(MacVampMark(arc: arc, ink: Color(white: 0.95)).padding(size * 0.16))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Image(systemName: badge)
                        .font(.system(size: size * 0.21, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: size * 0.44, height: size * 0.44)
                        .background(MacBrand.crimson, in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5))
                        .offset(x: size * 0.12, y: size * 0.12)
                }
            }
            .accessibilityHidden(true)
    }
}

/// The last frame of each Mac's session in this run, for its card. Memory only: a Mac's
/// screen is never written to disk, so after a relaunch the cards show artwork again
/// until the next session.
@MainActor
final class MacHostThumbnails: ObservableObject {
    static let shared = MacHostThumbnails()
    @Published private(set) var images: [UUID: NSImage] = [:]
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    func record(_ frame: CVPixelBuffer, for hostID: UUID) {
        let image = CIImage(cvPixelBuffer: frame)
        let scale = min(1, 640 / max(image.extent.width, 1))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = Self.context.createCGImage(small, from: small.extent) else { return }
        images[hostID] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    #if SCREENSHOTS
    /// Screenshot builds only: each Mac shows a fictional desktop from `-VampSampleThumbnails`
    /// (comma-separated paths), so store images never carry a real screen.
    func seedSamples(for ids: [UUID]) {
        let paths = (UserDefaults.standard.string(forKey: "VampSampleThumbnails") ?? "").split(separator: ",")
        let samples = paths.compactMap { NSImage(contentsOfFile: String($0)) }
        guard !samples.isEmpty else { return }
        for (index, id) in ids.enumerated() where images[id] == nil { images[id] = samples[index % samples.count] }
    }
    #endif
}

/// A Mac display for a card: the last frame of this run's session with that Mac when
/// there is one (tagged so it never passes for live video), otherwise artwork.
struct MacScreenTile: View {
    enum State { case ready, asleep, offline }
    let seed: String
    let state: State
    var thumbnail: NSImage?

    private struct Palette { let base: Color; let bloomA: Color; let pointA: UnitPoint; let bloomB: Color; let pointB: UnitPoint }
    private static let palettes = [
        Palette(base: Color(red: 0.08, green: 0.08, blue: 0.11), bloomA: Color(red: 0.29, green: 0.20, blue: 0.40), pointA: .topLeading,
                bloomB: Color(red: 0.11, green: 0.29, blue: 0.31), pointB: .bottomTrailing),
        Palette(base: Color(red: 0.07, green: 0.07, blue: 0.09), bloomA: Color(red: 0.36, green: 0.13, blue: 0.21), pointA: .topTrailing,
                bloomB: Color(red: 0.16, green: 0.16, blue: 0.23), pointB: .bottomLeading),
        Palette(base: Color(red: 0.06, green: 0.07, blue: 0.09), bloomA: Color(red: 0.14, green: 0.20, blue: 0.31), pointA: .bottomLeading,
                bloomB: Color(red: 0.20, green: 0.13, blue: 0.27), pointB: .topTrailing),
    ]

    /// Stable across launches, unlike `hashValue`.
    private var palette: Palette {
        let hash = seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return Self.palettes[hash % Self.palettes.count]
    }

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            ZStack(alignment: .topLeading) {
                palette.base
                RadialGradient(colors: [palette.bloomA, .clear], center: palette.pointA, startRadius: 0, endRadius: w * 0.85)
                RadialGradient(colors: [palette.bloomB, .clear], center: palette.pointB, startRadius: 0, endRadius: w * 0.8)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: w, height: h)
                        .clipped()
                    if state != .ready {
                        Color.black.opacity(0.45)
                        stateIcon(width: w, height: h)
                    }
                    Text("LAST SESSION")
                        .font(MacBrand.mono(8.5, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(Color.white.opacity(0.88))
                        .padding(.horizontal, 7)
                        .frame(height: 17)
                        .background(Color.black.opacity(0.5), in: Capsule())
                        .padding(8)
                        .frame(width: w, height: h, alignment: .bottomLeading)
                } else if state == .ready {
                    Rectangle().fill(.black.opacity(0.32)).frame(height: h * 0.09)
                    window.frame(width: w * 0.54, height: h * 0.52).offset(x: w * 0.08, y: h * 0.22)
                    window.frame(width: w * 0.48, height: h * 0.42).offset(x: w * 0.42, y: h * 0.36)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                        .frame(width: w * 0.42, height: h * 0.08)
                        .offset(x: w * 0.29, y: h * 0.87)
                } else {
                    stateIcon(width: w, height: h)
                }
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .saturation(state == .offline ? 0.35 : 1)
        .brightness(state == .offline ? -0.08 : 0)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .accessibilityHidden(true)
    }

    private func stateIcon(width w: CGFloat, height h: CGFloat) -> some View {
        Image(systemName: state == .asleep ? "moon.zzz" : "wifi.slash")
            .font(.system(size: min(w, h) * 0.16, weight: .light))
            .foregroundStyle(Color.white.opacity(0.6))
            .frame(width: w, height: h)
    }

    private var window: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color(red: 0.11, green: 0.11, blue: 0.14).opacity(0.86))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 3) {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                    Circle().fill(Color(red: 1, green: 0.74, blue: 0.18))
                    Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25))
                }
                .frame(height: 4.5)
                .padding(5)
            }
            .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
    }
}

/// A key fingerprint in the same blocks of 8 that Vamp Sync shows, so the two
/// screens read identically when compared side by side.
struct MacFingerprintChunks: View {
    let fingerprint: String
    var large = false

    private var blocks: [String] {
        let characters = Array(fingerprint)
        return stride(from: 0, to: characters.count, by: 8).map {
            String(characters[$0..<min($0 + 8, characters.count)])
        }
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4), alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                Text(block)
                    .font(MacBrand.mono(large ? 13 : 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, large ? 7 : 4)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(MacBrand.hairline, lineWidth: 0.5))
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fingerprint")
        .accessibilityValue(fingerprint)
    }
}

/// The shared promo card: glass over a crimson bloom, a mark tile with an action
/// badge, a mono eyebrow, and a light capsule (never crimson — the screen's own
/// primary action keeps the accent).
struct MacSyncPromoCard: View {
    var wide = true
    /// Set once the person confirms Vamp Sync is on their Mac; the card then stays hidden.
    @AppStorage("control.promo.syncInstalled") private var syncInstalled = false
    @State private var confirming = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 20, style: .continuous) }

    var body: some View {
        if !syncInstalled { card }
    }

    private var card: some View {
        Group {
            if confirming {
                approval
            } else if wide {
                HStack(spacing: 18) {
                    head.frame(maxWidth: .infinity, alignment: .leading)
                    ViewThatFits(in: .horizontal) {
                        chips
                        EmptyView()
                    }
                    cta
                    dismiss
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    head.padding(.trailing, 26)
                    chips
                    cta
                }
                .overlay(alignment: .topTrailing) { dismiss }
            }
        }
        .animation(.snappy, value: confirming)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlassSurface(in: shape)
        .background {
            shape.fill(RadialGradient(colors: [MacBrand.crimson.opacity(0.30), .clear],
                                      center: .topLeading, startRadius: 0, endRadius: 420))
                .allowsHitTesting(false)
        }
        .overlay(shape.strokeBorder(MacBrand.hairline, lineWidth: 0.5).allowsHitTesting(false))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Get Vamp Sync")
    }

    private var head: some View {
        HStack(alignment: wide ? .center : .top, spacing: 14) {
            MacMarkTile(size: 46, arc: .sync, badge: "arrow.down")
            VStack(alignment: .leading, spacing: 4) {
                Text("VAMP SYNC · FREE")
                    .font(MacBrand.mono(9.5, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(MacBrand.crimsonText)
                Text("Put Vamp Sync on the Mac you want to reach")
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("The free website edition adds keyboard and pointer control. The Mac App Store edition is View Only.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var chips: some View {
        HStack(spacing: 5) {
            chip("Menu bar app", systemImage: "menubar.rectangle")
            chip("Approve each device", systemImage: "checkmark.shield")
        }
        .fixedSize()
    }

    private func chip(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(MacBrand.crimsonText)
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(MacBrand.crimson.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(MacBrand.crimson.opacity(0.5), lineWidth: 0.6))
    }

    private var cta: some View {
        Link(destination: VampProductLinks.syncEditions) {
            Label("Get Vamp Sync", systemImage: "arrow.up.right")
                .labelStyle(MacTrailingIconLabelStyle())
        }
        .buttonStyle(MacCapsuleButtonStyle(kind: .inverse))
        .help("https://thevamp.app/sync/#editions")
        .accessibilityHint("Opens the Vamp Sync website in your browser")
    }

    private var dismiss: some View {
        Button { confirming = true } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.08), in: Circle())
                .overlay(Circle().strokeBorder(MacBrand.hairline, lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
        .accessibilityHint("Asks whether Vamp Sync is already on your Mac")
    }

    /// Hiding the card is only right once the host is on the Mac, so dismissing asks first.
    private var approval: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(MacBrand.live)
                .frame(width: 46, height: 46)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MacBrand.hairline, lineWidth: 0.5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("VAMP SYNC")
                    .font(MacBrand.mono(9.5, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(MacBrand.crimsonText)
                Text("Is Vamp Sync installed on the Mac you want to reach?")
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Confirm and this card stays hidden.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Not Yet") { confirming = false }
                .buttonStyle(MacCapsuleButtonStyle(kind: .glass))
            Button { withAnimation(.snappy) { syncInstalled = true } } label: {
                Label("Yes, It’s Installed", systemImage: "checkmark")
                    .labelStyle(MacTrailingIconLabelStyle())
            }
            .buttonStyle(MacCapsuleButtonStyle(kind: .inverse))
        }
    }
}

/// Title first, then a small icon — for "Get Vamp Sync ↗" style links.
struct MacTrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.title
            configuration.icon.font(.system(size: 10, weight: .bold))
        }
    }
}

/// Switches for features that are not ready to be on by default.
enum MacExperiments {
    /// Vamp Assistant pairing, kept for a future app.
    static let assistantKey = "control.experimental.assistant"
}
