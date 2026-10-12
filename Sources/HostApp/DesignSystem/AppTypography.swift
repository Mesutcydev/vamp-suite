import SwiftUI

/// Native typography — system font (SF), no rounded/heavy brand styling.
enum AppTypography {
    static let hero = Font.system(size: 26, weight: .semibold)
    static let sectionTitle = Font.system(size: 17, weight: .semibold)
    static let cardTitle = Font.system(size: 14, weight: .semibold)
    static let bodyEmphasis = Font.system(size: 13, weight: .medium)
    static let caption = Font.system(size: 12, weight: .regular)
    static let label = Font.system(size: 11, weight: .medium)
}
