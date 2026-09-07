import SwiftUI
import SharedProtocol
import SharedModels
#if canImport(UIKit)
import UIKit
#endif

/// Assistant-backed App Stream keeps the app browser separate from whole-display Remote
/// Control, while both destinations use the same proven control surface after selection.
struct VampAssistantAppStreamView: View {
    let session: BeetCodeRemoteSessionViewModel.Session
    let onClose: () -> Void
    let onRefreshStatus: () async -> String?

    @State private var runningApplications: [BeetCodeRemoteApplication] = []
    @State private var installedApplications: [BeetCodeRemoteApplication] = []
    @State private var selectedApplication: BeetCodeRemoteApplication?
    @State private var launchingName: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectionRevision = UUID()
    @State private var originalApplications: [UInt32: BeetCodeRemoteApplication] = [:]
    @State private var resizeOperation: Task<Void, Never>?
    @State private var isResizing = false
    @State private var sizingRecoveryFailed = false
    @State private var sizingIntent = AppStreamSizingIntent()
    @State private var sizingActionID = UUID()
    @State private var adaptive = false
    @State private var sizingRequested = false
    @State private var streamRevision = 0
    @State private var viewportAspect = 9.0 / 19.5

    var body: some View {
        GeometryReader { proxy in
            Group {
                if !session.status.ready {
                    // App inventory remains readable while macOS is at loginwindow, but
                    // launching or focusing a window cannot succeed there. Route through
                    // the same authenticated unlock/permission surface as Remote Control
                    // before exposing tappable apps.
                    BeetCodeRemoteView(
                        session: session,
                        onClose: onClose,
                        onRefresh: onRefreshStatus)
                } else if let selectedApplication {
                    BeetCodeRemoteView(
                        session: session,
                        windowID: selectedApplication.windowID,
                        streamTitle: selectedApplication.name,
                        isTerminalApplication: AppStreamApplicationProfile.isTerminal(
                            bundleIdentifier: selectedApplication.bundleIdentifier,
                            name: selectedApplication.name),
                        // ScreenCaptureKit fixes its encoder dimensions when a
                        // stream starts. Restart after the Mac confirms new AX
                        // bounds so rotation never squeezes or crops the newly
                        // resized window into the previous frame geometry.
                        streamGeometryRevision: "\(selectedApplication.windowID ?? 0)-\(selectedApplication.width)-\(selectedApplication.height)-\(streamRevision)",
                        onClose: onClose,
                        onRefresh: onRefreshStatus,
                        onChooseApplication: { selectionRevision = UUID(); self.selectedApplication = nil; Task { await loadApplications() } },
                        onViewportSize: { updateViewport($0) },
                        inputSuspended: isResizing || sizingRecoveryFailed,
                        sizingNotice: errorMessage,
                        onAdaptiveSizing: { adaptive = true; sizingRequested = true; sizingActionID = UUID() },
                        onOriginalSizing: { adaptive = false; sizingRequested = true; sizingActionID = UUID() })
                } else {
                    VampAssistantApplicationBrowser(
                        macName: session.displayName,
                        runningApplications: runningApplications,
                        installedApplications: installedApplications,
                        isLoading: isLoading,
                        launchingName: launchingName,
                        errorMessage: errorMessage,
                        onClose: onClose,
                        onRefresh: { Task { await loadApplications() } },
                        onSelect: { application in Task { await open(application) } },
                        onQuit: { application in Task { await quit(application) } })
                }
            }
            .tint(PR.accent)
            // Seeds the aspect for the launch request, before any video exists to measure.
            // Once the stream is up, `onViewportSize` refines it to the real video area.
            .onAppear { updateViewport(proxy.size) }
            .onChangeCompat(of: proxy.size) { if selectedApplication == nil { updateViewport($0) } }
            .task(id: resizeTaskID) {
                let intent = sizingIntent.request()
                guard session.status.ready, sizingRequested,
                      let application = selectedApplication, let windowID = application.windowID else {
                    isResizing = false
                    return
                }
                isResizing = true
                sizingRecoveryFailed = false
                defer { if sizingIntent.accepts(intent) { isResizing = false } }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                // Cancellation of the view task does not imply cancellation at the HTTP server.
                // Drain the previous operation before sending another resize.
                await resizeOperation?.value
                guard !Task.isCancelled else { return }
                let revision = selectionRevision
                let aspect = requestedAspect(for: application)
                let operation = Task { @MainActor in
                    sizingIntent.markSent(intent)
                    do {
                        let resized = try await session.client.resizeApplication(
                            windowID: windowID, clientViewportAspect: aspect)
                        guard sizingIntent.accepts(intent), revision == selectionRevision, selectedApplication?.windowID == windowID else { return }
                        present(resized)
                        updateSizingNotice(resized, requestedAspect: aspect)
                    } catch {
                        guard sizingIntent.accepts(intent), revision == selectionRevision else { return }
                        // A failed HTTP response does not prove the Mac kept its old bounds.
                        // Revalidate before enabling clicks against the existing capture geometry.
                        do {
                            let windows = try await session.client.applications()
                            guard sizingIntent.accepts(intent), revision == selectionRevision else { return }
                            guard let current = windows.first(where: { $0.windowID == windowID }) else {
                                self.selectedApplication = nil
                                errorMessage = "That window is no longer available. Choose an open window."
                                return
                            }
                            present(current)
                            errorMessage = "Could not apply the requested size. Showing the current window."
                        } catch {
                            guard sizingIntent.accepts(intent), revision == selectionRevision else { return }
                            sizingRecoveryFailed = true
                            errorMessage = "Window size could not be verified. Return to Apps and reopen it."
                        }
                    }
                }
                resizeOperation = operation
                await operation.value
            }
            .task(id: "\(session.address)-\(session.status.ready)") {
                guard session.status.ready else { return }
                await loadApplications()
                if errorMessage == nil, let selected = selectedApplication,
                   !runningApplications.contains(where: { $0.windowID == selected.windowID }) {
                    selectionRevision = UUID()
                    selectedApplication = nil
                    errorMessage = "That window is no longer available. Choose an open window."
                }
            }
        }
        .onDisappear { sizingIntent.cancel(); selectionRevision = UUID(); launchingName = nil }
    }

