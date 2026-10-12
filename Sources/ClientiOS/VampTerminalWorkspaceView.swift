import Combine
import SwiftUI
import SharedProtocol
import Speech
import AVFoundation

private enum VampTerminalPresentation: String, CaseIterable, Identifiable {
    case chat
    case terminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Task chat"
        case .terminal: return "Terminal"
        }
    }

    var compactTitle: String {
        switch self {
        case .chat: return "Chat"
        case .terminal: return "Terminal"
        }
    }

    var systemImage: String {
        switch self {
        case .chat: return "text.bubble"
        case .terminal: return "terminal"
        }
    }
}

struct VampTerminalWorkspaceView: View {
    @ObservedObject var workspace: TerminalWorkspaceViewModel
    @ObservedObject var coordinator: ClientSessionCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renameTargetID: UUID?
    @State private var renameText = ""
    @State private var showingRename = false
    @State private var showingStartupCommand = false
    @State private var startupCommandPrefix = ""
    @State private var startupCommandInput = ""
    @State private var startupCommandTitle = "Attach terminal session"
    @State private var showingDisconnectConfirmation = false
    @State private var selectedAgentForWorkspace: VampAgentProvider?
    @State private var showingWorkspaces = false
    @State private var showingActivity = false
    @State private var presentation: VampTerminalPresentation = .chat
    @AppStorage("vampTerminal.appearance") private var appearance = "system"
    // ZCode-style working status: any tab with a streaming agent block counts
    // as "Working". A 15-second tick keeps the elapsed minutes fresh without
    // forcing the feed to re-render between message updates.
    @State private var statusTick = Date()
    @State private var workStartedAt: Date?
    private let statusTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var isWorking: Bool {
        workspace.tabs.contains { $0.chat.blocks.contains { $0.isStreaming } }
    }

    private var headerStatusText: String {
        guard let started = workStartedAt else { return "Connected" }
        let minutes = max(0, Int(statusTick.timeIntervalSince(started) / 60))
        return minutes < 1 ? "Working" : "Working for \(minutes)m"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            // Keep the workspace hierarchy stable while the keyboard moves.
            // The composer already participates in SwiftUI's keyboard-safe
            // area, so removing and reinserting these bars caused the whole
            // task view to jump on every focus transition.
            tabBar
            presentationBar

            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    // Every VT stays mounted for stable PTY state, but Chat is
                    // a semantic card feed—not a terminal embedded above a
                    // conversation. The VT surface becomes visible only when
                    // the user explicitly chooses Terminal.
                    ZStack {
                        // Only the mounted VT surface owns a provider-colored
                        // terminal canvas. Chat and empty states use the
                        // appearance-adaptive application surface so Light
                        // mode never places dark labels on a black backdrop.
                        if presentation == .terminal, !workspace.tabs.isEmpty {
                            workspace.selectedTab?.provider?.terminalBackground ?? Color.black
                        } else {
                            Color(uiColor: .systemBackground)
                        }
                        ForEach(workspace.tabs) { tab in
                            VampTerminalPaneView(
                                session: tab.session,
                                isActive: workspace.selectedTabID == tab.id,
                                isPreview: presentation == .chat,
                                provider: tab.provider,
                                onOpenTerminal: { presentation = .terminal },
                                onSendClipboardToHost: { _ = workspace.sendClipboardToHost() },
                                onRequestClipboardFromHost: { _ = workspace.requestClipboardFromHost() },
                                onTerminalClipboard: { text in
                                    _ = workspace.sendClipboardTextToHost(text)
                                },
                                onTerminalInput: { data in
                                    workspace.recordInput(tabID: tab.id, data: data)
                                }
                            )
                            .opacity(workspace.selectedTabID == tab.id ? 1 : 0.001)
                            .id(tab.id)
                        }
                        if presentation == .terminal, workspace.tabs.isEmpty {
                            emptyWorkspaceState
                                .padding(.horizontal, VampTerminalDesign.space4)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: presentation == .chat ? 0 : .infinity)
                    .opacity(presentation == .chat ? 0 : 1)
                    .allowsHitTesting(presentation == .terminal)
                    .clipped()

                    if presentation == .chat {
                        if let tab = workspace.selectedTab {
                            TerminalChatFeedView(
                            chat: tab.chat,
                            session: tab.session,
                            provider: tab.provider,
                            draft: Binding(
                                get: { workspace.tabs.first(where: { $0.id == tab.id })?.draft ?? "" },
                                set: { workspace.updateDraft(tabID: tab.id, value: $0) }
                            ),
                            onSendCommand: { command in
                                workspace.sendCommand(tabID: tab.id, text: command)
                            },
                            onResolveApproval: { choice in
                                workspace.resolveApproval(tabID: tab.id, choice: choice)
                            },
                            onOpenTerminal: { presentation = .terminal },
                            onInterrupt: { workspace.interrupt(tabID: tab.id) },
                            onResume: { workspace.resumePlan(tabID: tab.id) },
                            onSendClipboardToHost: { _ = workspace.sendClipboardToHost() },
                            onRequestClipboardFromHost: { _ = workspace.requestClipboardFromHost() }
                            )
                            .id(tab.id)
                        } else {
                            emptyWorkspaceState
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(uiColor: .systemBackground))
                        }
                    }
                }

