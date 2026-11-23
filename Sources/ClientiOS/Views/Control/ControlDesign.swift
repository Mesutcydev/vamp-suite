import SwiftUI

/// Vamp Control's visual identity: black, white, and native clear glass.
enum ControlDesign {
    static let canvas = Color.dynamic(light: 0xF5F5F5, dark: 0x141414)
    static let ink = Color.dynamic(light: 0x181818, dark: 0xF3F3F3)
    static let secondary = Color.dynamic(light: 0x686868, dark: 0xAAAAAA)
    static let accent = Color.dynamic(light: 0x181818, dark: 0xF3F3F3)
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
    var opacity: Double { self == .surface ? 0.55 : 0.8 }
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
            .foregroundStyle(ControlDesign.buttonInk)
            .padding(.horizontal, ControlDesign.inset)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: ControlDesign.buttonHeight)
            .background(ControlDesign.accent.opacity(isDisabled ? 0.4 : 1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(ControlPressStyle())
        .disabled(isDisabled)
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

/// A shell prompt heading: `$ ls macs`. VoiceOver reads the plain label.
struct ControlPrompt: View {
    let command: String
    let label: LocalizedStringKey
    var body: some View {
        Text("\(Text(verbatim: "$").foregroundStyle(ControlDesign.prompt)) \(Text(verbatim: command))")
            .font(.body.weight(.semibold)).foregroundStyle(ControlDesign.ink)
            // Same text column as the lines inside the glass panels below it.
            .padding(.leading, ControlDesign.inset)
            .accessibilityLabel(Text(label))
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
