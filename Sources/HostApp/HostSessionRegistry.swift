import Foundation
import os

/// Durable record of the host's terminal sessions (step B of the persistent
/// session architecture).
///
/// The Mac is authoritative: this registry survives app restarts so the host
/// can reconcile what actually happened to a session (still running, detached
/// awaiting reattach, reaped), and answer client snapshot/resume queries with
/// the truth instead of the client guessing.
///
/// It records METADATA only — no terminal bytes or transcripts (those belong
/// to the event journal) and no startup commands or launcher arguments (those
/// never need to survive a process and must not be persisted unnecessarily).
///
/// Storage: one JSON file per session under `rootURL`, written atomically
/// (temp + rename). A `processSignature` stamped into each record lets a new
/// process recognise records from a previous one: PTYs do not survive a host
/// restart, so those records are reconciled to `.reaped` instead of lying to
/// clients that their shells are still alive.
final class HostSessionRegistry: @unchecked Sendable {

    // MARK: - Records

    enum TerminalState: String, Codable, Equatable, Sendable {
        case running
        case detached
        case reaped
    }

    struct TerminalRecord: Codable, Equatable, Sendable {
        var terminalID: UUID
        var workspaceID: UUID?
        var workspacePath: String?
        var cols: UInt16
        var rows: UInt16
        var lastSequence: UInt64
        var state: TerminalState
        var createdAt: Date
        var lastActivityAt: Date
    }

    struct SessionRecord: Codable, Equatable, Sendable {
        var sessionID: UUID
        var processSignature: String
        var state: TerminalState
        var createdAt: Date
        var lastActivityAt: Date
        var terminals: [TerminalRecord]
    }

    // MARK: - Storage

    private let rootURL: URL
    private let processSignature: String
    private let queue = DispatchQueue(label: "host.session.registry")
    private var sessions: [UUID: SessionRecord] = [:]
    private var loaded = false
    private let logger = Logger(subsystem: "com.remotedesktop.host", category: "SessionRegistry")

