import Foundation
import os

/// Bounded, per-session journal of SEMANTIC session events (step C of the
/// persistent-session architecture).
///
/// Every event gets a monotonically increasing sequence number. A client that
/// reconnects asks for `events(after: lastAppliedSequence)` and applies the
/// delta — no task-plan mutation, agent status change, or user prompt is ever
/// lost just because the phone was away.
///
/// Deliberate scope boundary: this journal records SEMANTIC state only
/// (task-plan events, provider semantic events, agent prompts, terminal
/// lifecycle). Raw terminal bytes are NOT journaled — they stay in the
/// bounded in-memory reattach buffer in `HostTerminalService`. Terminal
/// scrollback is presentation state, not task state, and persisting raw
/// shell output to disk would be a pointless privacy/storage cost.
///
/// Storage: one JSON-lines file per session under `rootURL`. Writes are
/// append-only; when a file exceeds the byte budget the journal rewrites it
/// keeping the newest `maxEvents` entries.
final class HostSessionJournal: @unchecked Sendable {

    // MARK: - Event model

    enum EventType: String, Codable, Sendable {
        case terminalOpened
        case terminalClosed
        case sessionDetached
        case sessionAttached
        case taskPlan
        case providerSemantic
        case agentPrompt
    }

    struct Event: Codable, Equatable, Sendable {
        var sequence: UInt64
        var timestamp: Date
        var type: EventType
        /// The original wire message (task-plan event, provider semantic
        /// event, …) encoded as JSON. Replay decodes it with the same Codable
        /// type the live path uses, so journal and live delivery can never
        /// drift apart.
        var payload: Data
    }

    // MARK: - Configuration

    /// Per-session caps: keeps disk use bounded no matter how long an agent
    /// runs. 2 MB of semantic events ≈ thousands of task-plan mutations.
    private let maxFileBytes = 2 * 1024 * 1024
    private let maxEventsOnCompact = 400
    private let flushInterval: TimeInterval = 2.0

    // MARK: - State