                // Diagnostics never participate in the terminal's measured
                // geometry, so errors cannot move the viewport or composer.
                VStack(spacing: VampTerminalDesign.space2) {
                    if let message = workspace.lastTerminalError { terminalErrorBanner(message) }
                    if workspace.isConnectionSuspended { reconnectingBanner() }
                    if let message = workspace.clipboardStatusMessage { clipboardToast(message) }
                }
                // Hug the banner's own height and pin it to the top via the
                // parent ZStack. A full-height, hit-test-disabled overlay used
                // to float translucently over the pane status bar and chat rows
                // (so their text bled through and looked overlapped) and it
                // swallowed the Retry button's taps. Sizing to content keeps the
                // terminal geometry untouched while leaving only this strip
                // interactive, so Retry works and the surface below stays live.
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.horizontal, VampTerminalDesign.space3)
                .padding(.top, VampTerminalDesign.space3)
                .zIndex(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if let sessionID = coordinator.activeSessionID {
                workspace.activate(sessionID: sessionID)
            }
            // A plain shell is an interactive terminal first. Agent tabs use
            // the semantic Chat projection until the user switches modes.
            if workspace.selectedTab?.provider == nil {
                presentation = .terminal
            }
        }
        .onReceive(statusTimer) { date in
            statusTick = date
            if isWorking {
                if workStartedAt == nil { workStartedAt = date }
            } else {
                workStartedAt = nil
            }
        }
        .onChange(of: isWorking) { _, working in
            if working {
                if workStartedAt == nil { workStartedAt = Date() }
            } else {
                workStartedAt = nil
            }
        }
        .onChange(of: workspace.selectedTabID) { _, _ in
            if workspace.selectedTab?.provider == nil {
                presentation = .terminal
            }
        }
        .onChange(of: coordinator.terminalSessionLifecycle) { _, lifecycle in
            switch lifecycle {
            case .active(let sessionID):
                workspace.activate(sessionID: sessionID)
            case .suspended:
                // Transient transport loss: keep tabs mounted, remote shells
                // keep running on the Mac.
                workspace.suspendForReattach()
            case .ended:
                // Explicit user end: tear tabs down (polite close).
                workspace.stop()
            case .connecting, .inactive:
                break
            }
        }
        // Navigating away must NOT end the remote session: the workspace
        // stays mounted and the transport (app-level) keeps running.
        .fullScreenCover(item: $selectedAgentForWorkspace) { provider in
            VampWorkspaceChooserView(
                store: workspace.workspaceStore,
                provider: provider,
                hostName: coordinator.connectedHostName ?? "Connected Mac"
            ) { chosenWorkspace, resumeMode, persistenceMode in
                let launch = provider.launchConfiguration(
                    resumeMode: resumeMode,
                    persistenceMode: persistenceMode,
                    workspaceID: chosenWorkspace.id
                )
                _ = workspace.createTab(
                    title: provider.sessionDisplayName,
                    provider: provider,
                    workspace: chosenWorkspace,
                    resumeMode: resumeMode,
                    persistenceMode: persistenceMode,
                    launchExecutable: launch.executable,
                    launchArguments: launch.arguments
                )
                presentation = .chat
                selectedAgentForWorkspace = nil
            }
        }
        .fullScreenCover(isPresented: $showingWorkspaces) {
            VampWorkspacesView(
                store: workspace.workspaceStore,
                terminalWorkspace: workspace,
                hostName: coordinator.connectedHostName ?? "Connected Mac",
                connectionLabel: coordinator.connectionMode.label
            )
        }
        .sheet(isPresented: $showingActivity) {
            if let tab = workspace.selectedTab {
                TerminalSessionActivityView(chat: tab.chat, title: tab.title)
            }
        }
        .alert("Disconnect from Mac?", isPresented: $showingDisconnectConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) {
                Task { await coordinator.endSession() }
            }
        } message: {
            Text("All active terminal tabs on this connection will close. Use tmux or screen if you need to reconnect later.")
        }
        .alert("Rename terminal", isPresented: $showingRename) {
            TextField("Terminal name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let renameTargetID {
                    workspace.rename(tabID: renameTargetID, title: renameText)
                }
            }
        } message: {
            Text("Choose a short name for this shell tab.")
        }
        .alert(startupCommandTitle, isPresented: $showingStartupCommand) {
            TextField("session-name", text: $startupCommandInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Open") {
                let argument = startupCommandInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !argument.isEmpty else { return }
                _ = workspace.createTab(startupCommand: startupCommandPrefix + shellQuote(argument))
                startupCommandInput = ""
            }
        } message: {
            Text("Vamp Terminal opens a fresh PTY, then runs the command. Use tmux or screen to resume a shell or agent that is already running on the Mac.")
        }
    }

    private func terminalErrorBanner(_ message: String) -> some View {
        HStack(spacing: VampTerminalDesign.space2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(VampGlassPalette.warning)
            Text(message)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(VampGlassPalette.inkSecondary)
                .lineLimit(3)
            if workspace.hasStalledTab {
                Spacer(minLength: 6)
                Button("Retry") {
                    workspace.retryStalledTabs()
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(VampGlassPalette.ink)
                .padding(.horizontal, VampTerminalDesign.space3)
                .frame(minHeight: VampTerminalDesign.minTapTarget)
                .vampGlassSurface(.button, cornerRadius: VampTerminalDesign.controlRadius)
                .vampGlassOutline(cornerRadius: VampTerminalDesign.controlRadius)
                .buttonStyle(VampGlassPressStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, VampTerminalDesign.space3)
        .padding(.vertical, VampTerminalDesign.space2)
        // Opaque base under the glass so the pane status bar / chat rows behind
        // the floating banner never bleed through and read as overlapping text.
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: VampTerminalDesign.cardRadius, style: .continuous))
        .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.cardRadius)
        .vampGlassOutline(cornerRadius: VampTerminalDesign.cardRadius, color: VampGlassPalette.warning.opacity(0.30))
    }

    /// Quiet grace-state chip: the transport is away but the remote session is
    /// NOT over. Never flashes "Disconnected" for a brief app-switch or path
    /// flap — the Mac keeps running and tabs stay mounted.
    private func reconnectingBanner() -> some View {
        let online = coordinator.isNetworkPathSatisfied
        return HStack(spacing: VampTerminalDesign.space2) {
            // Offline is the device's fault and no spinner is honest about it;
            // "reconnecting" (path up, host quiet) is where a spinner belongs.
            if online {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VampGlassPalette.warning)
            }
            Text(online
                 ? "Reconnecting to Mac — sessions are still running"
                 : "Waiting for network — this device is offline")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(VampGlassPalette.inkSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: VampTerminalDesign.space2)
            if online {
                Button("Retry now") {
                    Task { try? await coordinator.forceReconnectLast() }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(VampGlassPalette.ink)
                .padding(.horizontal, VampTerminalDesign.space3)
                .frame(minHeight: VampTerminalDesign.minTapTarget)
                .vampGlassSurface(.button, cornerRadius: VampTerminalDesign.controlRadius)
                .vampGlassOutline(cornerRadius: VampTerminalDesign.controlRadius)
                .buttonStyle(VampGlassPressStyle())
                .accessibilityHint("Forces an immediate reconnect instead of waiting")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, VampTerminalDesign.space3)
        .padding(.vertical, VampTerminalDesign.space2)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: VampTerminalDesign.cardRadius, style: .continuous))
        .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.cardRadius)
        .vampGlassOutline(cornerRadius: VampTerminalDesign.cardRadius, color: (online ? VampGlassPalette.inkSecondary : VampGlassPalette.warning).opacity(0.25))
    }

    private func clipboardToast(_ message: String) -> some View {
        HStack(spacing: VampTerminalDesign.space2) {
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(VampGlassPalette.inkSecondary)
            Text(message)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(VampGlassPalette.inkSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, VampTerminalDesign.space3)
        .padding(.vertical, VampTerminalDesign.space2)
        // Opaque base under the glass so content behind the floating toast never
        // bleeds through and reads as overlapping text.
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: VampTerminalDesign.cardRadius, style: .continuous))
        .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.cardRadius)
        .vampGlassOutline(cornerRadius: VampTerminalDesign.cardRadius)
    }

    private var header: some View {
        HStack(spacing: VampTerminalDesign.space3) {
            Button {
                showingDisconnectConfirmation = true
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VampGlassPalette.inkSecondary)
                    .frame(width: VampTerminalDesign.minTapTarget, height: VampTerminalDesign.minTapTarget)
            }
            .buttonStyle(VampGlassPressStyle())
            .accessibilityLabel("Back to hosts")
            .accessibilityHint("Asks for confirmation before disconnecting")

            VStack(alignment: .leading, spacing: VampTerminalDesign.space1) {
                Text(presentation.title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(VampGlassPalette.ink)
                    .lineLimit(1)
                // Host context only — the live connection dot lives on the
                // trailing status pill, so this line no longer repeats it.
                Text("\(coordinator.connectedHostName ?? "Vamp Terminal") · \(coordinator.connectionMode.label)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VampGlassPalette.inkTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: VampTerminalDesign.space2)

            Menu {
                Section("Connected host") {
                    Label(coordinator.connectedHostName ?? "Vamp Terminal", systemImage: "terminal.fill")
                    Label(coordinator.connectionMode.label, systemImage: "circle.fill")
                }
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        presentation = .terminal
                    }
                } label: {
                    Label("Open Terminal", systemImage: "terminal")
                }
                Button {
                    showingActivity = true
                } label: {
                    Label("Session Activity", systemImage: "clock.arrow.circlepath")
                }
                Button {
                    showingWorkspaces = true
                } label: {
                    Label("Open workspaces", systemImage: "folder")
                }
                Menu {
                    appearanceButton("System", value: "system", systemImage: "circle.lefthalf.filled")
                    appearanceButton("Light", value: "light", systemImage: "sun.max")
                    appearanceButton("Dark", value: "dark", systemImage: "moon")
                } label: {
                    Label("Appearance", systemImage: "circle.righthalf.filled")
                }
                Button(role: .destructive) {
                    showingDisconnectConfirmation = true
                } label: {
                    Label("Disconnect", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                HStack(spacing: VampTerminalDesign.space2) {
                    Circle()
                        .fill(isWorking ? VampGlassPalette.ink : VampGlassPalette.good)
                        .frame(width: 7, height: 7)
                    Text(headerStatusText)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(VampGlassPalette.inkSecondary)
                }
                .padding(.horizontal, VampTerminalDesign.space3)
                .frame(minHeight: VampTerminalDesign.compactControlHeight)
                .vampGlassSurface(.capsule)
                .vampGlassOutline(cornerRadius: 999, color: VampGlassPalette.ruleStrong)
            }
            .accessibilityLabel("Connection menu")
        }
        .padding(.horizontal, VampTerminalDesign.space4)
        .padding(.vertical, VampTerminalDesign.space2)
        .vampGlassSurface(.toolbar, cornerRadius: 0)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(VampGlassPalette.ruleStrong)
                .frame(height: 0.5)
        }
    }

    private func appearanceButton(_ title: String, value: String, systemImage: String) -> some View {
        Button {
            appearance = value
        } label: {
            Label(title, systemImage: appearance == value ? "checkmark" : systemImage)
        }
    }

    private var presentationBar: some View {
        HStack {
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                ForEach(VampTerminalPresentation.allCases) { mode in
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                            presentation = mode
                        }
                    } label: {
                        Label(mode.compactTitle, systemImage: mode.systemImage)
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(presentation == mode ? VampGlassPalette.ink : VampGlassPalette.inkSecondary)
                            .padding(.horizontal, VampTerminalDesign.space3)
                            .frame(minHeight: VampTerminalDesign.compactControlHeight)
                            .background(
                                presentation == mode
                                    ? VampGlassPalette.surfaceFill
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: VampTerminalDesign.smallRadius, style: .continuous)
                            )
                            .overlay {
                                if presentation == mode {
                                    RoundedRectangle(cornerRadius: VampTerminalDesign.smallRadius, style: .continuous)
                                        .stroke(VampGlassPalette.ruleStrong, lineWidth: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(presentation == mode ? .isSelected : [])
                }
            }
            .padding(2)
            .background(VampGlassPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: VampTerminalDesign.controlRadius, style: .continuous))
            .vampGlassOutline(cornerRadius: VampTerminalDesign.controlRadius)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VampTerminalDesign.space4)
        .padding(.vertical, VampTerminalDesign.space1)
        .frame(height: 44)
        .vampGlassSurface(.toolbar, cornerRadius: 0)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(VampGlassPalette.rule)
                .frame(height: 0.5)
        }
    }

    private var emptyWorkspaceState: some View {
        VStack(spacing: VampTerminalDesign.space3) {
            Image(systemName: "terminal")
                .font(.title2)
                .foregroundStyle(VampGlassPalette.inkSecondary)
            Text("No terminal tabs")
                .font(.headline)
                .foregroundStyle(VampGlassPalette.ink)
            Text("Open a new shell to continue. Existing tabs stay alive when you switch between them.")
                .font(.footnote)
                .foregroundStyle(VampGlassPalette.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                showingWorkspaces = true
            } label: {
                Label("Choose workspace", systemImage: "folder")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, VampTerminalDesign.space4)
                    .frame(minHeight: VampTerminalDesign.minTapTarget)
                    .background(VampGlassPalette.ink, in: RoundedRectangle(cornerRadius: VampTerminalDesign.controlRadius, style: .continuous))
            }
            .buttonStyle(VampGlassPressStyle())
            .disabled(!workspace.canCreateTab)
        }
        .padding(VampTerminalDesign.space6)
        .frame(maxWidth: 360)
        .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.largeCardRadius)
        .vampGlassOutline(cornerRadius: VampTerminalDesign.largeCardRadius, color: VampGlassPalette.ruleStrong)
        .accessibilityElement(children: .contain)
    }

    private var tabBar: some View {
        ScrollViewReader { proxy in
            HStack(spacing: VampTerminalDesign.space2) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: VampTerminalDesign.space2) {
                        ForEach(workspace.tabs) { tab in
                            tabChip(tab)
                                .id(tab.id)
                        }
                    }
                    .padding(.horizontal, VampTerminalDesign.space3)
                    .padding(.vertical, VampTerminalDesign.space2)
                }
                .scrollClipDisabled()

                Menu {
                    Button {
                        showingWorkspaces = true
                    } label: {
                        Label("New shell in workspace", systemImage: "terminal")
                    }

                    Section("Resume a session") {
                        Button {
                            presentStartupCommand(
                                title: "Attach tmux session",
                                prefix: "tmux new-session -A -s "
                            )
                        } label: {
                            Label("Attach / create tmux", systemImage: "rectangle.split.2x1")
                        }
                        Button {
                            presentStartupCommand(
                                title: "Attach GNU screen",
                                prefix: "screen -r "
                            )
                        } label: {
                            Label("Attach screen", systemImage: "rectangle.on.rectangle")
                        }
                    }
                    Section("Agent launchers") {
                        ForEach(VampAgentProvider.allCases) { provider in
                            agentCommandButton(provider)
                        }
                    }
                    Section("Project context") {
                        Button {
                            showingWorkspaces = true
                        } label: {
                            Label("Choose workspace", systemImage: "folder.badge.gearshape")
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(workspace.canCreateTab ? VampGlassPalette.ink : VampGlassPalette.inkSubtle)
                        .frame(minWidth: VampTerminalDesign.minTapTarget, minHeight: VampTerminalDesign.minTapTarget)
                        .vampGlassSurface(.button, cornerRadius: VampTerminalDesign.controlRadius)
                        .vampGlassOutline(cornerRadius: VampTerminalDesign.controlRadius, color: VampGlassPalette.ruleStrong)
                }
                .buttonStyle(VampGlassPressStyle())
                .disabled(!workspace.canCreateTab)
                .accessibilityLabel("New terminal tab")
                .accessibilityValue(workspace.tabCountLabel)
                .accessibilityHint(workspace.canCreateTab ? "Opens another independent shell" : "Terminal capacity reached")
                .padding(.trailing, VampTerminalDesign.space3)
            }
            .onAppear {
                scrollSelectedTabIntoView(proxy, animated: false)
            }
            .onChange(of: workspace.selectedTabID) { _, _ in
                scrollSelectedTabIntoView(proxy, animated: true)
            }
        }
        .frame(height: 52)
        .vampGlassSurface(.toolbar, cornerRadius: 0)
        .overlay(alignment: .bottom) {
            Rectangle().fill(VampGlassPalette.ruleStrong).frame(height: 0.5)
        }
    }

    private func scrollSelectedTabIntoView(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let selectedTabID = workspace.selectedTabID else { return }
        let scroll = {
            proxy.scrollTo(selectedTabID, anchor: .center)
        }
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.18), scroll)
        } else {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction, scroll)
        }
    }

    private func tabChip(_ tab: TerminalWorkspaceViewModel.Tab) -> some View {
        let selected = workspace.selectedTabID == tab.id
        return HStack(spacing: 0) {
            Button {
                workspace.select(tabID: tab.id)
            } label: {
                HStack(spacing: VampTerminalDesign.space2) {
                    Circle()
                        .fill(dotColor(for: tab.state))
                        .frame(width: 7, height: 7)
                    Text(tab.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium, design: .rounded))
                        .foregroundStyle(selected ? VampGlassPalette.ink : VampGlassPalette.inkSecondary)
                        .lineLimit(1)
                    if tab.hasUnreadOutput {
                        Circle()
                            .fill(VampGlassPalette.ink)
                            .frame(width: 5, height: 5)
                            .accessibilityLabel("Unread output")
                    }
                    if let plan = tab.chat.taskPlan, plan.isActive {
                        Text(plan.progressLabel)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(VampGlassPalette.inkTertiary)
                            .accessibilityLabel("Task progress \(plan.progressLabel)")
                    }
                }
                .padding(.leading, VampTerminalDesign.space3)
                .padding(.trailing, workspace.tabs.count > 1 ? VampTerminalDesign.space2 : VampTerminalDesign.space3)
                .frame(minHeight: VampTerminalDesign.controlHeight)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.title)
            .accessibilityValue(accessibilityValue(for: tab, selected: selected))
            .accessibilityHint("Select this terminal")

            if workspace.tabs.count > 1 {
                Button {
                    workspace.close(tabID: tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(VampGlassPalette.inkTertiary)
                        .frame(minWidth: VampTerminalDesign.minTapTarget, minHeight: VampTerminalDesign.controlHeight)
                }
                .buttonStyle(VampGlassPressStyle())
                .accessibilityLabel("Close \(tab.title)")
            }
        }
        .vampGlassSurface(.tab, cornerRadius: VampTerminalDesign.tabRadius)
        .background {
            RoundedRectangle(cornerRadius: VampTerminalDesign.tabRadius, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.12) : Color.primary.opacity(0.035))
        }
        .vampGlassOutline(
            cornerRadius: VampTerminalDesign.tabRadius,
            color: selected ? VampGlassPalette.ruleStrong : VampGlassPalette.rule
        )
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(selected ? VampGlassPalette.ink : .clear)
                .frame(width: 24, height: 2)
                .offset(y: 1)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.92),
                    value: selected
                )
        }
        .contextMenu {
            Button {
                renameTargetID = tab.id
                renameText = tab.title
                showingRename = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                workspace.close(tabID: tab.id)
            } label: {
                Label("Close", systemImage: "xmark")
            }
        }
    }

    private func dotColor(for state: ClientTerminalSessionManager.State) -> Color {
        switch state {
        case .open: return VampGlassPalette.good
        case .opening: return VampGlassPalette.warning
        case .idle: return VampGlassPalette.inkSubtle
        case .closed: return VampGlassPalette.bad
        }
    }

    private func accessibilityValue(
        for tab: TerminalWorkspaceViewModel.Tab,
        selected: Bool
    ) -> String {
        let state: String
        switch tab.state {
        case .idle: state = "waiting"
        case .opening: state = "opening"
        case .open: state = "connected"
        case .closed: state = "closed"
        }
        let unread = tab.hasUnreadOutput ? ", unread output" : ""
        return "\(selected ? "selected, " : "")\(state)\(unread)"
    }

    private func presentStartupCommand(title: String, prefix: String) {
        startupCommandTitle = title
        startupCommandPrefix = prefix
        startupCommandInput = ""
        showingStartupCommand = true
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func agentCommandButton(_ provider: VampAgentProvider) -> some View {
        Button {
            // Agent-first launch resolves through the same workspace chooser as
            // the workspace-first flow. This prevents an agent from silently
            // inheriting an unrelated global cwd.
            selectedAgentForWorkspace = provider
        } label: {
            if let assetName = provider.assetName {
                Label(provider.displayName, image: assetName)
            } else {
                Label(provider.displayName, systemImage: provider.fallbackSystemImage)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(provider.accent)
            }
        }
        .accessibilityLabel(provider.displayName)
    }
}

