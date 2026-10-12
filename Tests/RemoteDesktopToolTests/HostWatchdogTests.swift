import XCTest
@testable import HostApp

#if os(macOS)
final class HostWatchdogTests: XCTestCase {
    func testBundledHelperMarksWatchdogRecoveryBeforeTerminatingHost() {
        let script = HostWatchdogInstaller.helperScript
        XCTAssertTrue(script.contains("watchdog-recovering"))
        XCTAssertTrue(script.contains("kill -TERM"))
        XCTAssertLessThan(
            script.range(of: "> \"$watchdog_recovering\"")!.lowerBound,
            script.range(of: "kill -TERM")!.lowerBound
        )
    }

    func testIntentionalQuitPauseExpiresInsteadOfDisablingRecoveryForever() {
        let script = HostWatchdogInstaller.helperScript
        XCTAssertTrue(script.contains("watchdog_pause_seconds=60"))
        XCTAssertTrue(script.contains("expired intentional-quit pause; recovery resumed"))
        XCTAssertTrue(script.contains("rm -f \"$watchdog_pause\""))
    }

    func testLaunchAgentRunsInstalledHelperAndStaysAlive() {
        let helper = URL(fileURLWithPath: "/tmp/Vamp Watchdog/vamp-host-watchdog")
        let log = URL(fileURLWithPath: "/tmp/Vamp Host/watchdog-launchd.log")
        let plist = HostWatchdogInstaller.launchAgentPropertyList(helperURL: helper, logURL: log)

        XCTAssertEqual(plist["Label"] as? String, HostWatchdogInstaller.label)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [helper.path])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
    }

    @MainActor
    func testWatchdogRecoveryTerminationDoesNotPauseRelaunch() {
        XCTAssertFalse(HostProcessHeartbeat.shouldPauseForTermination(isWatchdogRecovery: true))
        XCTAssertTrue(HostProcessHeartbeat.shouldPauseForTermination(isWatchdogRecovery: false))
    }
}
#endif
