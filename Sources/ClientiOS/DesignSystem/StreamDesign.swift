import SwiftUI
import SharedModels

/// App Stream's visual language. Kept independent of the transport and host implementation.
/// Shared source lets the two app libraries use exactly the same components.
enum StreamDesign {
    static let ink = Color(hex: 0x101116)
    static let garnet = Color(hex: 0x662E38)
    static let coral = Color(hex: 0xFF8576)
    static let accent = Color.dynamic(light: 0xA63433, dark: 0xFF998B)
    static let text = Color.dynamic(light: 0x242127, dark: 0xF7F2ED)
    static let secondary = Color.dynamic(light: 0x6C6167, dark: 0xBBB0B4)
    static let line = Color.dynamic(light: 0x4C2935, dark: 0xFFFFFF, lightAlpha: 0.12, darkAlpha: 0.13)
    static let readingPlate = Color.dynamic(light: 0xFFFAF6, dark: 0x17151C, lightAlpha: 0.46, darkAlpha: 0.30)
    static let radius: CGFloat = 28
    static let inset: CGFloat = 24
    static let maxWidth: CGFloat = 760
    static let spring = Animation.spring(response: 0.32, dampingFraction: 1)
}

extension EnvironmentValues {
    /// Only Stream opts into this style; Control retains its own design system.
    @Entry var streamDesign = false
}

/// Two offset windows form a forward-moving ribbon. The open corners are the signature.
struct StreamSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 64
        let origin = CGPoint(x: rect.midX - 32 * scale, y: rect.midY - 32 * scale)
        var p = Path()
        p.move(to: CGPoint(x: 27, y: 8))
        p.addLine(to: CGPoint(x: 51, y: 8))
        p.addQuadCurve(to: CGPoint(x: 60, y: 17), control: CGPoint(x: 60, y: 8))
        p.addLine(to: CGPoint(x: 60, y: 35))
        p.addLine(to: CGPoint(x: 49, y: 43))
        p.addLine(to: CGPoint(x: 49, y: 21))
        p.addQuadCurve(to: CGPoint(x: 47, y: 19), control: CGPoint(x: 49, y: 19))
        p.addLine(to: CGPoint(x: 13, y: 19))
        p.closeSubpath()
        p.move(to: CGPoint(x: 37, y: 56))
        p.addLine(to: CGPoint(x: 13, y: 56))
        p.addQuadCurve(to: CGPoint(x: 4, y: 47), control: CGPoint(x: 4, y: 56))
        p.addLine(to: CGPoint(x: 4, y: 29))
        p.addLine(to: CGPoint(x: 15, y: 21))
        p.addLine(to: CGPoint(x: 15, y: 43))
        p.addQuadCurve(to: CGPoint(x: 17, y: 45), control: CGPoint(x: 15, y: 45))
        p.addLine(to: CGPoint(x: 51, y: 45))
        p.closeSubpath()
        return p.applying(CGAffineTransform(scaleX: scale, y: scale))
            .applying(CGAffineTransform(translationX: origin.x, y: origin.y))
    }
}

struct StreamBrandMark: View {
    static let preferenceKey = "vampstream.classicLogo"
    @AppStorage(Self.preferenceKey) private var usesClassic = false

    var body: some View {
        Group {
            if usesClassic {
                Image("StreamIconClassic").resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                StreamSymbol().fill(StreamDesign.accent)
            }
        }
        .accessibilityHidden(true)
    }
}