private struct TerminalChatFeedView: View {
    @ObservedObject var chat: TerminalChatStore
    @ObservedObject var session: ClientTerminalSessionManager
    let provider: VampAgentProvider?
    @Binding var draft: String
    let onSendCommand: (String) -> Void
    let onResolveApproval: (TerminalChatStore.ApprovalChoice) -> Void
    let onOpenTerminal: () -> Void
    let onInterrupt: () -> Void
    let onResume: () -> Void
    let onSendClipboardToHost: () -> Void
    let onRequestClipboardFromHost: () -> Void

    @FocusState private var composerFocused: Bool
    @State private var isNearLatest = true
    @State private var pendingScrollTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: VampTerminalDesign.space4) {
                        if chat.blocks.isEmpty {
                            TerminalChatReadyCard(
                                title: provider?.sessionDisplayName ?? "Shell",
                                onOpenTerminal: onOpenTerminal
                            )
                            .id("chat-ready")
                        }
                        ForEach(chat.blocks) { block in
                            TerminalChatBlockView(block: block, provider: provider)
                                .id(block.id)
                        }
                        if let taskPlan = chat.taskPlan {
                            TaskPlanCard(plan: taskPlan, onInterrupt: onInterrupt, onResume: onResume)
                                .id(taskPlan.id)
                        }
                        if let approval = chat.pendingApproval {
                            TerminalApprovalCard(
                                approval: approval,
                                onResolve: onResolveApproval
                            )
                            .id(approval.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("chat-bottom")
                    }
                    .padding(.horizontal, VampTerminalDesign.space4)
                    .padding(.top, VampTerminalDesign.space4)
                    .padding(.bottom, VampTerminalDesign.space5)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .overlay(alignment: .bottomTrailing) {
                    if !isNearLatest {
                        Button {
                            scrollToLatest(proxy, animated: true)
                        } label: {
                            Label("Latest", systemImage: "arrow.down")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .padding(.horizontal, VampTerminalDesign.space3)
                                .frame(minHeight: VampTerminalDesign.compactControlHeight)
                                .vampGlassSurface(.capsule)
                                .vampGlassOutline(cornerRadius: 999, color: VampGlassPalette.ruleStrong)
                        }
                        .buttonStyle(VampGlassPressStyle())
                        .padding(.trailing, VampTerminalDesign.space4)
                        .padding(.bottom, VampTerminalDesign.space3)
                    }
                }
                .onAppear {
                    scrollToLatestAfterLayout(proxy, animated: false)
                }
                .onChange(of: chat.blocks) { _, _ in
                    guard isNearLatest else { return }
                    scrollToLatestAfterLayout(proxy, animated: false)
                }
                .onChange(of: chat.taskPlan) { _, _ in
                    guard isNearLatest else { return }
                    scrollToLatestAfterLayout(proxy, animated: false)
                }
                .onChange(of: chat.pendingApproval) { _, _ in
                    guard let approval = chat.pendingApproval else { return }
                    // A permission decision is more important than preserving
                    // composer focus. Keeping the keyboard up forced the tall
                    // card beneath the fixed workspace header on iPhone.
                    composerFocused = false
                    DispatchQueue.main.async {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                            proxy.scrollTo(approval.id, anchor: .top)
                        }
                    }
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    let distanceFromLatest = geometry.contentSize.height
                        - geometry.contentOffset.y
                        - geometry.containerSize.height
                    return distanceFromLatest <= 56
                } action: { _, nearLatest in
                    isNearLatest = nearLatest
                }
            }
            .onDisappear {
                pendingScrollTask?.cancel()
                pendingScrollTask = nil
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The conversation owns the scrolling region. The composer uses
            // one native keyboard-safe inset; focusing it must not also
            // programmatically scroll the feed, which made cards jump while
            // the keyboard animation was still changing the viewport.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                TerminalChatComposer(
                    draft: $draft,
                    composerFocused: $composerFocused,
                    provider: provider,
                    isEnabled: session.canEditInput,
                    canSend: session.canSendInput,
                    onSend: sendDraft,
                    onOpenTerminal: onOpenTerminal,
                    onPaste: pasteFromPhone,
                    onSendClipboardToHost: onSendClipboardToHost,
                    onRequestClipboardFromHost: onRequestClipboardFromHost
                )
            }
        .background(Color(uiColor: .systemBackground))
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy, animated: Bool) {
        if !animated || reduceMotion {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
        } else {
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
        }
    }

    private func scrollToLatestAfterLayout(_ proxy: ScrollViewProxy, animated: Bool) {
        isNearLatest = true
        pendingScrollTask?.cancel()
        pendingScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            scrollToLatest(proxy, animated: animated)
        }
    }

    private func sendDraft() {
        // The composer submission is the canonical Chat message. Use trimming
        // only to reject an empty draft; sending the trimmed value corrupted
        // intentional indentation and made Chat differ from what the agent
        // actually received in its PTY.
        let submittedText = draft
        guard !submittedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              session.canSendInput else { return }
        onSendCommand(submittedText)
        draft = ""
        composerFocused = true
    }

    private func pasteFromPhone() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        if draft.isEmpty {
            draft = text
        } else {
            draft += text
        }
        composerFocused = true
    }
}

