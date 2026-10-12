import Foundation

// MARK: - Session sync protocol (step D)
//
// The resumable-session contract: a reconnecting client asks the host for
// everything it missed while away, and the host answers with the current
// snapshot plus a bounded replay of journaled semantic events. Exactly-once
// UI application is achieved through `journalSequence` deduplication — the
// same numbers that ride on live `.taskPlanEvent` / `.providerSemanticEvent`
// messages.

/// Client → host: "I am back for this session; replay semantic events after
/// this sequence." The host answers with `SessionSnapshotMessage` followed by
/// zero or more `SessionSyncEventMessage`s, then continues live delivery.
public struct SessionSyncRequestMessage: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let afterSequence: UInt64

    public init(sessionID: UUID, afterSequence: UInt64) {
        self.sessionID = sessionID
        self.afterSequence = afterSequence
    }
}

/// Host → client: authoritative current state of the session.
public struct SessionSnapshotMessage: Codable, Hashable, Sendable {

    public struct TerminalSnapshot: Codable, Hashable, Sendable {
        public let terminalID: UUID
        public let workspaceID: UUID?
        public let workspacePath: String?
        public let cols: UInt16
        public let rows: UInt16
        /// Registry state raw value: `running`, `detached`, or `reaped`.
        public let state: String
        /// Last terminal-output sequence assigned by the host.
        public let lastSequence: UInt64

        public init(
            terminalID: UUID,
            workspaceID: UUID?,
            workspacePath: String?,
            cols: UInt16,
            rows: UInt16,
            state: String,
            lastSequence: UInt64
        ) {
            self.terminalID = terminalID
            self.workspaceID = workspaceID
            self.workspacePath = workspacePath
            self.cols = cols
            self.rows = rows
            self.state = state
            self.lastSequence = lastSequence
        }
    }

    public let sessionID: UUID
    /// `running`, `detached`, or `reaped`.
    public let sessionState: String
    /// Highest journal sequence the host has for this session.
    public let lastJournalSequence: UInt64
    public let terminals: [TerminalSnapshot]

    public init(
        sessionID: UUID,
        sessionState: String,
        lastJournalSequence: UInt64,
        terminals: [TerminalSnapshot]
    ) {
        self.sessionID = sessionID
        self.sessionState = sessionState
        self.lastJournalSequence = lastJournalSequence
        self.terminals = terminals
    }
}

/// Host → client: one replayed journal event. `payload` is the original wire
/// message (task-plan event, provider semantic event, terminal lifecycle, …)
/// encoded as JSON; `kind` tells the client which decoder to use.
public struct SessionSyncEventMessage: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let journalSequence: UInt64
    public let kind: String
    public let payload: Data

    public init(sessionID: UUID, journalSequence: UInt64, kind: String, payload: Data) {
        self.sessionID = sessionID
        self.journalSequence = journalSequence
        self.kind = kind
        self.payload = payload
    }
}