struct StreamWordmark: View {
    var body: some View {
        HStack(spacing: 10) {
            StreamBrandMark()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            Text(verbatim: VampProductIdentity.streamName)
                .font(.system(.headline, design: .default, weight: .semibold))
                .tracking(-0.6)
                .foregroundStyle(StreamDesign.text)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Still artwork uses no timers or per-frame effects. Glass refracts the broad ribbon beneath it.
struct StreamAtmosphere: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.prSolidSurfaces) private var solidSurfaces
    var decorative = true

    var body: some View {
        GeometryReader { proxy in
            let dark = scheme == .dark
            ZStack {
                (dark ? StreamDesign.ink : Color(hex: 0xF7F0EB))
                if decorative && !reduceTransparency && !solidSurfaces {
                    RadialGradient(
                        colors: [Color(hex: dark ? 0x63323F : 0xE9C1BA).opacity(0.8), .clear],
                        center: UnitPoint(x: 1.05, y: 0.55), startRadius: 5,
                        endRadius: max(proxy.size.height * 0.64, 1))
                    StreamRibbon()
                        .fill(LinearGradient(
                            colors: [Color(hex: dark ? 0x211D2B : 0xF8E4DA),
                                     Color(hex: dark ? 0x743744 : 0xE3ABA3),
                                     Color(hex: dark ? 0xBC6D68 : 0xD5908D)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay {
                            StreamRibbon().stroke(
                                LinearGradient(colors: [.clear, StreamDesign.coral.opacity(dark ? 0.44 : 0.2), .clear],
                                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                        }
                    LinearGradient(colors: [dark ? StreamDesign.ink.opacity(0.45) : .white.opacity(0.2), .clear,
                                            dark ? StreamDesign.ink.opacity(0.68) : Color(hex: 0xF7F0EB).opacity(0.6)],
                                   startPoint: .top, endPoint: .bottom)
                }
                (dark ? Color.black : Color.white)
                    .opacity(contrast == .increased ? 0.22 : 0)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct StreamRibbon: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        p.move(to: CGPoint(x: w * 1.22, y: h * 0.11))
        p.addCurve(to: CGPoint(x: -w * 0.12, y: h * 0.89),
                   control1: CGPoint(x: w * 0.12, y: h * 0.23), control2: CGPoint(x: w * 1.12, y: h * 0.66))
        p.addLine(to: CGPoint(x: -w * 0.12, y: h * 1.06))
        p.addCurve(to: CGPoint(x: w * 1.22, y: h * 0.30),
                   control1: CGPoint(x: w * 1.42, y: h * 0.77), control2: CGPoint(x: w * 0.39, y: h * 0.40))
        p.closeSubpath()
        return p
    }
}

struct StreamGlassSurface: ViewModifier {
    var radius: CGFloat = StreamDesign.radius
    var elevated = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.prSolidSurfaces) private var solid
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                if reduceTransparency || solid || contrast == .increased {
                    shape.fill(Color.dynamic(light: 0xFFFAF6, dark: 0x252129))
                } else {
                    #if os(iOS) && compiler(>=6.2)
                    if #available(iOS 26.0, *) {
                        Color.clear
                            .glassEffect(.clear, in: shape)
                            .background(StreamDesign.readingPlate, in: shape)
                    } else {
                        shape.fill(StreamDesign.readingPlate)
                            .background(.ultraThinMaterial, in: shape)
                    }
                    #else
                    shape.fill(StreamDesign.readingPlate)
                        .background(.ultraThinMaterial, in: shape)
                    #endif
                }
            }
            .overlay {
                shape.strokeBorder(LinearGradient(
                    colors: [Color.white.opacity(scheme == .dark ? 0.23 : 0.8), StreamDesign.line.opacity(0.5), StreamDesign.line],
                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(elevated ? 0.12 : 0.04), radius: elevated ? 28 : 14, y: elevated ? 14 : 6)
    }
}

extension View {
    func streamGlass(radius: CGFloat = StreamDesign.radius, elevated: Bool = false) -> some View {
        modifier(StreamGlassSurface(radius: radius, elevated: elevated))
    }
}

struct StreamPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(reduceMotion ? nil : StreamDesign.spring, value: configuration.isPressed)
    }
}

struct StreamPrimaryButton: View {
    let title: LocalizedStringKey
    var symbol = "arrow.up.right"
    var isDisabled = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(.black.opacity(0.06), in: Circle())
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color(hex: 0x262127))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(minHeight: 58)
            .background(LinearGradient(colors: [Color(hex: 0xFFF6EE), Color(hex: 0xEED7CE)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.7), lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(StreamPressStyle())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
    }
}

struct StreamIconButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(StreamDesign.text)
                .frame(width: 48, height: 48)
                .streamGlass(radius: 24)
                .contentShape(Circle())
        }
        .buttonStyle(StreamPressStyle())
        .accessibilityLabel(Text(label))
    }
}

struct StreamEyebrow: View {
    let title: LocalizedStringKey
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        if !typeSize.isAccessibilitySize {
            Text(title)
            .font(.system(.caption2, design: .monospaced, weight: .medium))
            .tracking(2)
            .foregroundStyle(StreamDesign.secondary)
            .accessibilityAddTraits(.isHeader)
        }
    }
}

/// A window passing from a Mac to a handheld canvas. Decorative, never a fake app inventory.
struct StreamWorkspaceIllustration: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .stroke(StreamDesign.line, lineWidth: 1)
                .frame(width: 250, height: 164)
                .rotationEffect(.degrees(-9))
                .offset(x: -8, y: -8)
            StreamIllustratedWindow()
                .frame(width: 250, height: 164)
                .rotationEffect(.degrees(-4))
                .offset(x: -8, y: 0)
            VStack(spacing: 10) {
                Capsule().fill(StreamDesign.line).frame(width: 21, height: 3)
                StreamSymbol()
                    .fill(LinearGradient(colors: [Color(hex: 0xFFB7A0), StreamDesign.coral],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                Capsule().fill(StreamDesign.line).frame(width: 22, height: 3)
            }
            .frame(width: 88, height: 137)
            .streamGlass(radius: 25, elevated: true)
            .rotationEffect(.degrees(9))
            .offset(x: 102, y: 34)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 196)
        .accessibilityHidden(true)
    }
}