private struct TaskPlanCard: View {
    let plan: SessionTaskPlan
    let onInterrupt: () -> Void
    let onResume: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: VampTerminalDesign.space3) {
            Button {
                if reduceMotion {
                    isExpanded.toggle()
                } else {
                    withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
                }
            } label: {
                HStack(spacing: VampTerminalDesign.space2) {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(statusColor)
                    Text(plan.title ?? "Plan")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .textCase(.uppercase)
                        .tracking(1.1)
                    Spacer(minLength: VampTerminalDesign.space2)
                    Text(plan.progressLabel)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(VampGlassPalette.inkSecondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(VampGlassPalette.inkTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse task plan" : "Expand task plan")
            .accessibilityValue(plan.progressLabel)

            if isExpanded {
                VStack(alignment: .leading, spacing: VampTerminalDesign.space2) {
                    ForEach(plan.tasks) { task in
                        taskRow(task)
                    }
                }
                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))

                HStack(spacing: VampTerminalDesign.space2) {
                    Text(plan.source == .inferred ? "Inferred from agent plan" : "Agent task plan")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(VampGlassPalette.inkSubtle)
                    Spacer(minLength: VampTerminalDesign.space2)
                    if plan.state == .planning || plan.state == .running {
                        Button(action: onInterrupt) {
                            Label("Interrupt", systemImage: "stop.fill")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .padding(.horizontal, VampTerminalDesign.space3)
                                .frame(minHeight: VampTerminalDesign.compactControlHeight)
                                .vampGlassSurface(.button, cornerRadius: VampTerminalDesign.controlRadius)
                        }
                        .buttonStyle(VampGlassPressStyle())
                        .accessibilityHint("Sends Control-C and pauses this plan")
                    } else if plan.state == .paused {
                        Button(action: onResume) {
                            Label("Resume", systemImage: "play.fill")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .padding(.horizontal, VampTerminalDesign.space3)
                                .frame(minHeight: VampTerminalDesign.compactControlHeight)
                                .vampGlassSurface(.button, cornerRadius: VampTerminalDesign.controlRadius)
                        }
                        .buttonStyle(VampGlassPressStyle())
                        .accessibilityHint("Resumes this plan without recreating the terminal")
                    }
                }
            } else if let current = plan.tasks.first(where: { $0.status == .running }) {
                Text(current.title)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(VampGlassPalette.inkSecondary)
                    .lineLimit(2)
            }
        }
        .padding(VampTerminalDesign.space4)
        .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.largeCardRadius)
        .vampGlassOutline(cornerRadius: VampTerminalDesign.largeCardRadius, color: VampGlassPalette.ruleStrong)
        .accessibilityElement(children: .contain)
    }

    private func taskRow(_ task: SessionTask) -> some View {
        HStack(alignment: .top, spacing: VampTerminalDesign.space3) {
            Image(systemName: iconName(for: task.status))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color(for: task.status))
                .frame(width: 18, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(task.order). \(task.title)")
                    .font(.system(.subheadline, design: .rounded).weight(task.status == .running ? .semibold : .regular))
                    .foregroundStyle(task.status == .completed || task.status == .skipped ? VampGlassPalette.inkTertiary : VampGlassPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if task.status == .running, let detail = task.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(VampGlassPalette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if task.status == .failed, let reason = task.failureReason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(VampGlassPalette.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var statusSymbol: String {
        switch plan.state {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .paused: return "pause.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        case .planning, .running: return "circle.dotted"
        }
    }

    private var statusColor: Color {
        switch plan.state {
        case .completed: return VampGlassPalette.good
        case .failed, .cancelled: return VampGlassPalette.bad
        case .paused: return VampGlassPalette.warning
        case .planning, .running: return VampGlassPalette.inkSecondary
        }
    }

    private func iconName(for status: SessionTaskStatus) -> String {
        switch status {
        case .pending: return "circle"
        case .running: return "circle.dotted"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }

    private func color(for status: SessionTaskStatus) -> Color {
        switch status {
        case .pending: return VampGlassPalette.inkTertiary
        case .running: return VampGlassPalette.ink
        case .completed: return VampGlassPalette.good
        case .failed: return VampGlassPalette.bad
        case .skipped: return VampGlassPalette.inkSubtle
        }
    }
}

private struct TerminalApprovalCard: View {
    let approval: TerminalChatStore.PendingApproval
    let onResolve: (TerminalChatStore.ApprovalChoice) -> Void

    @State private var selection: TerminalChatStore.ApprovalChoice = .once

    var body: some View {
        VStack(alignment: .leading, spacing: VampTerminalDesign.space3) {
            VStack(alignment: .leading, spacing: VampTerminalDesign.space1) {
                Label("Permission required", systemImage: "lock.shield")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                Text("Awaiting approval · \(approval.identity)")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(VampGlassPalette.inkSecondary)
            }

            Text(approval.command)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(VampGlassPalette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(VampTerminalDesign.space3)
                .background(VampGlassPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: VampTerminalDesign.controlRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: VampTerminalDesign.controlRadius, style: .continuous)
                        .stroke(VampGlassPalette.rule, lineWidth: 1)
                }

            VStack(spacing: VampTerminalDesign.space2) {
                approvalChoice(.once, number: "1", title: "Allow", detail: "Allow only this time")
                approvalChoice(.always, number: "2", title: "Always allow", detail: "Do not ask again for this command")
                approvalChoice(.deny, number: "3", title: "Deny", detail: "Reject it for now")
            }

            HStack(alignment: .center, spacing: VampTerminalDesign.space3) {
                Text("Choose an action, then confirm.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(VampGlassPalette.inkTertiary)
                Spacer(minLength: 0)
                Button("Confirm") { onResolve(selection) }
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, VampTerminalDesign.space4)
                    .frame(minHeight: VampTerminalDesign.minTapTarget)
                    .background(VampGlassPalette.ink, in: RoundedRectangle(cornerRadius: VampTerminalDesign.controlRadius, style: .continuous))
            }
        }
        .padding(VampTerminalDesign.space4)
        .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.largeCardRadius)
        .vampGlassOutline(cornerRadius: VampTerminalDesign.largeCardRadius, color: VampGlassPalette.ruleStrong)
    }

    private func approvalChoice(
        _ choice: TerminalChatStore.ApprovalChoice,
        number: String,
        title: String,
        detail: String
    ) -> some View {
        Button {
            selection = choice
        } label: {
            HStack(spacing: VampTerminalDesign.space3) {
                Text(number + ".")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(VampGlassPalette.inkTertiary)
                    .frame(width: 22, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    Text(detail)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(VampGlassPalette.inkSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: selection == choice ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection == choice ? VampGlassPalette.good : VampGlassPalette.inkTertiary)
            }
            .padding(.horizontal, VampTerminalDesign.space3)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(
                selection == choice ? VampGlassPalette.surfaceRaised : Color.clear,
                in: RoundedRectangle(cornerRadius: VampTerminalDesign.controlRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: VampTerminalDesign.controlRadius, style: .continuous)
                    .stroke(selection == choice ? VampGlassPalette.ruleStrong : VampGlassPalette.rule, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct TerminalSessionActivityView: View {
    @ObservedObject var chat: TerminalChatStore
    let title: String

    var body: some View {
        NavigationStack {
            Group {
                if chat.activityEvents.isEmpty {
                    ContentUnavailableView("No activity yet", systemImage: "clock")
                } else {
                    List(chat.activityEvents.reversed()) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.text)
                                .font(.system(.body, design: .rounded))
                            Text(event.date, style: .time)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Activity · \(title)")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Workspace / project layer

private struct VampWorkspaceCard: View {
    let workspace: RemoteWorkspace
    let isSelected: Bool
    let activeSessionCount: Int
    let onTap: () -> Void
    let onFavorite: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: VampTerminalDesign.space3) {
            Image(systemName: workspace.kind == .gitRepository ? "shippingbox" : "folder")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(VampGlassPalette.inkSecondary)
                .frame(width: 36, height: 36)
                .vampGlassSurface(.button, cornerRadius: VampTerminalDesign.controlRadius)

            VStack(alignment: .leading, spacing: VampTerminalDesign.space1) {
                HStack(spacing: VampTerminalDesign.space2) {
                    Text(workspace.name)
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(VampGlassPalette.ink)
                        .lineLimit(1)
                    if !workspace.isAvailable {
                        Text("UNAVAILABLE")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(VampGlassPalette.warning)
                    }
                }
                Text(workspace.path)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(VampGlassPalette.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: VampTerminalDesign.space2) {
                    if let gitInfo = workspace.gitInfo {
                        Label(gitInfo.branch ?? "Git", systemImage: "arrow.triangle.branch")
                        if gitInfo.isDirty { Text("· changes") }
                        if !gitInfo.projectHints.isEmpty { Text("· " + gitInfo.projectHints.prefix(2).joined(separator: " · ")) }
                    } else {
                        Text(workspace.kind == .home ? "Home folder" : "Folder")
                    }
                    if activeSessionCount > 0 { Text("· \(activeSessionCount) active") }
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(VampGlassPalette.inkTertiary)
            }

            Spacer(minLength: 0)
            VStack(spacing: VampTerminalDesign.space2) {
                Button(action: onFavorite) {
                    Image(systemName: workspace.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(workspace.isFavorite ? VampGlassPalette.ink : VampGlassPalette.inkSubtle)
                        .frame(width: VampTerminalDesign.minTapTarget, height: VampTerminalDesign.minTapTarget)
                }
                .buttonStyle(.plain)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VampGlassPalette.inkSubtle)
            }
        }
        .padding(VampTerminalDesign.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.largeCardRadius)
        .vampGlassOutline(
            cornerRadius: VampTerminalDesign.largeCardRadius,
            color: isSelected ? VampGlassPalette.ruleStrong : VampGlassPalette.rule
        )
        .contentShape(RoundedRectangle(cornerRadius: VampTerminalDesign.largeCardRadius, style: .continuous))
        .onTapGesture {
            guard workspace.isAvailable else { return }
            onTap()
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(workspace.isAvailable ? "Opens this workspace" : "Workspace unavailable")
        .opacity(workspace.isAvailable ? 1 : 0.62)
    }
}

struct VampWorkspaceChooserView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: VampWorkspaceStore
    let provider: VampAgentProvider
    let hostName: String
    let onStart: (RemoteWorkspace, ResumeMode, PersistenceMode) -> Void

    @State private var selectedWorkspaceID: UUID?
    @State private var resumeMode: ResumeMode = .new
    @State private var persistenceMode: PersistenceMode = .preserveWithTmux

    private var selectedWorkspace: RemoteWorkspace? {
        guard let selectedWorkspaceID else { return nil }
        return store.workspaces.first { $0.id == selectedWorkspaceID && $0.isAvailable }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VampTerminalDesign.space5) {
                    VStack(alignment: .leading, spacing: VampTerminalDesign.space1) {
                        Text("New \(provider.displayName) session")
                            .font(.system(size: 25, weight: .bold, design: .rounded))
                        Text(hostName + " · " + "Choose where this agent should start.")
                            .font(.subheadline)
                            .foregroundStyle(VampGlassPalette.inkSecondary)
                    }

                    sectionLabel("WORKSPACE")
                    if store.isLoading && store.workspaces.isEmpty {
                        ProgressView("Discovering projects on the Mac…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if store.workspaces.isEmpty {
                        emptyWorkspaceMessage
                    } else {
                        ForEach(store.workspaces) { workspace in
                            VampWorkspaceCard(
                                workspace: workspace,
                                isSelected: selectedWorkspaceID == workspace.id,
                                activeSessionCount: 0,
                                onTap: { selectedWorkspaceID = workspace.id },
                                onFavorite: { store.toggleFavorite(workspace.id) }
                            )
                        }
                    }

                    NavigationLink {
                            VampWorkspaceBrowserView(store: store) { workspace in
                            store.adopt(workspace)
                            selectedWorkspaceID = workspace.id
                            onStart(workspace, resumeMode, persistenceMode)
                        }
                    } label: {
                        Label("Browse Mac…", systemImage: "folder.badge.plus")
                            .font(.headline)
                            .foregroundStyle(VampGlassPalette.ink)
                            .frame(maxWidth: .infinity, minHeight: VampTerminalDesign.controlHeight)
                            .vampGlassSurface(.button, cornerRadius: VampTerminalDesign.controlRadius)
                            .vampGlassOutline(cornerRadius: VampTerminalDesign.controlRadius)
                    }
                    .buttonStyle(VampGlassPressStyle())

                    Button {
                        store.requestAdditionalFolder()
                    } label: {
                        HStack(spacing: VampTerminalDesign.space3) {
                            if store.isRequestingFolderAccess {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "macbook.and.iphone")
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Add Mac folder…")
                                    .font(.headline)
                                Text("A folder picker will open on (hostName)")
                                    .font(.caption)
                                    .foregroundStyle(VampGlassPalette.inkSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(VampGlassPalette.ink)
                        .frame(maxWidth: .infinity, minHeight: VampTerminalDesign.controlHeight, alignment: .leading)
                        .padding(.horizontal, VampTerminalDesign.space4)
                        .vampGlassSurface(.button, cornerRadius: VampTerminalDesign.controlRadius)
                        .vampGlassOutline(cornerRadius: VampTerminalDesign.controlRadius)
                    }
                    .buttonStyle(VampGlassPressStyle())
                    .disabled(store.isRequestingFolderAccess)
                    .accessibilityHint("Opens a folder chooser on the connected Mac")

                    if let selectedWorkspace {
                        VStack(alignment: .leading, spacing: VampTerminalDesign.space3) {
                            sectionLabel("SESSION")
                            Picker("Session", selection: $resumeMode) {
                                Text("New session").tag(ResumeMode.new)
                                Text("Resume previous").tag(ResumeMode.resumePrevious)
                            }
                            .pickerStyle(.segmented)
                            Toggle("Preserve session after disconnect", isOn: Binding(
                                get: { persistenceMode == .preserveWithTmux },
                                set: { persistenceMode = $0 ? .preserveWithTmux : .sessionOnly }
                            ))
                            .font(.subheadline)
                            Text("Start in: \(selectedWorkspace.path)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(VampGlassPalette.inkSecondary)
                                .lineLimit(2)
                        }
                    }

                }
                .padding(.horizontal, VampTerminalDesign.space5)
                .padding(.vertical, VampTerminalDesign.space5)
            }
            // A discovered Mac can contain dozens of projects. Keeping the
            // only launch action after that list made a selected workspace
            // appear to do nothing and required scrolling many screens before
            // a session could start. The CTA belongs to the sheet chrome and
            // remains reachable while the workspace list scrolls beneath it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: VampTerminalDesign.space2) {
                    if let selectedWorkspace {
                        Text(selectedWorkspace.name + " · " + selectedWorkspace.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(VampGlassPalette.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Choose a workspace to continue")
                            .font(.footnote)
                            .foregroundStyle(VampGlassPalette.inkSecondary)
                    }

                    Button {
                        guard let selectedWorkspace else { return }
                        onStart(selectedWorkspace, resumeMode, persistenceMode)
                        dismiss()
                    } label: {
                        Label("Start \(provider.displayName)", systemImage: "arrow.up.right")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity, minHeight: VampTerminalDesign.controlHeight)
                            .background(VampGlassPalette.ink, in: RoundedRectangle(cornerRadius: VampTerminalDesign.controlRadius, style: .continuous))
                    }
                    .buttonStyle(VampGlassPressStyle())
                    .disabled(selectedWorkspace == nil)
                    .opacity(selectedWorkspace == nil ? 0.45 : 1)
                    .accessibilityHint(selectedWorkspace == nil ? "Choose a workspace first" : "Starts the agent in the selected workspace")
                }
                .padding(.horizontal, VampTerminalDesign.space5)
                .padding(.top, VampTerminalDesign.space3)
                .padding(.bottom, VampTerminalDesign.space2)
                .background(VampGlassPalette.surfaceRaised)
                .overlay(alignment: .top) {
                    Rectangle().fill(VampGlassPalette.rule).frame(height: 0.5)
                }
            }
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .navigationTitle("Choose workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh workspaces")
                }
            }
        }
        .onAppear {
            store.activate()
            if selectedWorkspaceID == nil {
                selectedWorkspaceID = store.workspaces.first(where: { $0.isAvailable })?.id
            }
        }
        .onChange(of: store.workspaces) { _, workspaces in
            guard selectedWorkspaceID == nil else { return }
            selectedWorkspaceID = workspaces.first(where: { $0.isAvailable })?.id
        }
    }

    private var emptyWorkspaceMessage: some View {
        VStack(alignment: .leading, spacing: VampTerminalDesign.space2) {
            Text("No projects discovered yet")
                .font(.headline)
            Text(store.errorMessage ?? "Browse the Mac to choose a folder. The folder is never deleted when removed from recents.")
                .font(.subheadline)
                .foregroundStyle(VampGlassPalette.inkSecondary)
        }
        .padding(VampTerminalDesign.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.largeCardRadius)
        .vampGlassOutline(cornerRadius: VampTerminalDesign.largeCardRadius)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .tracking(1.4)
            .foregroundStyle(VampGlassPalette.inkTertiary)
    }
}

struct VampWorkspacesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: VampWorkspaceStore
    @ObservedObject var terminalWorkspace: TerminalWorkspaceViewModel
    let hostName: String
    let connectionLabel: String
    @State private var selectedWorkspace: RemoteWorkspace?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VampTerminalDesign.space5) {
                    VStack(alignment: .leading, spacing: VampTerminalDesign.space1) {
                        Text("Workspaces")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        HStack(spacing: VampTerminalDesign.space2) {
                            Circle().fill(VampGlassPalette.good).frame(width: 7, height: 7)
                            Text("\(hostName) · \(connectionLabel)")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(VampGlassPalette.inkSecondary)
                        }
                    }

                    Text("RECENT")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(VampGlassPalette.inkTertiary)

                    if store.workspaces.isEmpty && store.isLoading {
                        HStack(spacing: VampTerminalDesign.space3) {
                            ProgressView()
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Finding recent projects")
                                    .font(.headline)
                                Text("You can open Home or another location now.")
                                    .font(.subheadline)
                                    .foregroundStyle(VampGlassPalette.inkSecondary)
                            }
                        }
                        .padding(VampTerminalDesign.space4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.cardRadius)
                    } else {
                        ForEach(store.workspaces) { item in
                            VampWorkspaceCard(
                                workspace: item,
                                isSelected: false,
                                activeSessionCount: terminalWorkspace.tabs.filter { $0.workspaceID == item.id }.count,
                                onTap: { selectedWorkspace = item },
                                onFavorite: { store.toggleFavorite(item.id) }
                            )
                        }
                    }

                    if let error = store.errorMessage {
                        VStack(alignment: .leading, spacing: VampTerminalDesign.space3) {
                            Label("Projects unavailable", systemImage: "exclamationmark.triangle")
                                .font(.headline)
                            Text(error)
                                .font(.subheadline)
                                .foregroundStyle(VampGlassPalette.inkSecondary)
                            Button("Try again") { store.refresh() }
                                .buttonStyle(.bordered)
                        }
                        .padding(VampTerminalDesign.space4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.cardRadius)
                    }

                    Text("OTHER LOCATIONS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(VampGlassPalette.inkTertiary)
                    ForEach(store.roots) { root in
                        NavigationLink {
                            VampWorkspaceBrowserView(store: store, initialPath: root.path) { workspace in
                                store.adopt(workspace)
                                selectedWorkspace = workspace
                            }
                        } label: {
                            HStack {
                                Image(systemName: root.name == "Home" ? "house" : "folder")
                                    .frame(width: 28)
                                Text(root.name)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(VampGlassPalette.inkSubtle)
                            }
                            .font(.headline)
                            .foregroundStyle(VampGlassPalette.ink)
                            .padding(.horizontal, VampTerminalDesign.space4)
                            .frame(minHeight: VampTerminalDesign.controlHeight)
                            .vampGlassSurface(.button, cornerRadius: VampTerminalDesign.controlRadius)
                            .vampGlassOutline(cornerRadius: VampTerminalDesign.controlRadius)
                        }
                        .buttonStyle(VampGlassPressStyle())
                    }
                }
                .padding(.horizontal, VampTerminalDesign.space5)
                .padding(.vertical, VampTerminalDesign.space5)
            }
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .navigationTitle("Workspaces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
        .fullScreenCover(item: $selectedWorkspace) { item in
            VampWorkspaceDetailView(
                workspace: item,
                store: store,
                terminalWorkspace: terminalWorkspace,
                hostName: hostName,
                onSessionStarted: {
                    selectedWorkspace = nil
                    dismiss()
                }
            )
        }
        .onAppear { store.activate() }
    }
}

private struct VampWorkspaceDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let workspace: RemoteWorkspace
    @ObservedObject var store: VampWorkspaceStore
    @ObservedObject var terminalWorkspace: TerminalWorkspaceViewModel
    let hostName: String
    let onSessionStarted: () -> Void
    @State private var selectedAgent: VampAgentProvider?

    private var activeTabs: [TerminalWorkspaceViewModel.Tab] {
        terminalWorkspace.tabs.filter { $0.workspaceID == workspace.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VampTerminalDesign.space5) {
                VStack(alignment: .leading, spacing: VampTerminalDesign.space2) {
                    Text(workspace.name)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(workspace.path)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(VampGlassPalette.inkSecondary)
                        .textSelection(.enabled)
                    if let git = workspace.gitInfo {
                        Label("Git · \(git.branch ?? "branch unknown")\(git.isDirty ? " · changes" : " · clean")", systemImage: "arrow.triangle.branch")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(VampGlassPalette.inkTertiary)
                    }
                }

                VStack(alignment: .leading, spacing: VampTerminalDesign.space3) {
                    Text("SESSIONS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(VampGlassPalette.inkTertiary)
                    if activeTabs.isEmpty {
                        Text("No active sessions in this workspace.")
                            .font(.subheadline)
                            .foregroundStyle(VampGlassPalette.inkSecondary)
                    } else {
                        ForEach(activeTabs) { tab in
                            HStack(spacing: VampTerminalDesign.space3) {
                                Circle().fill(VampGlassPalette.good).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: VampTerminalDesign.space1) {
                                    Text(tab.title).font(.headline)
                                    Text(tab.stateLabel)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(VampGlassPalette.inkSecondary)
                                }
                                Spacer()
                            }
                            .padding(VampTerminalDesign.space3)
                            .vampGlassSurface(.button, cornerRadius: VampTerminalDesign.controlRadius)
                            .vampGlassOutline(cornerRadius: VampTerminalDesign.controlRadius)
                        }
                    }
                }

                Menu {
                    ForEach(VampAgentProvider.allCases) { provider in
                        Button {
                            selectedAgent = provider
                        } label: {
                            if let assetName = provider.assetName {
                                Label(provider.displayName, image: assetName)
                            } else {
                                Label(provider.displayName, systemImage: provider.fallbackSystemImage)
                            }
                        }
                    }
                } label: {
                    Label("New agent session", systemImage: "plus")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: VampTerminalDesign.controlHeight)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: VampTerminalDesign.controlRadius, style: .continuous))
                }
                .buttonStyle(VampGlassPressStyle())

                Button {
                    // Close both nested workspace sheets before mounting the
                    // terminal. SwiftTerm may become first responder as soon
                    // as its PTY is ready; creating it while the workspace
                    // sheet is still presented leaves the keyboard attached
                    // to a hidden terminal and visually mixes both screens.
                    dismiss()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 180_000_000)
                        onSessionStarted()
                        try? await Task.sleep(nanoseconds: 180_000_000)
                        _ = terminalWorkspace.createTab(title: "Shell · \(workspace.name)", workspace: workspace)
                    }
                } label: {
                    Label("Open shell here", systemImage: "terminal")
                        .font(.headline)
                        .foregroundStyle(VampGlassPalette.ink)
                        .frame(maxWidth: .infinity, minHeight: VampTerminalDesign.controlHeight)
                        .vampGlassSurface(.button, cornerRadius: VampTerminalDesign.controlRadius)
                        .vampGlassOutline(cornerRadius: VampTerminalDesign.controlRadius)
                }
                .buttonStyle(VampGlassPressStyle())
            }
            .padding(.horizontal, VampTerminalDesign.space5)
            .padding(.vertical, VampTerminalDesign.space5)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .navigationTitle("Workspace")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $selectedAgent) { provider in
            VampWorkspaceChooserView(store: store, provider: provider, hostName: hostName) { chosen, resumeMode, persistenceMode in
                let launch = provider.launchConfiguration(
                    resumeMode: resumeMode,
                    persistenceMode: persistenceMode,
                    workspaceID: chosen.id
                )
                selectedAgent = nil
                dismiss()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    onSessionStarted()
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    _ = terminalWorkspace.createTab(
                        title: provider.sessionDisplayName,
                        provider: provider,
                        workspace: chosen,
                        resumeMode: resumeMode,
                        persistenceMode: persistenceMode,
                        launchExecutable: launch.executable,
                        launchArguments: launch.arguments
                    )
                }
            }
        }
    }
}

