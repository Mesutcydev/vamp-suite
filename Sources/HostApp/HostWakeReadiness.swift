import Foundation

/// Whether this Mac is configured to wake for incoming network traffic — the prerequisite for any
/// Wake-on-LAN / Wake-on-Demand attempt from the iOS client to do anything. Derived from `pmset`.
struct HostWakeReadiness: Sendable, Equatable {
    enum State: String, Sendable {
        case enabled
        case disabled
        /// Couldn't be determined — e.g. the App Sandbox blocks `pmset`, or the key isn't present.
        case unknown
    }

    var wakeOnNetwork: State   // pmset `womp` (Wake on Network Access / Wake for Ethernet)
    var tcpKeepAlive: State    // pmset `tcpkeepalive` (lets the NIC stay reachable while asleep)

    /// True only when we positively know the Mac will wake for network access.
    var isWakeable: Bool { wakeOnNetwork == .enabled }

    static let unknown = HostWakeReadiness(wakeOnNetwork: .unknown, tcpKeepAlive: .unknown)
}

/// Reads (and, with admin consent, sets) the macOS power settings that gate Wake-on-LAN. All work
/// is read-only except `enableWakeOnNetwork()`, which prompts for administrator authorization.
/// Everything degrades to `.unknown` under the App Sandbox, where `pmset`/`osascript` can't be run.
enum HostWakeReadinessDetector {
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// Runs `pmset -g` (no privileges needed) and parses the active power settings.
    static func detect() -> HostWakeReadiness {
        guard !isSandboxed, let output = runPmsetGet() else { return .unknown }
        return parse(output)
    }

    /// Parses `pmset -g` output, whose body is `key   value` lines such as ` womp   1`.
    static func parse(_ output: String) -> HostWakeReadiness {
        func value(for key: String) -> HostWakeReadiness.State {
            for line in output.split(separator: "\n") {
                let parts = line
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .filter { !$0.isEmpty }
                guard parts.count >= 2, parts[0].lowercased() == key else { continue }
                return parts[1] == "1" ? .enabled : .disabled
            }
            return .unknown
        }
        return HostWakeReadiness(
            wakeOnNetwork: value(for: "womp"),
            tcpKeepAlive: value(for: "tcpkeepalive")
        )
    }

    /// Enables `womp` + `tcpkeepalive` for all power sources via an admin prompt. Non-sandboxed only.
    /// Returns true if the command completed (the user may cancel the auth dialog → false).
    @discardableResult
    static func enableWakeOnNetwork() -> Bool {
        guard !isSandboxed else { return false }
        // `pmset -a` applies to every power source; requires root, hence the admin prompt.
        let script = "do shell script \"/usr/bin/pmset -a womp 1; /usr/bin/pmset -a tcpkeepalive 1\" with administrator privileges"
        return run(executable: "/usr/bin/osascript", arguments: ["-e", script]) != nil
    }

    // MARK: - Process helpers

    private static func runPmsetGet() -> String? {
        run(executable: "/usr/bin/pmset", arguments: ["-g"])
    }

    /// Runs a command, returns stdout on a clean exit, or nil on launch failure / non-zero status.
    private static func run(executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
