import Foundation

#if canImport(UIKit) && !os(macOS)
import UIKit

enum AppHaptics {
    enum ImpactStyle {
        case light
        case medium
        case heavy
        case soft
        case rigid
    }

    static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

    static func warning() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
    }

    static func error() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.error)
    }

    static func impact(_ style: ImpactStyle = .light) {
        let generator = UIImpactFeedbackGenerator(style: uiKitStyle(for: style))
        generator.prepare()
        generator.impactOccurred()
    }

    private static func uiKitStyle(for style: ImpactStyle) -> UIImpactFeedbackGenerator.FeedbackStyle {
        switch style {
        case .light: return .light
        case .medium: return .medium
        case .heavy: return .heavy
        case .soft: return .soft
        case .rigid: return .rigid
        }
    }
}
#else
enum AppHaptics {
    enum ImpactStyle {
        case light
        case medium
        case heavy
        case soft
        case rigid
    }

    static func selection() {}
    static func success() {}
    static func warning() {}
    static func error() {}
    static func impact(_ style: ImpactStyle = .light) {}
}
#endif