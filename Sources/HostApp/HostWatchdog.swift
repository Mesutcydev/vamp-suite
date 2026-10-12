#if os(macOS)
import Darwin
import Foundation
import os

/// Installs the watchdog as a per-user LaunchAgent from the shipped Host app.
/// This keeps direct ZIP installs self-contained: opening Vamp Host once is
/// sufficient to enable unattended crash and hang recovery.
enum HostWatchdogInstaller {
    static let label = "com.mesutcy.remotedesktop.host.watchdog"
    private static let logger = Logger(subsystem: "com.remotedesktop.host", category: "Watchdog")

    static var helperScript: String {
        #"""
        #!/bin/sh
        set -u

        watchdog_bundle_id="com.mesutcy.remotedesktop.host"
        watchdog_process_name="Vamp Host"
        watchdog_support_dir="$HOME/Library/Application Support/Vamp Host"
        watchdog_heartbeat="$watchdog_support_dir/watchdog-heartbeat"
        watchdog_pause="$watchdog_support_dir/watchdog-paused"
        watchdog_recovering="$watchdog_support_dir/watchdog-recovering"
        watchdog_log="$watchdog_support_dir/watchdog.log"
        watchdog_last_restart=0
        watchdog_pause_seconds=60

        mkdir -p "$watchdog_support_dir"

        log_event() {
          printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$watchdog_log"
        }

        restart_host() {
          watchdog_now="$(date +%s)"
          if [ $((watchdog_now - watchdog_last_restart)) -lt 20 ]; then
            return
          fi
          watchdog_last_restart="$watchdog_now"
          log_event "relaunching $watchdog_process_name"
          /usr/bin/open -gj -b "$watchdog_bundle_id" || log_event "relaunch request failed"
        }

        while :; do
          if [ -e "$watchdog_pause" ]; then
            watchdog_now="$(date +%s)"
            watchdog_pause_timestamp="0"
            read -r watchdog_pause_timestamp _ < "$watchdog_pause" || true
            case "$watchdog_pause_timestamp" in (*[!0-9]*|'') watchdog_pause_timestamp="0" ;; esac
            if [ "$watchdog_pause_timestamp" -gt 0 ] && [ $((watchdog_now - watchdog_pause_timestamp)) -le "$watchdog_pause_seconds" ]; then
              sleep 5
              continue
            fi
            rm -f "$watchdog_pause"
            log_event "expired intentional-quit pause; recovery resumed"
          fi

          watchdog_now="$(date +%s)"
          watchdog_pid=""
          watchdog_timestamp="0"
          if [ -r "$watchdog_heartbeat" ]; then
            read -r watchdog_pid watchdog_timestamp < "$watchdog_heartbeat" || true
          fi

          case "$watchdog_pid" in (*[!0-9]*|'') watchdog_pid="" ;; esac
          case "$watchdog_timestamp" in (*[!0-9]*|'') watchdog_timestamp="0" ;; esac

          if [ -n "$watchdog_pid" ] && kill -0 "$watchdog_pid" 2>/dev/null; then
            watchdog_command="$(ps -p "$watchdog_pid" -o comm= 2>/dev/null || true)"
            if [ $((watchdog_now - watchdog_timestamp)) -gt 20 ]; then
              case "$watchdog_command" in
                *"/Vamp Host")
                  log_event "heartbeat stale; terminating pid $watchdog_pid"
                  printf '%s\n' "$watchdog_now" > "$watchdog_recovering"
                  kill -TERM "$watchdog_pid" 2>/dev/null || true
                  sleep 5
                  if kill -0 "$watchdog_pid" 2>/dev/null; then
                    log_event "pid $watchdog_pid did not terminate; forcing exit"
                    kill -KILL "$watchdog_pid" 2>/dev/null || true
                  fi
                  restart_host
                  ;;
                *) log_event "ignored stale heartbeat for unexpected process $watchdog_pid" ;;
              esac
            fi
          elif [ $((watchdog_now - watchdog_timestamp)) -gt 20 ]; then
            restart_host
          fi

          sleep 5
        done
        """#
    }

    static func launchAgentPropertyList(helperURL: URL, logURL: URL) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [helperURL.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "ThrottleInterval": 10,
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path
        ]
    }

    static func installAndLoad() {
        Task.detached(priority: .utility) {
            do {
                try installAndLoadSynchronously()
            } catch {
                logger.error("Watchdog installation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func installAndLoadSynchronously() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let installDirectory = home
            .appendingPathComponent("Library/Application Support/Vamp Watchdog", isDirectory: true)
        let helperURL = installDirectory.appendingPathComponent("vamp-host-watchdog")
        let agentDirectory = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let plistURL = agentDirectory.appendingPathComponent("\(label).plist")
        let hostSupport = home
            .appendingPathComponent("Library/Application Support/Vamp Host", isDirectory: true)
        let launchdLogURL = hostSupport.appendingPathComponent("watchdog-launchd.log")

        try FileManager.default.createDirectory(
            at: installDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hostSupport, withIntermediateDirectories: true)

        let helperChanged = try writeIfDifferent(Data(helperScript.utf8), to: helperURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: launchAgentPropertyList(helperURL: helperURL, logURL: launchdLogURL),
            format: .xml,
            options: 0
        )
        let plistChanged = try writeIfDifferent(plistData, to: plistURL)

        let domain = "gui/\(getuid())"
        let service = "\(domain)/\(label)"
        if !helperChanged, !plistChanged, runLaunchctl(["print", service]) == 0 {
            return
        }

        _ = runLaunchctl(["bootout", service])
        let bootstrapStatus = runLaunchctl(["bootstrap", domain, plistURL.path])
        guard bootstrapStatus == 0 else {
            throw WatchdogInstallError.launchctlFailed(bootstrapStatus)
        }
        logger.info("Watchdog installed and loaded")
    }

    @discardableResult
    private static func writeIfDifferent(_ data: Data, to url: URL) throws -> Bool {
        if let existing = try? Data(contentsOf: url), existing == data {
            return false
        }
        try data.write(to: url, options: .atomic)
        return true
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}

private enum WatchdogInstallError: LocalizedError {
    case launchctlFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .launchctlFailed(let status):
            return "launchctl bootstrap failed with status \(status)"
        }
    }
}

/// Main-run-loop heartbeat consumed by the watchdog LaunchAgent. Keeping the
/// Timer on `.main` is deliberate: a hung UI/network run loop stops updating
/// the file even though the process still exists.
@MainActor
final class HostProcessHeartbeat {
    static let shared = HostProcessHeartbeat()

    private var timer: Timer?

    private var directoryURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Vamp Host", isDirectory: true)
    }

    private var heartbeatURL: URL { directoryURL.appendingPathComponent("watchdog-heartbeat") }
    private var pauseURL: URL { directoryURL.appendingPathComponent("watchdog-paused") }
    private var recoveringURL: URL { directoryURL.appendingPathComponent("watchdog-recovering") }

    func start() {
        guard timer == nil else { return }
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: pauseURL)
        try? FileManager.default.removeItem(at: recoveringURL)
        writeHeartbeat()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeHeartbeat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopForTermination() {
        timer?.invalidate()
        timer = nil
        let isWatchdogRecovery = FileManager.default.fileExists(atPath: recoveringURL.path)
        if Self.shouldPauseForTermination(isWatchdogRecovery: isWatchdogRecovery) {
            let marker = Data("\(Int(Date().timeIntervalSince1970)) intentional-quit\n".utf8)
            try? marker.write(to: pauseURL, options: .atomic)
        }
        try? FileManager.default.removeItem(at: heartbeatURL)
    }

    static func shouldPauseForTermination(isWatchdogRecovery: Bool) -> Bool {
        !isWatchdogRecovery
    }

    private func writeHeartbeat() {
        let line = "\(ProcessInfo.processInfo.processIdentifier) \(Int(Date().timeIntervalSince1970))\n"
        try? Data(line.utf8).write(to: heartbeatURL, options: .atomic)
    }
}
#endif
