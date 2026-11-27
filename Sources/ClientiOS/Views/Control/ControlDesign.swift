import SwiftUI
import SharedModels

/// Vamp Control's visual identity: ink, native clear glass, and one crimson accent.
enum ControlDesign {
    static let canvas = Color.dynamic(light: 0xF5F5F5, dark: 0x0F1013)
    static let ink = Color.dynamic(light: 0x181818, dark: 0xF3F3F3)
    static let secondary = Color.dynamic(light: 0x686868, dark: 0xAAAAAA)
    static let accent = Color.dynamic(light: 0x181818, dark: 0xF3F3F3)
    /// The suite's one brand accent, shared with Vamp Sync and Control for Mac: only the
    /// single primary action on a screen (Connect, Open, Unlock). White text passes 4.5:1 on both.
    static let primary = Color.dynamic(light: 0xC42A50, dark: 0xD12E57)
    static let primaryInk = Color.white
    /// Ending something: a soft crimson capsule, never the solid primary.
    static let endInk = Color.dynamic(light: 0xA3223F, dark: 0xFFA3B8)
    static let endFill = Color.dynamic(light: 0xC42A50, dark: 0xD12E57, lightAlpha: 0.10, darkAlpha: 0.18)
    /// Status is the one place color appears; everything else stays monochrome.
    static let available = Color.dynamic(light: 0x1F9D55, dark: 0x3DD07A)
    static let caution = Color.dynamic(light: 0xB86E00, dark: 0xF2A93B)
    /// The shell prompt: `$`, `+`. Terminal green, the one color outside status.
    static let prompt = available
    static let buttonInk = Color.dynamic(light: 0xFFFFFF, dark: 0x181818)
    static let line = Color.dynamic(light: 0x181818, dark: 0xF3F3F3, lightAlpha: 0.12, darkAlpha: 0.12)
    static let plate = Color.dynamic(light: 0xFFFFFF, dark: 0x242424)
    // One 4-pt grid for every Control screen; nothing below picks its own number.
    /// Related things: a label and its card, sibling cards, a dot and its text.
    static let gap: CGFloat = 8
    /// An icon and its text; lines stacked inside a card.
    static let stack: CGFloat = 12
    /// Card edge to text. Labels outside cards start here too, so all text shares one column.
    static let inset: CGFloat = 16
    /// Screen edge to card.
    static let gutter: CGFloat = 20
    /// Between sections.
    static let section: CGFloat = 24
    /// Every card, and the controls nested inside one.
    static let radius: CGFloat = 20
    static let innerRadius: CGFloat = 12
    /// Key/value lines and single-line rows; two-line tappable rows.
    static let lineHeight: CGFloat = 48
    static let rowHeight: CGFloat = 64
    static let buttonHeight: CGFloat = 40
    static let smallButtonHeight: CGFloat = 32
    /// Glass icon tiles and round icon buttons.
    static let tile: CGFloat = 40
    static let maxWidth: CGFloat = 720
    /// Two-pane home from here up: the unfolded iPhone Duo panel is 951 pt wide.
    static let wideMinWidth: CGFloat = 700
    static let wideMaxWidth: CGFloat = 1080

    static func companionMessage(_ message: String) -> String {
        message.replacingOccurrences(of: "Vamp Assistant", with: "Vamp Companion")
            .replacingOccurrences(of: "Vamp Stream", with: "Vamp Control")
            .replacingOccurrences(of: "port 9575", with: "the port shown on your Mac")
    }
}

/// Switches for features that are not ready to be on by default.
enum ControlExperiments {
    /// Vamp Companion pairing, kept for a future app. Saved Companion Macs keep working either way.
    static let companionKey = "control.experimental.companion"
}

enum ControlAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    static let storageKey = "control.appearance"
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Connected windows: one identity across the toolbar, splash, and app icon.
struct ControlSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 64
        return Path(ControlMarkGeometry.silhouette())
            .applying(CGAffineTransform(scaleX: scale, y: scale))
            .applying(CGAffineTransform(translationX: rect.midX - 32 * scale,
                                       y: rect.midY - 32 * scale))
    }
}

struct ControlWordmark: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            ControlSymbol().fill(ControlDesign.accent)
                .frame(width: 18, height: 18)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            Text("vamp").font(.system(size: 19, weight: .bold)).tracking(-0.7)
            Text("CONTROL").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.6)
                .foregroundStyle(ControlDesign.secondary)
        }
        .foregroundStyle(ControlDesign.ink)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Vamp Control")
    }
}

