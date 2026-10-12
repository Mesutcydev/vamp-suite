import SwiftUI
#if os(macOS)
import AppKit

// MARK: - Menu Bar Template Icon

/// Returns a template NSImage for use in the macOS menu bar tray.
/// Draws a rounded square with a bold "m" letterform cut through it,
/// matching the app icon. Template images adapt automatically to
/// light/dark mode and menu-bar accent color.
func makeMenuBarTemplateIcon(size: CGFloat = 18) -> NSImage {
    let nsSize = NSSize(width: size, height: size)
    let image = NSImage(size: nsSize, flipped: false) { rect in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

        let radius = rect.width * 0.22
        let inset  = rect.insetBy(dx: 0.5, dy: 0.5)

        // 1. Fill the rounded square background (black = opaque in template).
        let bgPath = CGPath(
            roundedRect: inset,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.addPath(bgPath)
        ctx.fillPath()

        // 2. Punch out the letter "m" using destination-out blending so those
        //    pixels become transparent — the system renders the gap as the
        //    background (invisible in the tray), giving the appearance of the
        //    app icon design (black bg, white/clear letter).
        let fontSize = size * 0.52
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font as Any,
            .foregroundColor: NSColor.black
        ]
        let str = NSAttributedString(string: "m", attributes: attrs)
        let strSize = str.size()
        let strOrigin = CGPoint(
            x: (rect.width  - strSize.width)  / 2,
            y: (rect.height - strSize.height) / 2 + 0.5
        )
        ctx.saveGState()
        ctx.setBlendMode(.destinationOut)
        str.draw(at: strOrigin)
        ctx.restoreGState()

        return true
    }
    image.isTemplate = true
    return image
}

/// A small terminal-shaped template mark for Vamp Terminal Host's menu-bar item.
///
/// Menu-bar images must remain legible at 16–18 points and adapt to both menu-bar
/// appearances. The rounded terminal tile is the silhouette; the prompt, cursor
/// line, and two tiny fang notches are cut out so macOS can tint the mark as a
/// single template image without baking in a light or dark color.
func makeVampTerminalHostMenuBarTemplateIcon(size: CGFloat = 18) -> NSImage {
    let nsSize = NSSize(width: size, height: size)
    let image = NSImage(size: nsSize, flipped: false) { rect in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

        let radius = rect.width * 0.24
        let inset = rect.insetBy(dx: 0.5, dy: 0.5)
        let tile = CGPath(
            roundedRect: inset,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )

        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.addPath(tile)
        ctx.fillPath()

        // Transparent terminal glyph: the menu bar supplies the foreground
        // color, which keeps the mark crisp in light and dark appearances.
        ctx.setBlendMode(.destinationOut)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(max(1.35, size * 0.095))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        ctx.beginPath()
        ctx.move(to: CGPoint(x: rect.minX + size * 0.31, y: rect.midY + size * 0.10))
        ctx.addLine(to: CGPoint(x: rect.minX + size * 0.45, y: rect.midY))
        ctx.addLine(to: CGPoint(x: rect.minX + size * 0.31, y: rect.midY - size * 0.10))
        ctx.strokePath()

        ctx.beginPath()
        ctx.move(to: CGPoint(x: rect.minX + size * 0.53, y: rect.midY - size * 0.105))
        ctx.addLine(to: CGPoint(x: rect.minX + size * 0.69, y: rect.midY - size * 0.105))
        ctx.strokePath()

        // Subtle fang cut-outs under the cursor line. They remain distinct at
        // menu-bar scale without making the terminal glyph noisy.
        for centerX in [CGFloat(0.56), CGFloat(0.65)] {
            ctx.beginPath()
            ctx.move(to: CGPoint(x: rect.minX + size * (centerX - 0.025), y: rect.midY - size * 0.16))
            ctx.addLine(to: CGPoint(x: rect.minX + size * centerX, y: rect.midY - size * 0.24))
            ctx.addLine(to: CGPoint(x: rect.minX + size * (centerX + 0.025), y: rect.midY - size * 0.16))
            ctx.closePath()
            ctx.fillPath()
        }

        ctx.restoreGState()
        return true
    }
    image.isTemplate = true
    return image
}

#endif

// MARK: - App Logo View

/// Colored rounded-square logo used in the sidebar header and other surfaces.
/// Replicates the app-icon design: black background with a white bold "m".
struct HostAppLogo: View {
    var size: CGFloat = 28
    var cornerRadius: CGFloat = 8

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black)

            Text("m")
                .font(.system(size: size * 0.55, weight: .bold, design: .default))
                .foregroundStyle(Color.white)
                .offset(y: size * 0.01)
        }
        .frame(width: size, height: size)
    }
}

/// The focused product mark used by Vamp Terminal Host surfaces.
/// It keeps the terminal prompt readable in compact windows while the small
/// fang detail gives the product its own identity without relying on text.
struct VampTerminalHostMark: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                        .stroke(Color.primary.opacity(0.16), lineWidth: max(0.6, size * 0.018))
                }

            Image(systemName: "terminal.fill")
                .font(.system(size: size * 0.43, weight: .semibold))
                .foregroundStyle(.primary)

            HStack(spacing: size * 0.055) {
                fang
                fang
            }
            .offset(x: size * 0.07, y: size * 0.19)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Vamp Terminal Host")
    }

    private var fang: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: size * 0.035, y: size * 0.07))
            path.addLine(to: CGPoint(x: size * 0.07, y: 0))
            path.closeSubpath()
        }
        .fill(Color.primary)
        .frame(width: size * 0.07, height: size * 0.07)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    HStack(spacing: 16) {
        HostAppLogo(size: 20, cornerRadius: 5)
        HostAppLogo(size: 28, cornerRadius: 8)
        HostAppLogo(size: 44, cornerRadius: 12)
        HostAppLogo(size: 64, cornerRadius: 16)
    }
    .padding()
}
#endif
