import Foundation

// MARK: - Remote workspaces

/// The kind of host-side location represented by a workspace. These values are
/// deliberately small and stable because workspaces are persisted by clients.
public enum WorkspaceKind: String, Codable, Hashable, Sendable {
    case gitRepository
    case folder
    case home
}

public struct GitWorkspaceInfo: Codable, Hashable, Sendable {
    public var branch: String?
    public var isDirty: Bool
    public var remoteURL: String?
    public var ahead: Int?
    public var behind: Int?
    public var projectHints: [String]

    public init(
        branch: String? = nil,
        isDirty: Bool = false,
        remoteURL: String? = nil,
        ahead: Int? = nil,
        behind: Int? = nil,
        projectHints: [String] = []
    ) {
        self.branch = branch
        self.isDirty = isDirty
        self.remoteURL = remoteURL
        self.ahead = ahead
        self.behind = behind
        self.projectHints = projectHints
    }
}

/// A host-backed project or directory. The path is canonicalized by the host;
/// clients must never assume that an iOS-provided path is trusted.
public struct RemoteWorkspace: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var hostID: UUID
    public var name: String
    public var path: String
    public var kind: WorkspaceKind
    public var gitInfo: GitWorkspaceInfo?
    public var lastOpenedAt: Date?
    public var isFavorite: Bool
    public var isAvailable: Bool

    public init(
        id: UUID = UUID(),
        hostID: UUID,
        name: String,
        path: String,
        kind: WorkspaceKind,
        gitInfo: GitWorkspaceInfo? = nil,
        lastOpenedAt: Date? = nil,
        isFavorite: Bool = false,
        isAvailable: Bool = true
    ) {
        self.id = id
        self.hostID = hostID
        self.name = name
        self.path = path
        self.kind = kind
        self.gitInfo = gitInfo
        self.lastOpenedAt = lastOpenedAt
        self.isFavorite = isFavorite
        self.isAvailable = isAvailable
    }
}

public struct WorkspaceBrowseRoot: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let path: String
    public let isAvailable: Bool

    public init(name: String, path: String, isAvailable: Bool = true) {
        self.id = path
        self.name = name
        self.path = path
        self.isAvailable = isAvailable
    }
}

public struct WorkspaceDirectoryEntry: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let isReadable: Bool
    public let isGitRepository: Bool
    public let projectHints: [String]

    public init(
        name: String,
        path: String,
        isDirectory: Bool = true,
        isReadable: Bool = true,
        isGitRepository: Bool = false,
        projectHints: [String] = []
    ) {
        self.id = path
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isReadable = isReadable
        self.isGitRepository = isGitRepository
        self.projectHints = projectHints
    }
}

public struct WorkspaceListRequestMessage: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let requestID: UUID
    public let refresh: Bool

    public init(sessionID: UUID, requestID: UUID = UUID(), refresh: Bool = false) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.refresh = refresh
    }
}

public struct WorkspaceListResponseMessage: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let requestID: UUID
    public let hostID: UUID
    public let workspaces: [RemoteWorkspace]
    public let roots: [WorkspaceBrowseRoot]
    public let errorMessage: String?

    public init(
        sessionID: UUID,
        requestID: UUID,
        hostID: UUID,
        workspaces: [RemoteWorkspace] = [],
        roots: [WorkspaceBrowseRoot] = [],
        errorMessage: String? = nil
    ) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.hostID = hostID
        self.workspaces = workspaces
        self.roots = roots
        self.errorMessage = errorMessage
    }
}

public struct WorkspaceDirectoryRequestMessage: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let requestID: UUID
    public let path: String

    public init(sessionID: UUID, requestID: UUID = UUID(), path: String) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.path = path
    }
}

public struct WorkspaceDirectoryResponseMessage: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let requestID: UUID
    public let path: String
    public let entries: [WorkspaceDirectoryEntry]
    public let errorMessage: String?

    public init(
        sessionID: UUID,
        requestID: UUID,
        path: String,
        entries: [WorkspaceDirectoryEntry] = [],
        errorMessage: String? = nil
    ) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.path = path
        self.entries = entries
        self.errorMessage = errorMessage
    }
}

/// Client request to let the Mac owner expose one additional workspace root.
/// The client never supplies a path: selection happens in a trusted native
/// NSOpenPanel on the host and is persisted there as a security-scoped bookmark.
public struct WorkspaceAccessRequestMessage: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let requestID: UUID

    public init(sessionID: UUID, requestID: UUID = UUID()) {
        self.sessionID = sessionID
        self.requestID = requestID
    }
}