private struct VampWorkspaceBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: VampWorkspaceStore
    var initialPath: String?
    let onSelect: (RemoteWorkspace) -> Void

    init(
        store: VampWorkspaceStore,
        initialPath: String? = nil,
        onSelect: @escaping (RemoteWorkspace) -> Void
    ) {
        self.store = store
        self.initialPath = initialPath
        self.onSelect = onSelect
    }

    var body: some View {
        List {
            Section {
                if store.isBrowsing {
                    ProgressView("Reading Mac folder…")
                } else if let error = store.errorMessage {
                    ContentUnavailableView(
                        "Folder unavailable",
                        systemImage: "exclamationmark.folder",
                        description: Text(error)
                    )
                } else if store.directoryEntries.isEmpty {
                    ContentUnavailableView(
                        "No folders here",
                        systemImage: "folder",
                        description: Text("Choose another Mac location or go up one level.")
                    )
                }
                ForEach(store.directoryEntries) { entry in
                    HStack(spacing: VampTerminalDesign.space3) {
                        Button {
                            if let workspace = store.workspace(for: entry) {
                                onSelect(workspace)
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: VampTerminalDesign.space3) {
                                Image(systemName: entry.isGitRepository ? "shippingbox" : "folder")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name).foregroundStyle(.primary)
                                    Text(entry.path)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer(minLength: 0)
                        Button { store.browse(path: entry.path) } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text(store.browsePath ?? "Mac folders")
                    .font(.system(size: 11, design: .monospaced))
                    .textCase(nil)
            } footer: {
                Text("Tap a folder to use it as the agent workspace. Use the chevron to browse deeper.")
            }
        }
        .navigationTitle("Browse Mac")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    store.browseParent()
                } label: {
                    Label("Up", systemImage: "chevron.up")
                }
                .disabled(store.browsePath == nil || URL(fileURLWithPath: store.browsePath ?? "").deletingLastPathComponent().path == store.browsePath)
            }
        }
        .onAppear {
            if let initialPath {
                store.browse(path: initialPath)
            } else if let root = store.roots.first(where: { $0.name == "Home" }) ?? store.roots.first {
                store.browse(path: root.path)
            }
        }
    }
}

