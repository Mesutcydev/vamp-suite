import SwiftUI
import SharedModels

struct ScreensScreen: View {
    let environment: ClientAppEnvironment

    @ObservedObject private var layoutVM: DisplayLayoutViewModel
    @State private var mirroringToPhone = true
    @State private var quickLayout: QuickLayout = .extend

    private enum QuickLayout: String, CaseIterable {
        case extend
        case mirror
        case single
    }

    init(environment: ClientAppEnvironment) {
        self.environment = environment
        self.layoutVM = environment.displayLayoutViewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            PRScreenHeader(
                title: "screens",
                host: hostLabel,
                latency: "",
                state: .live
            )

            ScrollView {
                VStack(spacing: 12) {
                    PRCard("arrangement", trailing: {
                        Text("tap to mirror")
                            .foregroundColor(PR.accent)
                    }, content: {
                        displayArrangementPanel
                    })

                    PRCard("\(selectedDisplayLabel).config") {
                        PRRow(label: "resolution", trailing: {
                            Text(resolutionText)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(PR.accent2)
                        }, isLast: false)

                        PRRow(label: "refresh", trailing: {
                            Text(refreshText)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(PR.warn)
                        }, isLast: false)

                        PRRow(label: "hdr", trailing: {
                            Text(hdrText)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(PR.accent)
                        }, isLast: false)

                        PRRow(label: "mirror to phone", trailing: {
                            PRToggle(isOn: $mirroringToPhone)
                        }, isLast: true)
                    }

                    PRCard("quick layout") {
                        HStack(spacing: 8) {
                            ForEach(QuickLayout.allCases, id: \.self) { option in
                                Button {
                                    quickLayout = option
                                    applyQuickLayout(option)
                                } label: {
                                    Text(option.rawValue)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundColor(quickLayout == option ? PR.accent : PR.fg2)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(quickLayout == option ? PR.accent.opacity(0.10) : PR.bg2)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: PR.r8)
                                                .strokeBorder(quickLayout == option ? PR.accent.opacity(0.45) : PR.border)
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: PR.r8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .background(PR.bg)
        .task {
            await seedLayoutIfNeeded()
        }
    }

    private var hostLabel: String {
        environment.sessionCoordinator.connectedHostName ?? "displays · arranged"
    }

    private var selectedDisplay: DisplayDescriptor? {
        layoutVM.selectedDisplay ?? layoutVM.primaryDisplay ?? layoutVM.displays.first
    }

    private var selectedDisplayLabel: String {
        selectedDisplay?.name.lowercased() ?? "main"
    }

    private var resolutionText: String {
        guard let d = selectedDisplay else { return "--" }
        return "\(Int(d.pixelSize.width))×\(Int(d.pixelSize.height))"
    }

    private var refreshText: String {
        guard let hz = selectedDisplay?.refreshRate else { return "--" }
        return "\(Int(hz.rounded())) Hz"
    }

    private var hdrText: String {
        selectedDisplay == nil ? "--" : "p3 · enabled"
    }

    @ViewBuilder
    private var displayArrangementPanel: some View {
        GeometryReader { geo in
            let panelW = geo.size.width
            let panelH: CGFloat = 180

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: PR.r8)
                    .fill(PR.bg2)

                DottedGrid(spacing: 20)
                    .clipShape(RoundedRectangle(cornerRadius: PR.r8))

                if let layout = layoutVM.layout, !layout.displays.isEmpty {
                    let displays = layout.displays
                    let minX = displays.map { $0.frame.minX }.min() ?? 0
                    let minY = displays.map { $0.frame.minY }.min() ?? 0
                    let maxX = displays.map { $0.frame.maxX }.max() ?? 1
                    let maxY = displays.map { $0.frame.maxY }.max() ?? 1
                    let span = max(maxX - minX, maxY - minY)
                    let scale = span > 0 ? 280.0 / span : 1.0

                    ForEach(displays) { display in
                        Button {
                            layoutVM.selectDisplay(id: display.id)
                        } label: {
                            let w = CGFloat(max(28.0, display.frame.size.width * scale))
                            let h = CGFloat(max(22.0, display.frame.size.height * scale))
                            let x = CGFloat((display.frame.origin.x - minX) * scale) + 20
                            let y = CGFloat((display.frame.origin.y - minY) * scale) + 20
                            let isSelected = selectedDisplay?.id == display.id

                            ZStack(alignment: .topTrailing) {
                                RoundedRectangle(cornerRadius: PR.r6)
                                    .fill(isSelected ? PR.accent.opacity(0.14) : Color.white.opacity(0.03))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: PR.r6)
                                            .strokeBorder(isSelected ? PR.accent : PR.borderHi, lineWidth: isSelected ? 2 : 1)
                                    )
                                    .frame(width: w, height: h)

                                if display.isPrimary {
                                    Text("★")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(PR.warn)
                                        .padding(4)
                                }
                            }
                            .position(x: x + w / 2, y: y + h / 2)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text("No display layout yet")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(PR.err)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
            }
            .frame(width: panelW, height: panelH)
            .overlay(
                RoundedRectangle(cornerRadius: PR.r8)
                    .strokeBorder(PR.border)
            )
            .clipShape(RoundedRectangle(cornerRadius: PR.r8))
        }
        .frame(height: 180)
    }

    private func applyQuickLayout(_ option: QuickLayout) {
        switch option {
        case .extend:
            layoutVM.selectUnifiedDesktop()
        case .mirror:
            mirroringToPhone = true
        case .single:
            if let primary = layoutVM.primaryDisplay ?? layoutVM.displays.first {
                layoutVM.selectDisplay(id: primary.id)
            }
        }
    }

    private func seedLayoutIfNeeded() async {
        guard layoutVM.layout == nil else { return }
        let displays = [
            DisplayDescriptor(
                id: "main",
                name: "main",
                frame: DesktopRect(origin: DesktopPoint(x: 0, y: 0), size: DesktopSize(width: 2560, height: 1440)),
                visibleFrame: nil,
                pixelSize: DesktopSize(width: 5120, height: 2880),
                scaleFactor: 2,
                refreshRate: 120,
                isPrimary: true
            ),
            DisplayDescriptor(
                id: "side",
                name: "side",
                frame: DesktopRect(origin: DesktopPoint(x: 2560, y: 120), size: DesktopSize(width: 1920, height: 1080)),
                visibleFrame: nil,
                pixelSize: DesktopSize(width: 3840, height: 2160),
                scaleFactor: 2,
                refreshRate: 60,
                isPrimary: false
            )
        ]
        layoutVM.update(layout: DisplayLayout.computed(from: displays))
    }
}

private struct DottedGrid: View {
    let spacing: CGFloat

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                var y: CGFloat = 0
                while y <= h {
                    var x: CGFloat = 0
                    while x <= w {
                        path.addEllipse(in: CGRect(x: x, y: y, width: 1, height: 1))
                        x += spacing
                    }
                    y += spacing
                }
            }
            .fill(Color.white.opacity(0.04))
        }
    }
}

#Preview("ScreensScreen") {
    ScreensScreen(environment: ClientAppEnvironment.makeDefault(clientName: "Vamp Control"))
}
