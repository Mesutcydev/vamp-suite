import SwiftUI

/// Glass search field used on Stream’s app lists. Matches the app-row cards
/// instead of the opaque system rounded-border field.
struct VampAppSearchField: View {
    @Binding var text: String
    var placeholder: String = "Search apps"

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundStyle(PR.dim)
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
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .prGlassSurface(
            in: RoundedRectangle(cornerRadius: PR.rCard, style: .continuous),
            isInteractive: true
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(placeholder))
    }
}
