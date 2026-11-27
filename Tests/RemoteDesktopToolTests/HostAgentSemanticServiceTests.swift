#if os(macOS)
import XCTest
@testable import HostApp
import SharedProtocol

final class HostAgentSemanticServiceTests: XCTestCase {
    func testPromptIsSeparatedFromFlagsForEveryProvider() {
        let prompt = "--not-a-provider-flag"
        for provider in AgentProviderKind.allCases {
            let launch = HostAgentSemanticService.launch(provider: provider, prompt: prompt, previousSessionID: nil)
            // Flag-value providers get the prompt behind a leading space so a prompt that
            // starts with "-" can never be parsed as an option.
            let isPrompt: (String) -> Bool = { $0 == prompt || $0 == " " + prompt }
            XCTAssertEqual(launch.arguments.filter(isPrompt).count, 1, "\(provider.rawValue)")
            guard let promptIndex = launch.arguments.firstIndex(where: isPrompt), promptIndex > 0 else {
                return XCTFail("\(provider.rawValue) must pass the prompt as an argument")
            }
            let delimiter = launch.arguments[promptIndex - 1]
            XCTAssertTrue(
                ["--", "--prompt", "--message"].contains(delimiter),
                "\(provider.rawValue) must place the prompt after its prompt delimiter"
            )
            if delimiter != "--" {
                XCTAssertFalse(launch.arguments[promptIndex].hasPrefix("-"),
                               "\(provider.rawValue) must not hand a flag-like value to an option parser")
            }
        }
    }

    func testOpenCodeMatchesLinuxOneShotJSONRun() {
        let launch = HostAgentSemanticService.launch(provider: .openCode, prompt: "hello", previousSessionID: "ses_1")
        XCTAssertEqual(launch.executable, "opencode")
        XCTAssertEqual(launch.arguments, ["run", "--format", "json", "--session", "ses_1", "--", "hello"])
        XCTAssertFalse(launch.arguments.contains("--auto"))
    }

    func testCodexResumeKeepsJSONFlagsBeforePromptSeparator() {
        let launch = HostAgentSemanticService.launch(provider: .codex, prompt: "resume me", previousSessionID: "thread-1")
        XCTAssertEqual(launch.arguments, [
            "exec", "resume", "thread-1", "--json", "--skip-git-repo-check", "--", "resume me"
        ])
    }

    func testAdditionalProviderLaunchProfilesUseDocumentedHeadlessModes() {
        XCTAssertEqual(
            HostAgentSemanticService.launch(provider: .kimi, prompt: "hello", previousSessionID: "kimi-1").arguments,
            ["--output-format", "stream-json", "--session", "kimi-1", "--prompt", "hello"]
        )
        XCTAssertEqual(
            HostAgentSemanticService.launch(provider: .qwen, prompt: "hello", previousSessionID: "qwen-1").arguments,
            ["--output-format", "stream-json", "--include-partial-messages", "--approval-mode", "plan", "--resume", "qwen-1", "--prompt", "hello"]
        )
        XCTAssertEqual(
            HostAgentSemanticService.launch(provider: .aider, prompt: "hello", previousSessionID: nil).arguments,
            ["--message", "hello", "--stream", "--no-pretty", "--no-auto-commits", "--no-check-update"]
        )
        XCTAssertEqual(
            HostAgentSemanticService.launch(provider: .gemini, prompt: "hello", previousSessionID: "gemini-1").arguments,
            ["--output-format", "stream-json", "--approval-mode", "plan", "--resume", "gemini-1", "--prompt", "hello"]
        )
    }

    func testLaunchProfilesNeverBypassProviderSafety() {
        for provider in AgentProviderKind.allCases {
            let joined = HostAgentSemanticService.launch(provider: provider, prompt: "hello", previousSessionID: nil)
                .arguments.joined(separator: " ")
            XCTAssertFalse(joined.contains("dangerously-skip-permissions"), "\(provider.rawValue)")
            XCTAssertFalse(joined.contains("dangerously-bypass-approvals-and-sandbox"), "\(provider.rawValue)")
            XCTAssertFalse(joined.contains("always-approve"), "\(provider.rawValue)")
            XCTAssertFalse(joined.contains("auto-accept"), "\(provider.rawValue)")
            XCTAssertFalse(joined.split(separator: " ").contains("--yes"), "\(provider.rawValue)")
            XCTAssertFalse(joined.contains("yolo"), "\(provider.rawValue)")
        }
    }
}
#endif