    private var resizeTaskID: String {
        "\(selectedApplication?.windowID ?? 0)-\(adaptive ? viewportAspect : 0)-\(adaptive)-\(sizingRequested)-\(sizingActionID)-\(session.status.ready)-\(session.address)"
    }

    private func updateViewport(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let aspect = Double(size.width / size.height)
        guard aspect.isFinite, (0.25...4).contains(aspect) else { return }
        viewportAspect = aspect
    }

    private func loadApplications() async {
        guard session.status.ready else { return }
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            apply(try await session.client.applications())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func quit(_ application: BeetCodeRemoteApplication) async {
        guard session.status.ready else {
            errorMessage = "Unlock the Mac before closing an application."
            return
        }
        guard launchingName == nil else { return }
        guard let bundleIdentifier = application.bundleIdentifier, !bundleIdentifier.isEmpty else {
            errorMessage = "That Mac application does not expose a close identifier."
            return
        }
        guard ApplicationClosePolicy.canClose(bundleIdentifier) else {
            errorMessage = "\(application.name) cannot be closed remotely."
            return
        }
        errorMessage = nil
        do {
            try await session.client.quitApplication(bundleIdentifier: bundleIdentifier)
            if selectedApplication?.bundleIdentifier == bundleIdentifier {
                selectedApplication = nil
            }
            await loadApplications()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func open(_ application: BeetCodeRemoteApplication) async {
        guard session.status.ready else {
            errorMessage = "Unlock the Mac before opening an application."
            return
        }
        guard launchingName == nil else { return }
        await resizeOperation?.value
        let revision = UUID()
        selectionRevision = revision
        launchingName = application.name
        errorMessage = nil
        defer { if revision == selectionRevision { launchingName = nil } }
        adaptive = true
        sizingRequested = true
        sizingActionID = UUID()
        sizingRecoveryFailed = false
        if application.isRunning, application.windowID != nil {
            present(application)
            return
        }
        guard let bundleIdentifier = application.bundleIdentifier, !bundleIdentifier.isEmpty else {
            errorMessage = "That Mac application does not expose a launch identifier."
            return
        }
        do {
            let launched = try await session.client.launchApplication(
                bundleIdentifier: bundleIdentifier)
            guard !Task.isCancelled, revision == selectionRevision else { return }
            present(launched)
            let applications = try await session.client.applications()
            guard !Task.isCancelled, revision == selectionRevision else { return }
            apply(applications)
        } catch {
            guard !Task.isCancelled, revision == selectionRevision else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// `BeetCodeRemoteView` streams the whole Mac display when it is handed no window id, so an
    /// app the Mac could not resolve a window for would silently open the entire desktop instead
    /// of the one app the browser asked for. Stay in the browser and say what happened.
    private func present(_ application: BeetCodeRemoteApplication) {
        guard application.windowID != nil else {
            errorMessage = "\(application.name) has no open window on the Mac yet. Open one there, then tap it again."
            return
        }
        // Do not carry a previous failure into a selection that just succeeded — the browser
        // shows this banner again as soon as the user comes back from the stream.
        errorMessage = nil
        if let id = application.windowID, originalApplications[id] == nil { originalApplications[id] = application }
        streamRevision &+= 1
        selectedApplication = application
    }

    private func requestedAspect(for application: BeetCodeRemoteApplication) -> Double {
        let size = adaptiveSize(for: application)
        return size.width / max(size.height, 1)
    }

    private func updateSizingNotice(_ application: BeetCodeRemoteApplication, requestedAspect: Double) {
        if !adaptive {
            errorMessage = "Original proportions restored. This Assistant API cannot restore exact window dimensions."
        } else {
            let expected = adaptiveSize(for: application)
            let actualAspect = application.width / max(application.height, 1)
            if abs(actualAspect - expected.width / max(expected.height, 1)) > 0.05 {
                errorMessage = "The Mac kept a different window shape. Zoom or pan for a closer view."
            }
        }
    }

    /// The shape this client asked the Mac to produce, using the same shared policy the
    /// Sync host applies server-side. Notices compare against this, not the raw viewport.
    private func adaptiveSize(for application: BeetCodeRemoteApplication) -> DesktopSize {
        let original = application.windowID.flatMap { originalApplications[$0] } ?? application
        guard adaptive else {
            return DesktopSize(width: max(original.width, 1), height: max(original.height, 1))
        }
        // Assistant exposes aspect-only resizing, not exact dimensions or window screen ID.
        // Use the smallest reported screen to avoid promising width the server cannot retain.
        let widths = session.status.displays?.map(\.width) ?? []
        let heights = session.status.displays?.map(\.height) ?? []
        guard let width = widths.min() ?? session.status.displayWidth,
              let height = heights.min() ?? session.status.displayHeight else {
            // No usable display bounds from the Assistant host: still ask for the phone's
            // shape. Falling back to `max(viewportAspect, originalAspect)` here kept a
            // landscape Mac window landscape, which is exactly the letterboxed strip this
            // resize exists to avoid. Only the aspect matters to the Assistant API.
            return DesktopSize(width: viewportAspect * 1000, height: 1000)
        }
        return AdaptiveWindowSizing.size(
            original: DesktopSize(width: original.width, height: original.height),
            available: DesktopSize(width: max(width - 48, 1), height: max(height - 76, 1)),
            viewport: DesktopSize(width: viewportAspect, height: 1),
            bundleIdentifier: original.bundleIdentifier ?? "")
    }

    private func apply(_ applications: [BeetCodeRemoteApplication]) {
        let liveIDs = Set(applications.compactMap(\.windowID))
        originalApplications = originalApplications.filter { liveIDs.contains($0.key) }
        runningApplications = applications.filter(\.isRunning)
        installedApplications = applications.filter { !$0.isRunning }
    }
}

private struct VampAssistantApplicationBrowser: View {
    let macName: String
    let runningApplications: [BeetCodeRemoteApplication]
    let installedApplications: [BeetCodeRemoteApplication]
    let isLoading: Bool
    let launchingName: String?
    let errorMessage: String?
    let onClose: () -> Void
    let onRefresh: () -> Void
    let onSelect: (BeetCodeRemoteApplication) -> Void
    let onQuit: (BeetCodeRemoteApplication) -> Void

    @State private var closeChoice: BeetCodeRemoteApplication?

    @State private var searchText = ""
    private func matches(_ app: BeetCodeRemoteApplication) -> Bool {
        searchText.isEmpty || app.name.localizedStandardContains(searchText)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VampAssistantApplicationHeader(macName: macName, onClose: onClose)
            VampAppSearchField(text: $searchText)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            ScrollView {
                LazyVStack(spacing: 12) {
                    if let errorMessage {
                        VampAssistantApplicationError(message: errorMessage, onRetry: onRefresh)
                    }
                    if let launchingName {
                        HStack(spacing: 12) {
                            ProgressView().tint(PR.fg)
                            Text("Opening \(launchingName)…")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(PR.fg)
                            Spacer()
                        }
                        .padding(14)
                        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
                    }
                    if runningApplications.isEmpty, installedApplications.isEmpty {
                        VampStreamAppListEmptyHint(
                            title: isLoading ? "Loading applications…" : "No applications found",
                            isLoading: isLoading,
                            actionTitle: isLoading ? nil : "Refresh",
                            action: isLoading ? nil : onRefresh
                        )
                    } else {
                        let runningMatches = runningApplications.filter(matches)
                        let installedMatches = installedApplications.filter(matches)
                        if runningMatches.isEmpty, installedMatches.isEmpty {
                            VampStreamAppListEmptyHint(title: "No apps match")
                        } else {
                            if !runningMatches.isEmpty {
                                VampAssistantApplicationSection(
                                    title: "Running",
                                    applications: runningMatches,
                                    isDisabled: launchingName != nil,
                                    onSelect: onSelect,
                                    onQuit: { closeChoice = $0 })
                            }
                            if !installedMatches.isEmpty {
                                VampAssistantApplicationSection(
                                    title: "All Apps",
                                    applications: installedMatches,
                                    isDisabled: launchingName != nil,
                                    onSelect: onSelect,
                                    onQuit: { closeChoice = $0 })
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { onRefresh() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PRAppBackground().ignoresSafeArea())
        .confirmationDialog(
            closeChoice.map { "Close \($0.name)?" } ?? "Close this app?",
            isPresented: Binding(
                get: { closeChoice != nil },
                set: { if !$0 { closeChoice = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let application = closeChoice {
                Button("Close \(application.name)", role: .destructive) { onQuit(application) }
            }
            Button("Cancel", role: .cancel) { closeChoice = nil }
        } message: {
            Text("Unsaved changes on the Mac may be lost.")
        }
    }
}

private struct VampAssistantApplicationHeader: View {
    let macName: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Apps")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(PR.fg)
                // The selected Mac's actual name is the primary context; the provider is secondary.
                Text(macName)
                    .font(.subheadline)
                    .foregroundStyle(PR.fg2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(PR.fg2)
                    .frame(
                        width: AppHostMetrics.iconControlTarget,
                        height: AppHostMetrics.iconControlTarget)
                    .contentShape(Circle())
            }
            .buttonStyle(PRGlassPressButtonStyle())
            .accessibilityLabel("Close")
            .accessibilityHint("Return to the Vamp Assistant picker")
        }
        .padding(.horizontal, AppHostMetrics.screenInset)
        .padding(.top, AppSpacing.lg)
        .padding(.bottom, AppSpacing.sm)
    }
}

private struct VampAssistantApplicationSection: View {
    let title: LocalizedStringKey
    let applications: [BeetCodeRemoteApplication]
    let isDisabled: Bool
    let onSelect: (BeetCodeRemoteApplication) -> Void
    let onQuit: (BeetCodeRemoteApplication) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PR.fg2)
                .padding(.horizontal, 4)
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            // One quiet grouped surface per section with inset separators, instead of a glass
            // border around every row. Repeated per-row glass made each app look like an equally
            // important floating control.
            // Lazy, matching the Sync picker: "All Apps" can list hundreds of installed apps.
            LazyVStack(spacing: 0) {
                ForEach(Array(applications.enumerated()), id: \.element.streamListID) { index, application in
                    if index > 0 {
                        Divider()
                            .padding(.leading, AppHostMetrics.cardPadding + AppHostMetrics.appIcon + AppSpacing.sm)
                    }
                    Button { onSelect(application) } label: {
                        VampAssistantApplicationRow(
                            name: application.name,
                            detail: application.listDetail,
                            isRunning: application.isRunning,
                            isActive: application.isActive,
                            iconPNGBase64: application.iconPNGBase64)
                    }
                    .buttonStyle(PRGlassPressButtonStyle())
                    .disabled(isDisabled)
                    .contextMenu {
                        if application.isRunning,
                           let bundle = application.bundleIdentifier,
                           ApplicationClosePolicy.canClose(bundle) {
                            Button("Close \(application.name)", systemImage: "xmark.app", role: .destructive) {
                                onQuit(application)
                            }
                        }
                    }
                }
            }
            .appQuietSurface(isInteractive: true)
        }
    }
}

private struct VampAssistantApplicationRow: View {
    let name: String
    /// Optional: an installed app with no window has no useful second line, and repeating
    /// "Installed · tap to open" on every such row is noise.
    let detail: String?
    let isRunning: Bool
    let isActive: Bool
    let iconPNGBase64: String?

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            applicationIcon
                .frame(width: AppHostMetrics.appIcon, height: AppHostMetrics.appIcon)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PR.fg)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(isActive ? PR.fg : PR.fg2)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // A chevron implies another selection level follows. A running window opens directly,
            // so it gets a disclosure only in the sense of "go"; an installed app is launched,
            // which reads differently, so it keeps the launch affordance.
            Image(systemName: isRunning ? "chevron.right" : "arrow.up.forward.app")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(PR.dim)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, AppHostMetrics.cardPadding)
        .padding(.vertical, AppSpacing.sm)
        .frame(maxWidth: .infinity, minHeight: AppHostMetrics.rowMinHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityValue(detail ?? (isRunning ? "Running" : "Installed"))
        .accessibilityHint(isRunning ? "Stream this Mac application" : "Open and stream this Mac application")
    }

    @ViewBuilder private var applicationIcon: some View {
        if let iconPNGBase64,
           let data = Data(base64Encoded: iconPNGBase64),
           let image = UIImage(data: data) {
            // Fit, not fill: a non-square icon stays undistorted and gets no extra frame.
            Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .scaledToFit()
                .padding(9)
                .foregroundStyle(PR.fg2)
                .background(PR.fg.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }
}

private struct VampAssistantApplicationError: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PR.warn)
            Text(message).font(.footnote).foregroundStyle(PR.fg)
            Spacer()
            Button("Retry", action: onRetry)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(PR.fg)
        }
        .padding(14)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
    }
}