/// The brand mark on a clear glass tile, the way the app icon reads.
struct ControlGlassLogo: View {
    var size: CGFloat = ControlDesign.tile
    var body: some View {
        ControlSymbol().fill(ControlDesign.accent)
            .frame(width: size * 0.44, height: size * 0.44)
            .frame(width: size, height: size)
            .controlGlass(radius: size * 0.3, interactive: false, emphasis: .control)
            .accessibilityHidden(true)
    }
}

/// Small monospaced caps: section labels, source tags, and status meta.
struct ControlMono: View {
    let text: LocalizedStringKey
    var size: CGFloat = 10
    var color = ControlDesign.secondary
    var body: some View {
        Text(text).font(.system(size: size, weight: .semibold, design: .monospaced))
            .textCase(.uppercase).tracking(1.1).foregroundStyle(color)
    }
}

/// Ambient canvas behind clear glass: two colorless light blooms that drift slowly and a faint grid.
struct ControlBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false
    var body: some View {
        ZStack {
            ControlDesign.canvas
            Circle().fill(ControlDesign.ink.opacity(scheme == .dark ? 0.14 : 0.08))
                .frame(width: 480, height: 480).blur(radius: 110)
                .offset(x: drift ? -90 : -160, y: drift ? -220 : -280)
            Circle().fill(ControlDesign.ink.opacity(scheme == .dark ? 0.10 : 0.055))
                .frame(width: 420, height: 420).blur(radius: 120)
                .offset(x: drift ? 120 : 190, y: drift ? 340 : 280)
            Canvas { context, size in
                var path = Path()
                for x in stride(from: 0, through: size.width, by: 40) {
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: 0, through: size.height, by: 40) {
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(path, with: .color(ControlDesign.ink.opacity(scheme == .dark ? 0.06 : 0.045)), lineWidth: 0.5)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}

enum ControlGlassEmphasis {
    /// Broad surfaces stay transparent so the backdrop reads through.
    case surface
    /// Compact controls keep a visible optical rim.
    case control
    var opacity: Double {
        switch self {
        case .surface: 0.55
        case .control: 0.8
        }
    }
}

private struct ControlGlass: ViewModifier {
    var radius: CGFloat
    var interactive: Bool
    var emphasis: ControlGlassEmphasis
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                // Light mode has little to refract; a faint lift keeps surfaces off the page.
                if scheme == .light && emphasis == .surface {
                    shape.fill(Color.white.opacity(0.3))
                        .shadow(color: .black.opacity(0.07), radius: 18, y: 10)
                }
            }
            .background {
                if reduceTransparency {
                    shape.fill(ControlDesign.plate)
                } else if #available(iOS 26, *) {
                    // Geometry-locked so glass never changes the content's measured size.
                    GeometryReader { proxy in
                        Color.clear.frame(width: proxy.size.width, height: proxy.size.height)
                            .glassEffect(interactive ? .clear.interactive() : .clear, in: .rect(cornerRadius: radius))
                            .opacity(emphasis.opacity)
                    }
                } else {
                    shape.fill(.ultraThinMaterial)
                }
            }
            .overlay { shape.strokeBorder(ControlDesign.line, lineWidth: 0.6) }
    }
}

extension View {
    func controlGlass(radius: CGFloat = ControlDesign.radius, interactive: Bool = false,
                      emphasis: ControlGlassEmphasis = .surface) -> some View {
        modifier(ControlGlass(radius: radius, interactive: interactive, emphasis: emphasis))
    }
}

struct ControlPrimaryButton: View {
    let title: LocalizedStringKey
    var symbol = "arrow.right"
    var isDisabled = false
    var fillsWidth = false
    let action: () -> Void

    var body: some View {
        // ponytail: a plain capsule; .borderedProminent + .large draws a giant pill on iOS 26.
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title)
                Image(systemName: symbol).font(.footnote.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(ControlDesign.primaryInk)
            .padding(.horizontal, ControlDesign.inset)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: ControlDesign.buttonHeight)
            .background(ControlDesign.primary.opacity(isDisabled ? 0.4 : 1), in: Capsule())
            .shadow(color: ControlDesign.primary.opacity(isDisabled ? 0 : 0.35), radius: 10, y: 5)
            .contentShape(Capsule())
        }
        .buttonStyle(ControlPressStyle())
        .disabled(isDisabled)
    }
}