@MainActor private extension TerminalWorkspaceViewModel.Tab {
    var stateLabel: String {
        switch state {
        case .idle: return "Waiting"
        case .opening: return "Opening"
        case .open: return "Running"
        case .closed: return "Stopped"
        }
    }
}

private struct TerminalChatReadyCard: View {
    let title: String
    let onOpenTerminal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: VampTerminalDesign.space3) {
            HStack(spacing: VampTerminalDesign.space2) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(VampGlassPalette.good)
                Text("Ready")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(VampGlassPalette.inkSecondary)
            }
            Text(title + " is ready")
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .foregroundStyle(VampGlassPalette.ink)
            Text(title == "Shell"
                 ? "Type a command below, or open Terminal for direct shell control."
                 : "Send a message below to start this session, or open Terminal for direct control.")
                .font(.subheadline)
                .foregroundStyle(VampGlassPalette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onOpenTerminal) {
                Label("Open Terminal", systemImage: "terminal")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, VampTerminalDesign.space3)
                    .frame(minHeight: VampTerminalDesign.minTapTarget)
                    .background(VampGlassPalette.ink, in: RoundedRectangle(cornerRadius: VampTerminalDesign.controlRadius, style: .continuous))
            }
            .buttonStyle(VampGlassPressStyle())
        }
        .padding(VampTerminalDesign.space5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.largeCardRadius)
        .vampGlassOutline(cornerRadius: VampTerminalDesign.largeCardRadius, color: VampGlassPalette.good.opacity(0.24))
        .accessibilityElement(children: .contain)
    }
}

