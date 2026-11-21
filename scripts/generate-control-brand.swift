// Build with the same geometry as the app, then run from the repository root:
// swiftc Sources/ClientiOS/Views/Control/ControlMarkGeometry.swift \
//   scripts/generate-control-brand.swift -o /tmp/generate-control-brand
// /tmp/generate-control-brand
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
enum GenerateControlBrand {
    static let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    static let assets = root.appendingPathComponent("BrandKit/Control/assets")
    static let catalog = root.appendingPathComponent("Sources/ClientiOS/Assets.xcassets/ControlIcon.appiconset")

    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [
            CGFloat((hex >> 16) & 255) / 255,
            CGFloat((hex >> 8) & 255) / 255,
            CGFloat(hex & 255) / 255, alpha
        ])!
    }

    static func icon(background: UInt32, foreground: UInt32, name: String, kitName: String) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        // Explicit RGB drawing avoids AppKit's implicit graphics context, which
        // caused the previous otherwise-valid PNG files to contain black pixels.
        let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                                bytesPerRow: 4096, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.translateBy(x: 0, y: 1024)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(color(background))
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))

        context.saveGState()
        context.translateBy(x: 185.6, y: 175.4)
        context.scaleBy(x: 10.2, y: 10.2)
        context.addPath(ControlMarkGeometry.silhouette())
        context.setFillColor(color(foreground))
        context.fillPath()
        context.restoreGState()

        let image = context.makeImage()!
        // Fail before writing if a future renderer regresses to a blank image.
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var minimum: UInt8 = 255
        var maximum: UInt8 = 0
        var markPixels = 0
        let foregroundByte = UInt8(foreground & 255)
        for pixel in stride(from: 0, to: 1024 * 1024 * 4, by: 4) {
            let red = pixels[pixel]
            minimum = min(minimum, red)
            maximum = max(maximum, red)
            precondition(red == pixels[pixel + 1] && red == pixels[pixel + 2],
                         "Monochrome icon contains a color cast")
            if red == foregroundByte { markPixels += 1 }
        }
        precondition(minimum >= 20 && maximum >= 240 && Int(maximum) - Int(minimum) > 200,
                     "Icon is blank, has unpainted pixels, or has lost contrast")
        precondition(markPixels > 100_000 && markPixels < 400_000, "Window silhouette is missing or malformed")
        let destination = CGImageDestinationCreateWithURL(catalog.appendingPathComponent(name) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination), "PNG export failed")
        let data = try Data(contentsOf: catalog.appendingPathComponent(name))
        try data.write(to: assets.appendingPathComponent(kitName))
        print("Wrote \(name): \(data.count) bytes, RGB range \(minimum)...\(maximum)")
    }

    static func svgPath(_ path: CGPath) -> String {
        var commands: [String] = []
        func point(_ p: CGPoint) -> String { String(format: "%.3f %.3f", p.x, p.y) }
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint: commands.append("M" + point(e.points[0]))
            case .addLineToPoint: commands.append("L" + point(e.points[0]))
            case .addQuadCurveToPoint: commands.append("Q" + point(e.points[0]) + " " + point(e.points[1]))
            case .addCurveToPoint: commands.append("C" + point(e.points[0]) + " " + point(e.points[1]) + " " + point(e.points[2]))
            case .closeSubpath: commands.append("Z")
            @unknown default: break
            }
        }
        return commands.joined(separator: " ")
    }

    static func main() throws {
        try icon(background: 0xF4F4F4, foreground: 0x181818, name: "ControlIcon.png", kitName: "app-icon-light-1024.png")
        try icon(background: 0x181818, foreground: 0xF4F4F4, name: "ControlIcon-dark.png", kitName: "app-icon-dark-1024.png")
        try icon(background: 0x181818, foreground: 0xF4F4F4, name: "ControlIcon-tinted.png", kitName: "app-icon-tinted-1024.png")
        let path = svgPath(ControlMarkGeometry.silhouette())
        for (name, fill) in [("chalk", "#F3F3F3"), ("ink", "#181818")] {
            try "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 64 64\"><path fill=\"\(fill)\" d=\"\(path)\"/></svg>\n"
                .write(to: assets.appendingPathComponent("control-symbol-\(name).svg"), atomically: true, encoding: .utf8)
        }
        try "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 380 72\"><path transform=\"translate(0 4)\" fill=\"#181818\" d=\"\(path)\"/><text x=\"82\" y=\"47\" fill=\"#181818\" font-family=\"-apple-system,BlinkMacSystemFont,Helvetica Neue,sans-serif\" font-weight=\"700\" font-size=\"43\" letter-spacing=\"-2\">vamp</text><text x=\"207\" y=\"44\" fill=\"#686868\" font-family=\"-apple-system,BlinkMacSystemFont,Helvetica Neue,sans-serif\" font-weight=\"600\" font-size=\"15\" letter-spacing=\"3\">CONTROL</text></svg>\n"
            .write(to: assets.appendingPathComponent("control-lockup.svg"), atomically: true, encoding: .utf8)
        try "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\"><rect width=\"1024\" height=\"1024\" fill=\"#F4F4F4\"/><path transform=\"translate(185.6 175.4) scale(10.2)\" fill=\"#181818\" d=\"\(path)\"/></svg>\n"
            .write(to: assets.appendingPathComponent("control-icon.svg"), atomically: true, encoding: .utf8)
    }
}