public struct WorkspaceAccessResponseMessage: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let requestID: UUID
    public let approved: Bool
    public let errorMessage: String?

    public init(
        sessionID: UUID,
        requestID: UUID,
        approved: Bool,
        errorMessage: String? = nil
    ) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.approved = approved
        self.errorMessage = errorMessage
    }
}

public enum ResumeMode: String, Codable, Hashable, Sendable {
    case new
    case resumePrevious
}

public enum PersistenceMode: String, Codable, Hashable, Sendable {
    case sessionOnly
    case preserveWithTmux
}

public struct SessionLaunchRequest: Codable, Hashable, Sendable {
    public let hostID: UUID
    public let workspaceID: UUID
    public let workingDirectory: String
    public let agent: String
    public let resumeMode: ResumeMode
    public let persistenceMode: PersistenceMode

    public init(
        hostID: UUID,
        workspaceID: UUID,
        workingDirectory: String,
        agent: String,
        resumeMode: ResumeMode = .new,
        persistenceMode: PersistenceMode = .sessionOnly
    ) {
        self.hostID = hostID
        self.workspaceID = workspaceID
        self.workingDirectory = workingDirectory
        self.agent = agent
        self.resumeMode = resumeMode
        self.persistenceMode = persistenceMode
    }
}

// MARK: - Terminal Mode
//
// Bidirectional PTY-backed shell over the existing authenticated WebRTC data
// channel. The client opens a session, streams keystrokes as `TerminalInput`,
// receives `TerminalOutput` chunks (raw bytes as written by the shell), and
// resizes the PTY window via `TerminalResize`. `TerminalClose` tears down.
//
// Security: all messages travel the same authenticated + anti-replay envelope
// that gates input commands. The host enforces a bounded number of terminals
// per session (no fan-out, no remote forwarding) and applies hard byte/rate caps.

/// Sent by the client to open a new PTY shell on the host.
public struct TerminalOpenMessage: Codable, Hashable, Sendable {
    public let sessionID: UUID
    /// Stable identifier the client chooses for this terminal channel. Lets
    /// future versions multiplex multiple terminals over one session.
    public let terminalID: UUID
    /// Initial PTY window size (columns x rows in character cells).
    public let cols: UInt16
    public let rows: UInt16
    /// Suggested $TERM value; host falls back to `xterm-256color` if absent.
    public let term: String?
    /// Optional one-line command to run immediately after the login shell is
    /// created. This is intentionally a shell command rather than a process
    /// identifier: tmux/screen can reattach an existing long-lived session,
    /// which is the portable way to hand an in-progress agent or terminal
    /// workflow from Mac Terminal to Vamp Terminal.
    public let startupCommand: String?
    /// Stable workspace identity selected by the client. The host validates
    /// the path independently before applying it to the child PTY.
    public let workspaceID: UUID?
    /// Canonical host-side working directory for this terminal. This is not a
    /// shell command and is never written into the visible terminal transcript.
    public let workingDirectory: String?
    /// Optional executable to launch directly after changing to the workspace.
    /// When present, the host resolves this name through its own PATH and
    /// execs it without first echoing a shell bootstrap command into the PTY.
    public let launchExecutable: String?
    /// Arguments for `launchExecutable`. The host applies its own bounds and
    /// executable validation before starting the child process.
    public let launchArguments: [String]

    /// Bounds the command launcher payload without changing the existing PTY
    /// input limit. Commands are still subject to the authenticated terminal
    /// channel and are never persisted by the host.
    public static let maxStartupCommandLength = 2_048

    public init(
        sessionID: UUID,
        terminalID: UUID,
        cols: UInt16,
        rows: UInt16,
        term: String? = "xterm-256color",
        startupCommand: String? = nil,
        workspaceID: UUID? = nil,
        workingDirectory: String? = nil,
        launchExecutable: String? = nil,
        launchArguments: [String] = []
    ) {
        self.sessionID = sessionID
        self.terminalID = terminalID
        self.cols = cols
        self.rows = rows
        self.term = term
        if let startupCommand {
            let oneLine = startupCommand
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.startupCommand = oneLine.isEmpty
                ? nil
                : String(oneLine.prefix(Self.maxStartupCommandLength))
        } else {
            self.startupCommand = nil
        }
        if let workingDirectory {
            let normalized = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            self.workingDirectory = normalized.isEmpty ? nil : String(normalized.prefix(4_096))
        } else {
            self.workingDirectory = nil
        }
        self.workspaceID = workspaceID
        if let launchExecutable {
            let normalizedExecutable = launchExecutable.trimmingCharacters(in: .whitespacesAndNewlines)
            self.launchExecutable = normalizedExecutable.isEmpty ? nil : String(normalizedExecutable.prefix(128))
        } else {
            self.launchExecutable = nil
        }
        self.launchArguments = Array(launchArguments.prefix(32)).map { String($0.prefix(512)) }
    }
}