private struct TerminalChatBlockView: View {
    let block: TerminalChatStore.Block
    let provider: VampAgentProvider?

    var body: some View {
        content
            .contextMenu {
                Button {
                    UIPasteboard.general.string = block.text
                } label: {
                    Label("Copy message", systemImage: "doc.on.doc")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch block.role {
        case .system:
            systemBlock
        case .command:
            commandBlock
        case .output, .success, .warning, .error, .progress:
            outputBlock
        }
    }

    private var systemBlock: some View {
        VStack(alignment: .leading, spacing: VampTerminalDesign.space2) {
            HStack(spacing: VampTerminalDesign.space2) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(block.title ?? "System")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VampGlassPalette.inkTertiary)
                if block.isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(VampGlassPalette.warning)
                }
            }
            Text(block.text)
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(VampGlassPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var commandBlock: some View {
        HStack(alignment: .bottom, spacing: VampTerminalDesign.space2) {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: VampTerminalDesign.space2) {
                Text(block.title ?? "You")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(VampGlassPalette.inkSecondary)
            Text(block.text)
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(VampGlassPalette.ink)
                .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, VampTerminalDesign.space4)
                    .padding(.vertical, VampTerminalDesign.space3)
                    .background(
                        Color.primary.opacity(0.13),
                        in: RoundedRectangle(cornerRadius: 19, style: .continuous)
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var outputBlock: some View {
        HStack(alignment: .top, spacing: VampTerminalDesign.space3) {
            ZStack {
                Circle()
                    .fill((provider?.accent ?? VampGlassPalette.inkSecondary).opacity(0.16))
                Image(systemName: provider?.fallbackSystemImage ?? iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(provider?.accent ?? statusColor)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: VampTerminalDesign.space2) {
            HStack(spacing: VampTerminalDesign.space2) {
                    Text(block.title ?? provider?.sessionDisplayName ?? "Response")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(VampGlassPalette.inkSecondary)
                if block.isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(provider?.accent ?? statusColor)
                }
            }

            TerminalChatContentView(
                // Chat body text uses the adaptive label ink, never the
                // provider's terminalText: that cream/coral is tuned for the
                // dark terminal canvas and is nearly invisible on the light
                // chat background. Provider identity stays on the avatar + caret.
                text: block.text,
                color: VampGlassPalette.ink,
                usesProseTypography: provider != nil,
                isStreaming: block.isStreaming,
                caretColor: provider?.accent ?? statusColor
            )
            }
        }
        .padding(.vertical, VampTerminalDesign.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var iconName: String {
        switch block.role {
        case .output: return "chevron.right"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .progress: return "arrow.triangle.2.circlepath"
        case .system, .command: return "circle"
        }
    }

    private var statusColor: Color {
        switch block.role {
        case .system: return VampGlassPalette.inkSecondary
        case .command: return provider?.accent ?? VampGlassPalette.ink
        case .output: return provider?.accent ?? VampGlassPalette.inkSecondary
        case .success: return VampGlassPalette.good
        case .warning, .progress: return VampGlassPalette.warning
        case .error: return VampGlassPalette.bad
        }
    }
}

private struct TerminalChatContentView: View {
    let text: String
    let color: Color
    let usesProseTypography: Bool
    var isStreaming: Bool = false
    var caretColor: Color = VampGlassPalette.ink

    var body: some View {
        if usesProseTypography {
            // An agent reply is Markdown, not a terminal pane. Split fenced code
            // into copyable monospace cards and pipe tables into aligned grids,
            // then render the rest as inline-styled prose. The whole reply flows
            // in the main chat scroll (no nested vertical scroll that would
            // fight the outer scroll for the same drag).
            VStack(alignment: .leading, spacing: VampTerminalDesign.space3) {
                ForEach(VampChatMarkdown.segments(from: text)) { segment in
                    switch segment.kind {
                    case .code(let code):
                        VampCodeBlockCard(code: code)
                    case .table(let rows):
                        VampChatTableView(rows: rows, color: color)
                    case .prose(let prose):
                        VampMarkdownProseView(text: prose, color: color)
                    }
                }
                if isStreaming { VampStreamingCaret(color: caretColor) }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Plain shell output is not Markdown. Keep it monospace and let it
            // flow at natural height — a nested scroll region here trapped the
            // drag that belongs to the chat feed.
            VStack(alignment: .leading, spacing: VampTerminalDesign.space2) {
                Text(text)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(color)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if isStreaming { VampStreamingCaret(color: caretColor) }
            }
        }
    }
}

/// A trailing block cursor that blinks while a block is still streaming, so a
/// long reply reads as alive rather than frozen behind a tiny title spinner.
private struct VampStreamingCaret: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(color)
            .frame(width: 8, height: 15)
            .opacity(lit ? 0.95 : 0.18)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    lit = false
                }
            }
            .accessibilityHidden(true)
    }
}

/// A copyable, horizontally scrollable code block. Language highlighting is
/// intentionally out of scope; the win is monospace alignment, a real surface,
/// and a Copy button on a phone.
private struct VampCodeBlockCard: View {
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: VampTerminalDesign.space2) {
                Text("CODE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(VampGlassPalette.inkTertiary)
                Spacer(minLength: 0)
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(copied ? VampGlassPalette.good : VampGlassPalette.inkSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .padding(.horizontal, VampTerminalDesign.space3)
            .padding(.vertical, VampTerminalDesign.space2)

            Rectangle().fill(VampGlassPalette.rule).frame(height: 0.5)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(VampGlassPalette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(VampTerminalDesign.space3)
            }
        }
        .background(
            Color.black.opacity(0.30),
            in: RoundedRectangle(cornerRadius: VampTerminalDesign.controlRadius, style: .continuous)
        )
        .vampGlassOutline(cornerRadius: VampTerminalDesign.controlRadius)
    }

    private func copy() {
        UIPasteboard.general.string = code
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeOut(duration: 0.25)) { copied = false }
        }
    }
}

/// An aligned pipe-table grid. Flows at natural height (no inner vertical
/// scroll) and scrolls horizontally when a table is wider than the phone.
private struct VampChatTableView: View {
    let rows: [[String]]
    let color: Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .top, spacing: VampTerminalDesign.space3) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                            Text(value.isEmpty ? " " : value)
                                .font(.system(size: 12, weight: index == 0 ? .semibold : .regular, design: .monospaced))
                                .foregroundStyle(color.opacity(index == 1 ? 0.7 : 1))
                                .frame(minWidth: 80, alignment: .leading)
                        }
                    }
                    .padding(.vertical, VampTerminalDesign.space2)
                    if index < rows.count - 1 {
                        Rectangle().fill(VampGlassPalette.rule).frame(height: 0.5)
                    }
                }
            }
            .padding(.horizontal, VampTerminalDesign.space1)
        }
    }
}