private struct StreamIllustratedWindow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3) { _ in Circle().fill(StreamDesign.text.opacity(0.25)).frame(width: 5, height: 5) }
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(StreamDesign.secondary)
            .padding(14)
            Rectangle().fill(StreamDesign.line).frame(height: 0.5)
            HStack(spacing: 12) {
                VStack(spacing: 8) {
                    ForEach(0..<4) { i in
                        Capsule().fill(StreamDesign.text.opacity(i == 0 ? 0.3 : 0.1)).frame(width: i == 1 ? 23 : 35, height: 4)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 4)
                Rectangle().fill(StreamDesign.line).frame(width: 0.5)
                VStack(alignment: .leading, spacing: 10) {
                    StreamBrandMark().frame(width: 30, height: 30)
                    Capsule().fill(StreamDesign.text.opacity(0.25)).frame(width: 86, height: 6)
                    Capsule().fill(StreamDesign.text.opacity(0.1)).frame(width: 112, height: 4)
                    Capsule().fill(StreamDesign.text.opacity(0.1)).frame(width: 70, height: 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .streamGlass(radius: 20, elevated: true)
    }
}

struct StreamLibraryHeader: View {
    let macName: String
    let onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack {
                Button(action: onClose) {
                    Label("Macs", systemImage: "chevron.left")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(StreamDesign.text)
                        .frame(minHeight: 44)
                }
                .buttonStyle(StreamPressStyle())
                .accessibilityHint("Disconnect and return to your Macs")
                Spacer()
                StreamBrandMark().frame(width: 28, height: 28).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 9) {
                StreamEyebrow(title: "YOUR MAC, ON HAND")
                Text("App library")
                    .font(.system(.largeTitle, design: .default, weight: .medium))
                    .tracking(-1.5)
                    .foregroundStyle(StreamDesign.text)
                Label(macName, systemImage: "laptopcomputer")
                    .font(.subheadline)
                    .foregroundStyle(StreamDesign.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, StreamDesign.inset)
        .padding(.top, 8)
        .padding(.bottom, 22)
    }
}

enum StreamLibraryFilter: String, CaseIterable, Identifiable {
    case all, running, favorites
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self { case .all: "All apps"; case .running: "Running"; case .favorites: "Favorites" }
    }
}

struct StreamLibraryFilters: View {
    @Binding var selection: StreamLibraryFilter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        if typeSize.isAccessibilitySize {
            Menu {
                Picker("Show apps", selection: $selection) {
                    ForEach(StreamLibraryFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
            } label: {
                HStack {
                    Text(selection.title).font(.body.weight(.medium))
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.up.chevron.down").font(.body)
                }
                .foregroundStyle(StreamDesign.text)
                .padding(16)
                .frame(minHeight: 52)
                .streamGlass(radius: 24)
            }
            .accessibilityLabel("Show apps")
            .accessibilityValue(Text(selection.title))
        } else {
            HStack(spacing: 4) {
            ForEach(StreamLibraryFilter.allCases) { filter in
                Button { selection = filter } label: {
                    Text(filter.title)
                        .font(.subheadline.weight(selection == filter ? .semibold : .medium))
                        .foregroundStyle(selection == filter ? StreamDesign.text : StreamDesign.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(StreamDesign.text.opacity(selection == filter ? 0.10 : 0), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(StreamPressStyle())
                .accessibilityAddTraits(selection == filter ? .isSelected : [])
            }
        }
        .padding(4)
        .streamGlass(radius: 28)
        .animation(reduceMotion ? nil : StreamDesign.spring, value: selection)
        }
    }
}

struct StreamLibrarySectionHeading: View {
    let title: LocalizedStringKey
    let count: Int
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline.weight(.medium)).foregroundStyle(StreamDesign.text)
            Spacer()
            Text(count, format: .number).font(.caption.monospacedDigit()).foregroundStyle(StreamDesign.secondary)
        }
        .padding(.horizontal, 5)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct StreamLibraryEmptyState: View {
    let filter: StreamLibraryFilter
    let isSearching: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: isSearching ? "magnifyingglass" : (filter == .favorites ? "star" : "macwindow"))
                .font(.system(size: 30, weight: .ultraLight)).foregroundStyle(StreamDesign.accent)
            Text(isSearching ? "Nothing by that name." : (filter == .favorites ? "Keep your favorites close." : "A quiet workspace."))
                .font(.title3.weight(.medium)).foregroundStyle(StreamDesign.text)
            Text(isSearching ? "Try a different app name." : (filter == .favorites
                ? "In All apps, touch and hold an app, then choose Add to Favorites."
                : "Open an app on your Mac, then pull down to refresh."))
                .font(.subheadline).foregroundStyle(StreamDesign.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(26).streamGlass()
        .padding(.top, 18)
    }
}
