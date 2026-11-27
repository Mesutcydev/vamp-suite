import SwiftUI

/// Glass search field used on Stream’s app lists. Matches the app-row cards
/// instead of the opaque system rounded-border field.
struct VampAppSearchField: View {
    @Binding var text: String
    var placeholder: String = "Search apps"
    @Environment(\.streamDesign) private var streamDesign

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.regular))
                .foregroundStyle(streamDesign ? StreamDesign.secondary : PR.dim)
                .accessibilityHidden(true)

            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(PR.fg2))
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(PR.fg)
                .tint(PR.fg)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(PR.dim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .frame(minWidth: 44, minHeight: 44)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .modifier(StreamSearchSurface(isStream: streamDesign))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(placeholder))
    }
}

private struct StreamSearchSurface: ViewModifier {
    let isStream: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if isStream {
            content.streamGlass(radius: 20)
        } else {
            content.prGlassSurface(in: RoundedRectangle(cornerRadius: PR.rCard, style: .continuous), isInteractive: true)
        }
    }
}