/// A compact capsule label: glass for secondary actions, soft crimson for ending one.
/// Rows and cards draw it inside their own buttons, so it carries no action itself.
struct ControlCapsule: View {
    enum Style { case glass, end }
    let title: LocalizedStringKey
    var symbol: String?
    var style: Style = .glass
    var height: CGFloat = ControlDesign.smallButtonHeight
    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            if let symbol { Image(systemName: symbol).font(.caption.weight(.bold)) }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(style == .end ? ControlDesign.endInk : ControlDesign.ink)
        .padding(.horizontal, ControlDesign.stack + 2)
        .frame(minHeight: height)
        .background {
            if style == .end {
                Capsule().fill(ControlDesign.endFill)
                    .overlay { Capsule().strokeBorder(ControlDesign.primary.opacity(0.45), lineWidth: 0.6) }
            }
        }
        .modifier(GlassIfNeeded(isGlass: style == .glass, height: height))
        .fixedSize()
    }

    private struct GlassIfNeeded: ViewModifier {
        let isGlass: Bool
        let height: CGFloat
        func body(content: Content) -> some View {
            if isGlass { content.controlGlass(radius: height / 2, interactive: true, emphasis: .control) } else { content }
        }
    }
}

/// "Vamp Control" set in the suite's serif, the way the Mac apps title their windows.
struct ControlSerifWordmark: View {
    var size: CGFloat = 23
    var body: some View {
        Text(verbatim: "Vamp Control")
            .font(.system(size: size, weight: .regular, design: .serif))
            .tracking(0.3)
            .foregroundStyle(ControlDesign.ink)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("Vamp Control")
            .accessibilityAddTraits(.isHeader)
    }
}

/// The suite's shared promo card: glass over a soft crimson bloom, a mark tile with a badge,
/// a mono eyebrow, the benefit and its honest catch, and a light capsule that never competes
/// with the screen's primary action. Opens the browser only.
struct ControlPromoCard: View {
    var title: LocalizedStringKey = "Reach another Mac"
    var detail: LocalizedStringKey = "Put Vamp Sync on it, approve this device once, and it shows up here."
    /// Set once the person confirms Vamp Sync is on their Mac. Every promo card then stays hidden;
    /// Settings > On Your Mac keeps the Get Vamp Sync link.
    @AppStorage("control.promo.syncInstalled") private var syncInstalled = false
    @State private var confirming = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if !syncInstalled {
            Group { if confirming { approval } else { promo } }
                .padding(ControlDesign.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RadialGradient(colors: [ControlDesign.primary.opacity(scheme == .dark ? 0.32 : 0.16), .clear],
                                   center: .topLeading, startRadius: 0, endRadius: 300)
                        .clipShape(RoundedRectangle(cornerRadius: ControlDesign.radius + 4, style: .continuous))
                }
                .controlGlass(radius: ControlDesign.radius + 4)
                .animation(.snappy, value: confirming)
        }
    }

    private var promo: some View {
        VStack(alignment: .leading, spacing: ControlDesign.stack) {
            HStack(alignment: .top, spacing: ControlDesign.stack + 2) {
                ZStack(alignment: .bottomTrailing) {
                    ControlSymbol().fill(Color.white)
                        .frame(width: 22, height: 22)
                        .frame(width: 48, height: 48)
                        .background(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.07)], startPoint: .top, endPoint: .bottom),
                                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 0.8) }
                    Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 21, height: 21)
                        .background(ControlDesign.primary, in: Circle())
                        .overlay { Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5) }
                        .offset(x: 6, y: 6)
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    eyebrow("VAMP SYNC · FREE")
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.footnote).foregroundStyle(ControlDesign.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button { confirming = true } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ControlDesign.secondary)
                        .frame(width: 28, height: 28)
                        .controlGlass(radius: 14, emphasis: .control)
                        .contentShape(Rectangle().inset(by: -8))
                }
                .buttonStyle(ControlPressStyle())
                .accessibilityLabel("Dismiss")
                .accessibilityHint("Asks whether Vamp Sync is already on your Mac")
            }
            HStack(spacing: ControlDesign.stack) {
                Link(destination: VampProductLinks.syncDownload) { lightCapsule("Get Vamp Sync", symbol: "arrow.up.right") }
                    .buttonStyle(ControlPressStyle())
                Spacer(minLength: 0)
                Link("Compare editions", destination: VampProductLinks.syncEditions)
                    .font(.footnote).foregroundStyle(ControlDesign.secondary)
            }
        }
    }

    /// Hiding the card is only right once the host is on the Mac, so dismissing asks first.
    private var approval: some View {
        VStack(alignment: .leading, spacing: ControlDesign.stack) {
            HStack(alignment: .top, spacing: ControlDesign.stack + 2) {
                Image(systemName: "checkmark")
                    .font(.system(size: 19, weight: .bold)).foregroundStyle(ControlDesign.available)
                    .frame(width: 48, height: 48)
                    .controlGlass(radius: 13, emphasis: .control)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    eyebrow("VAMP SYNC")
                    Text("Is Vamp Sync installed on your Mac?").font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Confirm and this card stays hidden. Get Vamp Sync stays in Settings.")
                        .font(.footnote).foregroundStyle(ControlDesign.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: ControlDesign.stack) {
                Button { withAnimation(.snappy) { syncInstalled = true } } label: {
                    lightCapsule("Yes, it’s installed", symbol: "checkmark")
                }
                .buttonStyle(ControlPressStyle())
                .accessibilityIdentifier("control.promo.installed")
                Button("Not yet") { confirming = false }
                    .font(.footnote.weight(.semibold)).foregroundStyle(ControlDesign.secondary)
                    .frame(minHeight: ControlDesign.smallButtonHeight)
                Spacer(minLength: 0)
            }
        }
    }

    private func eyebrow(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.1)
            .foregroundStyle(ControlDesign.endInk)
    }

    private func lightCapsule(_ title: LocalizedStringKey, symbol: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
            Image(systemName: symbol).font(.caption.weight(.bold)).accessibilityHidden(true)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Color(white: 0.07))
        .padding(.horizontal, ControlDesign.stack + 2)
        .frame(minHeight: ControlDesign.smallButtonHeight)
        .background(Color(white: scheme == .dark ? 0.95 : 1), in: Capsule())
        .overlay { Capsule().strokeBorder(ControlDesign.line, lineWidth: scheme == .dark ? 0 : 0.6) }
    }
}