    private let rootURL: URL
    private let queue = DispatchQueue(label: "host.session.journal")
    private var sequences: [UUID: UInt64] = [:]
    private var pending: [UUID: [Event]] = [:]
    private var flushTimers: [UUID: DispatchSourceTimer] = [:]
    private let logger = Logger(subsystem: "com.remotedesktop.host", category: "SessionJournal")

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// Loads the highest sequence number per session so numbering continues
    /// across host restarts instead of restarting at 1 (which would make a
    /// client's `lastAppliedSequence` ambiguous).
    func load() {
        queue.sync {
            do {
                try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
                let files = try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "jsonl" }
                for file in files {
                    guard let sessionID = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                          let lastLine = Self.lastLine(of: file),
                          let event = try? JSONDecoder.journal().decode(Event.self, from: lastLine) else { continue }
                    sequences[sessionID] = max(sequences[sessionID] ?? 0, event.sequence)
                }
            } catch {
                logger.error("Failed to load journal: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Append

    /// Appends an event and returns its sequence number.
    @discardableResult
    func append(sessionID: UUID, type: EventType, payload: Data) -> UInt64 {
        queue.sync {
            let sequence = (sequences[sessionID] ?? 0) + 1
            sequences[sessionID] = sequence
            let event = Event(
                sequence: sequence,
                timestamp: Date(),
                type: type,
                payload: payload
            )
            pending[sessionID, default: []].append(event)
            scheduleFlushLocked(sessionID)
            return sequence
        }
    }

    // MARK: - Replay

    /// Events strictly after `afterSequence`, oldest first, capped at `limit`.
    func events(sessionID: UUID, after afterSequence: UInt64, limit: Int = 500) -> [Event] {
        queue.sync {
            flushLocked(sessionID)
            let all = readAllLocked(sessionID)
            return all.filter { $0.sequence > afterSequence }.suffix(limit)
        }
    }

    func lastSequence(sessionID: UUID) -> UInt64 {
        queue.sync {
            flushLocked(sessionID)
            return sequences[sessionID] ?? 0
        }
    }

    /// Flushes pending events to disk (tests, graceful host shutdown).
    func flush(sessionID: UUID) {
        queue.sync { flushLocked(sessionID) }
    }

    func remove(sessionID: UUID) {
        queue.sync {
            flushTimers[sessionID]?.cancel()
            flushTimers.removeValue(forKey: sessionID)
            pending.removeValue(forKey: sessionID)
            sequences.removeValue(forKey: sessionID)
            try? FileManager.default.removeItem(at: fileURL(for: sessionID))
        }
    }

    // MARK: - Persistence

    private func fileURL(for sessionID: UUID) -> URL {
        rootURL.appendingPathComponent("\(sessionID.uuidString).jsonl")
    }

    private func scheduleFlushLocked(_ sessionID: UUID) {
        guard flushTimers[sessionID] == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        timer.setEventHandler { [weak self] in
            self?.flushLocked(sessionID)
            if (self?.pending[sessionID] ?? []).isEmpty {
                timer.cancel()
                self?.flushTimers.removeValue(forKey: sessionID)
            }
        }
        timer.resume()
        flushTimers[sessionID] = timer
    }

    private func flushLocked(_ sessionID: UUID) {
        guard let events = pending[sessionID], !events.isEmpty else { return }
        pending[sessionID] = []
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let url = fileURL(for: sessionID)
            let handle = try FileHandle.orCreate(at: url)
            try handle.seekToEnd()
            for event in events {
                var data = try JSONEncoder.journal().encode(event)
                data.append(0x0A)
                try handle.write(contentsOf: data)
            }
            try handle.close()
            compactIfNeededLocked(sessionID)
        } catch {
            logger.warning("Journal flush failed for \(sessionID.uuidString): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Keeps the journal file under the byte budget by rewriting it with the
    /// newest `maxEventsOnCompact` entries.
    private func compactIfNeededLocked(_ sessionID: UUID) {
        let url = fileURL(for: sessionID)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int,
              size > maxFileBytes else { return }
        let kept = readAllLocked(sessionID).suffix(maxEventsOnCompact)
        let temp = url.appendingPathExtension("tmp")
        do {
            var out = Data()
            for event in kept {
                var line = try JSONEncoder.journal().encode(event)
                line.append(0x0A)
                out.append(line)
            }
            try out.write(to: temp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            logger.info("Compacted journal for session \(sessionID.uuidString) to \(kept.count) events")
        } catch {
            logger.warning("Journal compaction failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: temp)
        }
    }

    private func readAllLocked(_ sessionID: UUID) -> [Event] {
        let url = fileURL(for: sessionID)
        guard let data = try? Data(contentsOf: url) else { return [] }
        var events: [Event] = []
        var remainder = data
        while let newline = remainder.firstIndex(of: 0x0A) {
            let line = remainder[remainder.startIndex..<newline]
            remainder = remainder[remainder.index(after: newline)...]
            if let event = try? JSONDecoder.journal().decode(Event.self, from: line) {
                events.append(event)
            }
        }
        return events
    }

    private static func lastLine(of url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        var end = data.index(before: data.endIndex)
        while end > data.startIndex, data[end] == 0x0A { end = data.index(before: end) }
        guard end > data.startIndex else { return nil }
        var start = end
        while start > data.startIndex {
            let previous = data.index(before: start)
            if data[previous] == 0x0A { break }
            start = previous
        }
        return Data(data[start...end])
    }
}

private extension JSONEncoder {
    static func journal() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static func journal() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension FileHandle {
    /// Opens for writing, creating the file when it does not exist.
    static func orCreate(at url: URL) throws -> FileHandle {
        if FileManager.default.fileExists(atPath: url.path) {
            return try FileHandle(forWritingTo: url)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try FileHandle(forWritingTo: url)
    }
}