/// Line-oriented Markdown block renderer: headings, bullet/numbered lists,
/// blockquotes, and paragraphs, each with inline emphasis/code/links. It is
/// deliberately not a full CommonMark engine — fenced code and tables are
/// pulled out upstream by `VampChatMarkdown.segments`.
private struct VampMarkdownProseView: View {
    let text: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: VampTerminalDesign.space1) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                row(for: line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(for line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Color.clear.frame(height: 3)
        } else if let heading = VampChatMarkdown.heading(trimmed) {
            Text(VampChatMarkdown.inline(heading.text))
                .font(.system(size: heading.size, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, VampTerminalDesign.space1)
        } else if let item = VampChatMarkdown.listItem(trimmed) {
            HStack(alignment: .firstTextBaseline, spacing: VampTerminalDesign.space2) {
                Text(item.marker)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(color.opacity(0.7))
                    .frame(minWidth: 18, alignment: .trailing)
                Text(VampChatMarkdown.inline(item.text))
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if trimmed.hasPrefix(">") {
            Text(VampChatMarkdown.inline(String(trimmed.drop(while: { $0 == ">" || $0 == " " }))))
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(color.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, VampTerminalDesign.space3)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(color.opacity(0.3)).frame(width: 2)
                }
        } else {
            Text(VampChatMarkdown.inline(line))
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(color)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Splits an agent reply into fenced-code, table, and prose segments, and
/// carries the small inline/block Markdown helpers used to render prose.
enum VampChatMarkdown {
    struct Segment: Identifiable {
        let id = UUID()
        let kind: Kind
    }
    enum Kind {
        case prose(String)
        case code(String)
        case table([[String]])
    }

    static func segments(from text: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [String] = []
        var code: [String] = []
        var inCode = false

        func flushProse() {
            guard !prose.isEmpty else { return }
            let joined = prose.joined(separator: "\n")
            prose.removeAll()
            let rows = tableRows(joined)
            if isTable(rows) {
                segments.append(Segment(kind: .table(rows)))
            } else if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(Segment(kind: .prose(joined)))
            }
        }

        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    segments.append(Segment(kind: .code(code.joined(separator: "\n"))))
                    code.removeAll()
                    inCode = false
                } else {
                    flushProse()
                    inCode = true
                }
                continue
            }
            if inCode { code.append(line) } else { prose.append(line) }
        }
        if inCode, !code.isEmpty {
            // Unterminated fence: still surface the code captured so far.
            segments.append(Segment(kind: .code(code.joined(separator: "\n"))))
        }
        flushProse()
        return segments.isEmpty ? [Segment(kind: .prose(text))] : segments
    }

    static func inline(_ value: String) -> AttributedString {
        (try? AttributedString(
            markdown: value,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(value)
    }

    static func heading(_ line: String) -> (text: String, size: CGFloat)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard hashes <= 6, line.dropFirst(hashes).first == " " else { return nil }
        let content = String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
        let size: CGFloat = hashes <= 1 ? 20 : hashes == 2 ? 18 : 16
        return (content, size)
    }

    static func listItem(_ line: String) -> (marker: String, text: String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return ("•", String(line.dropFirst(2)))
        }
        let digits = line.prefix(while: { $0.isNumber })
        if !digits.isEmpty {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return (digits + ".", String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    static func tableRows(_ text: String) -> [[String]] {
        text
            .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "|", with: "").isEmpty }
            .map { line in
                line.split(separator: "|", omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
            }
    }

    static func isTable(_ rows: [[String]]) -> Bool {
        guard rows.count >= 2 else { return false }
        return rows.allSatisfy { $0.count >= 2 }
            && rows[1].allSatisfy { $0.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " } }
    }
}

private struct TerminalChatComposer: View {
    @Binding var draft: String
    var composerFocused: FocusState<Bool>.Binding
    let provider: VampAgentProvider?
    let isEnabled: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onOpenTerminal: () -> Void
    let onPaste: () -> Void
    let onSendClipboardToHost: () -> Void
    let onRequestClipboardFromHost: () -> Void

    @StateObject private var speech = VampSpeechTranscriber()
    @State private var dictationPrefix = ""
    @State private var showingSpeechError = false

    var body: some View {
        HStack(alignment: .center, spacing: VampTerminalDesign.space2) {
            Button(action: onOpenTerminal) {
                Image(systemName: "terminal")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: VampTerminalDesign.minTapTarget, height: VampTerminalDesign.minTapTarget)
                    .background(VampGlassPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(VampGlassPalette.inkSecondary)
            .accessibilityLabel("Open Terminal")

            TextField(
                provider.map { "Message \($0.sessionDisplayName)…" } ?? "Type a shell command…",
                text: $draft,
                axis: .vertical
            )
                .accessibilityIdentifier("vamp.chat.composer")
                .focused(composerFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .lineLimit(1...4)
                .font(.system(size: 15, weight: .regular, design: provider == nil ? .monospaced : .rounded))
                .foregroundStyle(VampGlassPalette.ink)
                .tint(VampGlassPalette.ink)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        guard isEnabled else { return }
                        composerFocused.wrappedValue = true
                    }
                )
                .onSubmit(onSend)
                .disabled(!isEnabled)

            Menu {
                Button(action: onPaste) {
                    Label("Paste from iPhone", systemImage: "doc.on.clipboard")
                }
                Button(action: onSendClipboardToHost) {
                    Label("Send iPhone clipboard to Mac", systemImage: "arrow.up.doc")
                }
                Button(action: onRequestClipboardFromHost) {
                    Label("Get Mac clipboard", systemImage: "arrow.down.doc")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: VampTerminalDesign.minTapTarget, height: VampTerminalDesign.minTapTarget)
                    .background(VampGlassPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(VampGlassPalette.inkSecondary)
            .accessibilityLabel("Command and clipboard actions")

            Button(action: performPrimaryAction) {
                Image(systemName: primaryActionSymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(primaryActionForeground)
                    .frame(width: VampTerminalDesign.minTapTarget, height: VampTerminalDesign.minTapTarget)
                    .background(primaryActionBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(VampGlassPressStyle())
            .disabled(!isEnabled || (!speech.isRecording && hasDraft && !canSend))
            .accessibilityLabel(primaryActionAccessibilityLabel)
        }
        .padding(.horizontal, VampTerminalDesign.space2)
        .padding(.vertical, VampTerminalDesign.space2)
        .frame(minHeight: 60)
        .vampGlassSurface(.field, cornerRadius: 18)
        .vampGlassOutline(cornerRadius: 18, color: VampGlassPalette.ruleStrong)
        .padding(.horizontal, VampTerminalDesign.space3)
        .padding(.vertical, VampTerminalDesign.space2)
        .onChange(of: speech.errorMessage) { _, message in
            showingSpeechError = message != nil
        }
        .alert("Dictation unavailable", isPresented: $showingSpeechError) {
            Button("OK") { speech.errorMessage = nil }
        } message: {
            Text(speech.errorMessage ?? "Check microphone and Speech Recognition access in Settings.")
        }
        .onDisappear { speech.stop() }
    }

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var primaryActionSymbol: String {
        if speech.isRecording { return "waveform" }
        return hasDraft ? "arrow.up" : "mic.fill"
    }

    private var primaryActionForeground: Color {
        if speech.isRecording { return .white }
        return Color.white
    }

    private var primaryActionBackground: Color {
        if speech.isRecording { return VampGlassPalette.bad }
        if hasDraft && canSend { return VampGlassPalette.ink }
        return VampGlassPalette.ink.opacity(0.22)
    }

    private var primaryActionAccessibilityLabel: String {
        if speech.isRecording { return "Stop dictation" }
        return hasDraft ? "Send message" : "Dictate message"
    }

    private func performPrimaryAction() {
        if speech.isRecording {
            speech.stop()
        } else if hasDraft {
            onSend()
        } else {
            dictationPrefix = draft
            speech.start { transcript in
                let separator = dictationPrefix.isEmpty || transcript.isEmpty ? "" : " "
                draft = dictationPrefix + separator + transcript
            }
        }
    }
}

@MainActor
private final class VampSpeechTranscriber: ObservableObject {
    @Published var isRecording = false
    @Published var errorMessage: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start(onTranscript: @escaping (String) -> Void) {
        guard !isRecording else { return }
        errorMessage = nil
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else {
                    self.errorMessage = "Allow Speech Recognition to dictate messages."
                    return
                }
                AVAudioApplication.requestRecordPermission { allowed in
                    DispatchQueue.main.async {
                        guard allowed else {
                            self.errorMessage = "Allow microphone access to dictate messages."
                            return
                        }
                        self.beginRecognition(onTranscript: onTranscript)
                    }
                }
            }
        }
    }

    func stop() {
        guard isRecording || task != nil else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func beginRecognition(onTranscript: @escaping (String) -> Void) {
        stop()
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech Recognition is not available right now."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request

            let input = audioEngine.inputNode
            let format = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                self.request = nil
                errorMessage = "No microphone input is available. Connect a microphone and try again."
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                return
            }
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
                request.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let result {
                        onTranscript(result.bestTranscription.formattedString)
                        if result.isFinal { self.stop() }
                    }
                    if let error {
                        self.errorMessage = error.localizedDescription
                        self.stop()
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            stop()
        }
    }
}