/// Sent by the host after a PTY has been created successfully. This explicit
/// acknowledgement lets a tab become interactive without waiting for shell
/// startup output (which can be delayed by a user's shell profile).
public struct TerminalReadyMessage: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let terminalID: UUID
    public let cols: UInt16
    public let rows: UInt16
    /// True when this ready acknowledges a REOPEN of an existing PTY (reattach
    /// after reconnect). The client uses it to keep its sequence baseline —
    /// a fresh PTY restarts sequences at 0 and would otherwise be mistaken
    /// for stale output.
    public let isReopen: Bool

    public init(sessionID: UUID, terminalID: UUID, cols: UInt16, rows: UInt16, isReopen: Bool = false) {
        self.sessionID = sessionID
        self.terminalID = terminalID
        self.cols = cols
        self.rows = rows
        self.isReopen = isReopen
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, terminalID, cols, rows, isReopen
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        terminalID = try container.decode(UUID.self, forKey: .terminalID)
        cols = try container.decode(UInt16.self, forKey: .cols)
        rows = try container.decode(UInt16.self, forKey: .rows)
        // Older hosts/clients predate this field; treat missing as fresh open.
        isReopen = try container.decodeIfPresent(Bool.self, forKey: .isReopen) ?? false
    }
}

/// Stdin chunk from the client to the host PTY.
public struct TerminalInputMessage: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let terminalID: UUID
    /// Raw bytes to write to the PTY master. UTF-8 keystrokes plus escape
    /// sequences (arrows, F-keys, etc.).
    public let data: Data

    /// 16 KB cap per chunk — typical keystroke is <8 bytes; paste of a whole
    /// page is comfortably under this. Anything larger is dropped.
    public static let maxChunkBytes = 16_384

    public init(sessionID: UUID, terminalID: UUID, data: Data) {
        self.sessionID = sessionID
        self.terminalID = terminalID
        self.data = data
    }
}

/// Stdout/stderr chunk from the host PTY to the client.
public struct TerminalOutputMessage: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let terminalID: UUID
    /// Raw bytes read from the PTY master. May contain VT/ANSI escape
    /// sequences; the client renders them through its terminal emulator.
    public let data: Data
    /// Monotonic sequence number assigned by the host so the client can detect
    /// drops/reorders (data channel is reliable + ordered today, but this
    /// keeps us honest if we ever switch to unreliable).
    public let sequence: UInt64

    /// 32 KB cap per chunk — a single 80×40 screen of utf-8 text fits easily;
    /// `cat` of a large file is split into many chunks by the host pump.
    public static let maxChunkBytes = 32_768

    public init(sessionID: UUID, terminalID: UUID, data: Data, sequence: UInt64) {
        self.sessionID = sessionID
        self.terminalID = terminalID
        self.data = data
        self.sequence = sequence
    }
}

/// Window resize — the client recomputes cols/rows when its view bounds or
/// font changes and pushes the new size; the host runs `TIOCSWINSZ` on the
/// PTY master.
public struct TerminalResizeMessage: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let terminalID: UUID
    public let cols: UInt16
    public let rows: UInt16

    public init(sessionID: UUID, terminalID: UUID, cols: UInt16, rows: UInt16) {
        self.sessionID = sessionID
        self.terminalID = terminalID
        self.cols = cols
        self.rows = rows
    }
}

/// Either side may send this. From client: please tear down the shell. From
/// host: the shell exited (`exitCode` set) or was killed by signal
/// (`signal` set). `reason` is for diagnostics; the client never trusts it
/// for security decisions.
public struct TerminalCloseMessage: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let terminalID: UUID
    public let exitCode: Int32?
    public let signal: Int32?
    public let reason: String?

    public init(sessionID: UUID, terminalID: UUID, exitCode: Int32? = nil, signal: Int32? = nil, reason: String? = nil) {
        self.sessionID = sessionID
        self.terminalID = terminalID
        self.exitCode = exitCode
        self.signal = signal
        self.reason = reason
    }
}