    /// Standard location: `<App Support>/<productName>/sessions/`.
    static func standardRootURL(productName: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent(productName, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    init(rootURL: URL, processSignature: String = UUID().uuidString) {
        self.rootURL = rootURL
        self.processSignature = processSignature
    }

    // MARK: - Load / reconcile

    /// Reads every session file. Records written by a DIFFERENT process are
    /// reconciled to `.reaped` (their PTYs died with that process) and pruned
    /// after `reapedGrace` so a client snapshot can still report them briefly.
    func load(reapedGrace: TimeInterval = 60 * 60) {
        queue.sync {
            guard !loaded else { return }
            loaded = true
            do {
                try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
                let files = try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" }
                for file in files {
                    guard let data = try? Data(contentsOf: file),
                          let record = try? JSONDecoder.iso8601().decode(SessionRecord.self, from: data) else {
                        logger.warning("Skipping unreadable session registry file \(file.lastPathComponent)")
                        continue
                    }
                    var reconciled = record
                    if record.processSignature != processSignature {
                        reconciled.processSignature = processSignature
                        reconciled.state = .reaped
                        for index in reconciled.terminals.indices {
                            reconciled.terminals[index].state = .reaped
                        }
                        logger.info("Reconciled stale session \(record.sessionID.uuidString) from a previous host process")
                    }
                    sessions[record.sessionID] = reconciled
                }
                pruneReapedSessionsLocked(olderThan: Date().addingTimeInterval(-reapedGrace))
            } catch {
                logger.error("Failed to load session registry: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Mutations

    func upsertSession(_ sessionID: UUID) {
        queue.sync {
            if sessions[sessionID] == nil {
                sessions[sessionID] = SessionRecord(
                    sessionID: sessionID,
                    processSignature: processSignature,
                    state: .running,
                    createdAt: Date(),
                    lastActivityAt: Date(),
                    terminals: []
                )
            } else {
                sessions[sessionID]?.lastActivityAt = Date()
            }
            persistLocked(sessionID)
        }
    }

    func recordTerminalOpened(_ terminal: TerminalRecord, sessionID: UUID) {
        queue.sync {
            guard var record = sessions[sessionID] else { return }
            if let index = record.terminals.firstIndex(where: { $0.terminalID == terminal.terminalID }) {
                record.terminals[index] = terminal
            } else {
                record.terminals.append(terminal)
            }
            record.state = .running
            record.lastActivityAt = Date()
            sessions[sessionID] = record
            persistLocked(sessionID)
        }
    }

    func markSessionDetached(_ sessionID: UUID) {
        queue.sync {
            guard var record = sessions[sessionID] else { return }
            record.state = .detached
            record.lastActivityAt = Date()
            for index in record.terminals.indices where record.terminals[index].state == .running {
                record.terminals[index].state = .detached
            }
            sessions[sessionID] = record
            persistLocked(sessionID)
        }
    }

    func markSessionAttached(_ sessionID: UUID) {
        queue.sync {
            guard var record = sessions[sessionID] else { return }
            record.state = .running
            record.lastActivityAt = Date()
            for index in record.terminals.indices where record.terminals[index].state == .detached {
                record.terminals[index].state = .running
            }
            sessions[sessionID] = record
            persistLocked(sessionID)
        }
    }

    func markTerminalReaped(sessionID: UUID, terminalID: UUID, lastSequence: UInt64) {
        queue.sync {
            guard var record = sessions[sessionID],
                  let index = record.terminals.firstIndex(where: { $0.terminalID == terminalID }) else { return }
            record.terminals[index].state = .reaped
            record.terminals[index].lastSequence = lastSequence
            record.lastActivityAt = Date()
            if record.terminals.allSatisfy({ $0.state == .reaped }) {
                record.state = .reaped
            }
            sessions[sessionID] = record
            persistLocked(sessionID)
        }
    }

    /// Throttled flush of sequence/activity metadata while a terminal streams.
    func recordTerminalProgress(
        sessionID: UUID,
        terminalID: UUID,
        lastSequence: UInt64,
        cols: UInt16? = nil,
        rows: UInt16? = nil
    ) {
        queue.sync {
            guard var record = sessions[sessionID],
                  let index = record.terminals.firstIndex(where: { $0.terminalID == terminalID }) else { return }
            record.terminals[index].lastSequence = lastSequence
            if let cols { record.terminals[index].cols = cols }
            if let rows { record.terminals[index].rows = rows }
            record.terminals[index].lastActivityAt = Date()
            record.lastActivityAt = Date()
            sessions[sessionID] = record
            persistLocked(sessionID)
        }
    }

    func removeSession(_ sessionID: UUID) {
        queue.sync {
            sessions.removeValue(forKey: sessionID)
            let url = fileURL(for: sessionID)
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Queries

    /// Sessions whose retention expired while detached (still running under
    /// THIS process — the caller tears the PTYs down).
    func expiredDetachedSessions(now: Date = Date(), retention: TimeInterval) -> [UUID] {
        queue.sync {
            sessions.values
                .filter { $0.state == .detached && now.timeIntervalSince($0.lastActivityAt) > retention }
                .map(\.sessionID)
        }
    }

    /// Sessions marked reaped that can be forgotten.
    func pruneReapedSessions(olderThan cutoff: Date = Date().addingTimeInterval(-24 * 60 * 60)) {
        queue.sync { pruneReapedSessionsLocked(olderThan: cutoff) }
    }

    /// Snapshot of everything the registry knows (for the resume protocol).
    func allSessionRecords() -> [SessionRecord] {
        queue.sync { Array(sessions.values).sorted { $0.createdAt < $1.createdAt } }
    }

    func sessionRecord(_ sessionID: UUID) -> SessionRecord? {
        queue.sync { sessions[sessionID] }
    }

    // MARK: - Persistence

    private func fileURL(for sessionID: UUID) -> URL {
        rootURL.appendingPathComponent("\(sessionID.uuidString).json")
    }

    private func persistLocked(_ sessionID: UUID) {
        guard let record = sessions[sessionID],
              let data = try? JSONEncoder.sorted().encode(record) else { return }
        let url = fileURL(for: sessionID)
        let temp = url.appendingPathExtension("tmp")
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try data.write(to: temp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            logger.warning("Failed to persist session \(sessionID.uuidString): \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: temp)
        }
    }

    private func pruneReapedSessionsLocked(olderThan cutoff: Date) {
        let reaped = sessions.filter { $0.value.state == .reaped && $0.value.lastActivityAt < cutoff }
        for (sessionID, _) in reaped {
            sessions.removeValue(forKey: sessionID)
            try? FileManager.default.removeItem(at: fileURL(for: sessionID))
        }
        if !reaped.isEmpty {
            logger.info("Pruned \(reaped.count) reaped session record(s)")
        }
    }
}

private extension JSONEncoder {
    static func sorted() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
