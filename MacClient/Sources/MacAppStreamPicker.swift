import AppKit
import SwiftUI
import SharedProtocol

/// The application browser Vamp Control shows when the connected host streams a
/// single app window rather than a whole display.
///
/// Vamp Sync (and any host that negotiates App Streaming without multi-display)
/// deliberately starts no capture until the client names a target, so without
/// this screen the session sat on "Waiting for video…" forever. The iOS browser
/// is UIKit-only, so this is its Mac counterpart over the same view model.
struct MacAppStreamPicker: View {
    @ObservedObject var vm: AppStreamViewModel
    let hostName: String
    let onDisconnect: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 148, maximum: 220), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacBrand.pageBackdrop)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Stream an app from \(hostName)")
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Refresh") { vm.backToApps() }
                .disabled(isBusy)
            Button("Disconnect", role: .destructive, action: onDisconnect)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var subtitle: String {
        switch vm.status {
        case .loadingApps: return "Reading the app list…"
        case .launching(let name): return "Opening \(name)…"
        case .failed(let reason), .targetLost(let reason): return reason
        default:
            let count = vm.applications.count
            return count == 0 ? "No apps reported yet." : "\(count) apps available"
        }
    }

    private var isBusy: Bool {
        switch vm.status {
        case .loadingApps, .launching: return true
        default: return false
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.applications.isEmpty {
            VStack(spacing: 12) {
                if isBusy {
                    ProgressView().controlSize(.large)
                } else {
                    Image(systemName: "macwindow.badge.plus")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                }
                Text(isBusy ? "Asking the Mac for its apps…" : "No apps to stream yet")
                    .font(.headline)
                Text("Vamp Sync only shares one app window at a time. Open an app on that Mac, then refresh.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                if !isBusy {
                    Button("Try Again") { vm.backToApps() }
                        .controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(sortedApplications) { app in
                        MacAppStreamTile(application: app, isBusy: isBusy) { vm.select(app) }
                            .contextMenu {
                                if app.isRunning, ApplicationClosePolicy.canClose(app.bundleIdentifier) {
                                    Button("Close \(app.name)", role: .destructive) { vm.close(app) }
                                }
                            }
                    }
                }
                .padding(20)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Applications available to stream")
            }
        }
    }

    /// Running apps first, then alphabetical — the Mac's frontmost app leads,
    /// which is almost always the one the user came here to open.
    private var sortedApplications: [RemoteApplication] {
        vm.applications.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

private struct MacAppStreamTile: View {
    let application: RemoteApplication
    let isBusy: Bool
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            BrandCard(hovering: hovering) {
                VStack(spacing: 8) {
                    icon
                        .frame(width: 52, height: 52)
                    Text(application.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)
                    Text(application.isRunning ? "Running" : "Not open")
                        .font(.caption2)
                        .foregroundStyle(application.isRunning ? Color.green : Color.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .padding(.horizontal, 10)
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .onHover { hovering = $0 }
        .help(application.isRunning
              ? "Stream \(application.name)"
              : "Open \(application.name) on the Mac and stream it")
        .accessibilityLabel(application.name)
        .accessibilityValue(application.isRunning ? "Running" : "Not open")
    }

    @ViewBuilder
    private var icon: some View {
        if let base64 = application.iconPNGBase64,
           let data = Data(base64Encoded: base64),
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
        }
    }
}
