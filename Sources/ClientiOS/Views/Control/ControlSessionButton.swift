import SwiftUI

struct ControlSessionLabel: View {
    let title: LocalizedStringKey
    let symbol: String
    var isActive = false

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.body.weight(.medium)).frame(height: 22)
            Text(title).font(.caption2.weight(.medium)).lineLimit(1)
        }
        .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.72))
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(isActive ? Color.white.opacity(0.16) : Color.clear, in: .rect(cornerRadius: 12))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

struct ControlSessionButton: View {
    let title: LocalizedStringKey
    let symbol: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ControlSessionLabel(title: title, symbol: symbol, isActive: isActive)
        }
        .buttonStyle(.plain)
    }
}