/// Reports where an open foldable's crease crosses this view, in the view's own points.
/// nil when the device has no hinge, the hinge is closed (the cover panel shows the UI),
/// or the OS is older than iOS 27.1. The iPhone Duo's crease runs down the middle of
/// its inner panel, so it is the window's horizontal midpoint.
struct ControlHingeReader: UIViewRepresentable {
    @Binding var hingeX: CGFloat?

    func makeUIView(context: Context) -> HingeView {
        let view = HingeView()
        view.onChange = { value in if hingeX != value { hingeX = value } }
        return view
    }

    func updateUIView(_ view: HingeView, context: Context) {
        view.onChange = { value in if hingeX != value { hingeX = value } }
    }

    final class HingeView: UIView {
        var onChange: ((CGFloat?) -> Void)?
        private var isOpen = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            if #available(iOS 27.1, *) {
                addInteraction(UIHingeInteraction { [weak self] _, update in
                    guard let self else { return }
                    let status = update.hinge?.status
                    self.isOpen = status == .fullyOpen || status == .partiallyOpen
                    self.report()
                })
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        private func report() {
            var value: CGFloat?
            if isOpen, let window {
                value = (convert(CGPoint(x: window.bounds.midX, y: 0), from: window).x).rounded()
            }
            DispatchQueue.main.async { [weak self] in self?.onChange?(value) }
        }
    }
}

/// A section heading in the suite's meta style: small monospaced caps on the shared text column.
/// `command` is kept for call sites written in the earlier terminal voice; only `label` shows.
struct ControlPrompt: View {
    let command: String
    let label: LocalizedStringKey
    var body: some View {
        ControlMono(text: label, size: 11)
            // Same text column as the lines inside the glass panels below it.
            .padding(.leading, ControlDesign.inset)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Lines inside a glass block light up under the finger instead of shrinking.
struct ControlRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(ControlDesign.ink.opacity(configuration.isPressed ? 0.06 : 0))
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Tiles shrink slightly under the finger instead of flashing.
struct ControlPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// A status dot that breathes while something is live.
struct ControlPulseDot: View {
    var color: Color
    var isLive = true
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .background {
                if isLive && !reduceMotion {
                    Circle().fill(color.opacity(0.4))
                        .scaleEffect(on ? 2.6 : 1).opacity(on ? 0 : 0.9)
                }
            }
            .onAppear {
                guard isLive, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { on = true }
            }
            .accessibilityHidden(true)
    }
}

/// Round glass control for the floating top bar.
struct ControlGlassIconButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ControlDesign.ink)
                .frame(width: ControlDesign.tile, height: ControlDesign.tile)
                .contentShape(Circle())
                .controlGlass(radius: ControlDesign.tile / 2, interactive: true, emphasis: .control)
        }
        .buttonStyle(ControlPressStyle())
        .accessibilityLabel(Text(label))
    }
}

/// Sections fade and rise in once, staggered. Reduce Motion skips the travel.
struct ControlAppear: ViewModifier {
    let shown: Bool
    var delay: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .animation(.smooth(duration: 0.6).delay(delay), value: shown)
    }
}

extension View {
    func controlAppear(_ shown: Bool, delay: Double = 0) -> some View {
        modifier(ControlAppear(shown: shown, delay: delay))
    }
}
