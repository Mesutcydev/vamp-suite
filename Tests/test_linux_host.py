#!/usr/bin/env python3
import json
import os
import tempfile
import sys
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "linux-host"))
from vamp_terminal_host import (  # noqa: E402
    AGENT_PROVIDERS,
    AiderSemanticParser,
    ClaudeSemanticParser,
    CodexSemanticParser,
    GeminiSemanticParser,
    KimiSemanticParser,
    OpenCodeSemanticParser,
    PiSemanticParser,
    QwenSemanticParser,
    PairingState,
    PtyTerminal,
    RequestHandler,
    VampTerminalHost,
    json_bytes,
    origin_allowed,
    parse_args,
    validate_listen_address,
)


class LinuxHostTests(unittest.TestCase):
    def test_pairing_rotates_and_rejects_wrong_code(self):
        pairing = PairingState()
        self.assertEqual(len(pairing.code), 12)
        self.assertTrue(pairing.code.isdigit())
        code = pairing.code
        self.assertIsNone(pairing.pair("000000" if code != "000000" else "111111"))
        result = pairing.pair(code)
        self.assertIsNotNone(result)
        token, token_expires_at = result or ("", 0)
        self.assertTrue(pairing.valid_token(token))
        self.assertGreater(token_expires_at, pairing.expires_at)
        self.assertNotEqual(pairing.code, code)
        self.assertIsNone(pairing.pair(code), "pairing approval codes must be single-use")

    def test_status_never_exposes_pairing_code_or_token(self):
        host = VampTerminalHost(8)
        code = host.pairing.code
        result = host.pairing.pair(code)
        token = result[0] if result else ""
        serialized = json.dumps(host.status())
        self.assertNotIn(code, serialized)
        self.assertNotIn(token or "", serialized)
        self.assertEqual(host.status()["pairing"]["pairedClients"], 1)

    def test_terminal_limit_is_bounded(self):
        self.assertEqual(VampTerminalHost(80).max_terminals, 8)
        self.assertEqual(VampTerminalHost(0).max_terminals, 1)

    def test_json_payload_is_compact_and_decodable(self):
        value = {"type": "terminalReady", "terminalID": "one"}
        self.assertEqual(json.loads(json_bytes(value)), value)

    def test_http_handler_supports_reverse_proxy_websocket_upgrades(self):
        self.assertEqual(RequestHandler.protocol_version, "HTTP/1.1")

    def test_workspace_is_canonical_and_restricted_to_home(self):
        with tempfile.TemporaryDirectory() as temporary_home:
            home = Path(temporary_home)
            project = home / "Projects" / "Vamp"
            project.mkdir(parents=True)
            host = VampTerminalHost(8)
            with patch("pathlib.Path.home", return_value=home):
                self.assertEqual(host.resolve_workspace(str(project / ".." / "Vamp")), project.resolve())
                with self.assertRaises(ValueError):
                    host.resolve_workspace("/")

    def test_capabilities_are_honest(self):
        capabilities = VampTerminalHost(8).capabilities()
        self.assertTrue(capabilities["terminal"])
        self.assertTrue(capabilities["multipleTerminals"])
        self.assertTrue(capabilities["workspaces"])
        self.assertTrue(capabilities["chat"])
        self.assertEqual(capabilities["agentProviders"], list(AGENT_PROVIDERS))
        self.assertFalse(capabilities["taskPlans"])
        self.assertFalse(capabilities["remoteControl"])

    def test_browser_is_byte_safe_and_keyboard_viewport_aware(self):
        browser = (Path(__file__).resolve().parents[1] / "linux-host" / "index.html").read_text()
        self.assertIn("new TextDecoder()", browser)
        self.assertIn("message.encoding==='base64'", browser)
        self.assertIn("visualViewport?.addEventListener('resize'", browser)
        self.assertIn("--visual-page-top", browser)
        self.assertIn("body.connected .help", browser)
        self.assertIn("scrollIntoView", browser)
        self.assertIn("class TerminalScreen", browser)
        self.assertIn("class SemanticStream", browser)
        self.assertIn('id="mode-chat"', browser)
        self.assertIn('id="mode-terminal"', browser)
        self.assertIn('id="chat"', browser)
        self.assertIn("responseSemantic", browser)
        self.assertIn("lastSubmittedCommand", browser)
        self.assertIn("localStorage.setItem(pairingStorageKey", browser)
        self.assertIn("let token=loadStoredPairing()", browser)
        self.assertIn("rememberPairing(body.token,body.expiresAt)", browser)
        self.assertNotIn("event.code===1008||event.code===1006", browser)
        self.assertIn("type:'agentPrompt'", browser)
        self.assertIn("message.type==='agentEvent'", browser)
        self.assertIn("agentProviders={opencode:", browser)
        self.assertIn("Codex CLI", browser)
        self.assertIn("OpenCode", browser)
        self.assertIn("Gemini CLI", browser)
        for provider in AGENT_PROVIDERS:
            self.assertIn(provider, browser)
        self.assertIn("provider:node.agent", browser)
        self.assertIn("white-space:pre", browser)
        self.assertIn("crypto.getRandomValues", browser)
        self.assertNotIn("crypto.randomUUID", browser)
        self.assertIn('id="pair-form"', browser)
        self.assertIn('maxlength="12"', browser)
        self.assertIn("function scheduleOutput", browser)
        self.assertIn("const existing=new Map", browser)
        self.assertIn("let viewportFrame=0", browser)
        self.assertIn("cloudflared tunnel run", browser)
        self.assertIn("Cloudflare Access", browser)

    def test_browser_tab_capacity_is_preflighted_and_failed_tabs_are_rolled_back(self):
        browser = (Path(__file__).resolve().parents[1] / "linux-host" / "index.html").read_text()
        host = (Path(__file__).resolve().parents[1] / "linux-host" / "vamp_terminal_host.py").read_text()
        self.assertIn("let maxTerminals = 8", browser)
        self.assertIn("if (tabs.size >= maxTerminals)", browser)
        self.assertIn("button.disabled = atCapacity", browser)
        self.assertIn("if(node?.state==='opening')", browser)
        self.assertIn("removeTab(terminalId,text)", browser)
        self.assertIn("message.type==='error'", browser)
        self.assertIn('"capacity"', host)
        self.assertIn("terminal_id,\n            )", host)

    def test_claude_stream_json_becomes_semantic_chat_events(self):
        parser = ClaudeSemanticParser()
        delta = json.dumps({
            "type": "stream_event",
            "session_id": "session-1",
            "event": {"delta": {"type": "text_delta", "text": "Hello"}},
        }).encode() + b"\n"
        self.assertEqual(
            parser.consume(delta),
            [{"eventType": "messageDelta", "text": "Hello"}],
        )
        self.assertEqual(parser.session_id, "session-1")
        completed = json.dumps({"type": "result", "result": "Hello", "is_error": False}).encode()
        self.assertEqual(parser.consume(completed), [{"eventType": "completed"}])
        self.assertTrue(parser.did_finish)

    def test_claude_final_result_is_a_non_streaming_fallback(self):
        parser = ClaudeSemanticParser()
        result = json.dumps({"type": "result", "result": "Complete answer", "is_error": False}).encode()
        self.assertEqual(parser.consume(result), [
            {"eventType": "messageDelta", "text": "Complete answer"},
            {"eventType": "completed"},
        ])

    def test_opencode_json_becomes_semantic_chat_events(self):
        parser = OpenCodeSemanticParser()
        self.assertEqual(parser.consume(b'{"type":"text","sessionID":"open-1","part":{"text":"Hello"}}\n'), [
            {"eventType": "messageDelta", "text": "Hello"},
        ])
        self.assertEqual(parser.session_id, "open-1")
        self.assertEqual(parser.consume(b'{"type":"step_finish","part":{"reason":"stop"}}\n'), [
            {"eventType": "completed"},
        ])

    def test_codex_jsonl_becomes_semantic_chat_events(self):
        parser = CodexSemanticParser()
        self.assertEqual(parser.consume(b'{"type":"thread.started","thread_id":"thread-1"}\n'), [])
        self.assertEqual(parser.session_id, "thread-1")
        self.assertEqual(parser.consume(b'{"type":"item.completed","item":{"type":"agent_message","text":"Ready"}}\n'), [
            {"eventType": "messageDelta", "text": "Ready"},
        ])
        self.assertEqual(parser.consume(b'{"type":"turn.completed"}\n'), [{"eventType": "completed"}])

    def test_gemini_stream_json_becomes_semantic_chat_events(self):
        parser = GeminiSemanticParser()
        self.assertEqual(parser.consume(b'{"type":"init","session_id":"gemini-1"}\n'), [])
        self.assertEqual(parser.session_id, "gemini-1")
        self.assertEqual(parser.consume(b'{"type":"message","role":"assistant","content":"Hi","delta":true}\n'), [
            {"eventType": "messageDelta", "text": "Hi"},
        ])
        self.assertEqual(parser.consume(b'{"type":"result"}\n'), [{"eventType": "completed"}])

    def test_all_added_provider_streams_become_semantic_chat_events(self):
        pi = PiSemanticParser()
        self.assertEqual(pi.consume(b'{"type":"session","id":"pi-1"}\n'), [])
        self.assertEqual(pi.session_id, "pi-1")
        self.assertEqual(pi.consume(b'{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Pi"}}\n'), [
            {"eventType": "messageDelta", "text": "Pi"},
        ])
        self.assertEqual(pi.consume(b'{"type":"agent_end"}\n'), [{"eventType": "completed"}])

        kimi = KimiSemanticParser()
        self.assertEqual(kimi.consume(b'{"session_id":"kimi-1","role":"assistant","content":"Kimi"}\n'), [
            {"eventType": "messageDelta", "text": "Kimi"},
        ])
        self.assertEqual(kimi.session_id, "kimi-1")
        self.assertEqual(kimi.consume(b'{"type":"end"}\n'), [{"eventType": "completed"}])

        qwen = QwenSemanticParser()
        self.assertEqual(qwen.consume(b'{"session_id":"qwen-1","type":"stream_event","event":{"delta":{"type":"text_delta","text":"Qwen"}}}\n'), [
            {"eventType": "messageDelta", "text": "Qwen"},
        ])
        self.assertEqual(qwen.session_id, "qwen-1")
        self.assertEqual(qwen.consume(b'{"type":"result","is_error":false}\n'), [{"eventType": "completed"}])

        aider = AiderSemanticParser()
        self.assertEqual(aider.consume("Aider\n".encode()), [{"eventType": "messageDelta", "text": "Aider\n"}])
        self.assertFalse(aider.did_finish)

    def test_claude_runner_streams_semantic_events_without_a_tui(self):
        class Connection:
            def __init__(self):
                self.messages = []

            def send(self, message):
                self.messages.append(message)

            def send_error(self, code, message, terminal_id=None):
                self.messages.append({"type": "error", "code": code, "message": message, "terminalID": terminal_id})

        with tempfile.TemporaryDirectory() as temporary_directory:
            directory = Path(temporary_directory)
            claude = directory / "claude"
            claude.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' '{\"type\":\"stream_event\",\"session_id\":\"fake-session\",\"event\":{\"delta\":{\"type\":\"text_delta\",\"text\":\"semantic reply\"}}}'\n"
                "printf '%s\\n' '{\"type\":\"result\",\"result\":\"semantic reply\",\"is_error\":false}'\n"
            )
            claude.chmod(0o755)
            connection = Connection()
            terminal = PtyTerminal(connection, "terminal-one", "Claude", directory)
            with patch.dict(os.environ, {"PATH": str(directory)}):
                terminal.run_agent_prompt("claude", "hello")
                deadline = time.time() + 5
                while terminal.agent_process is not None and time.time() < deadline:
                    time.sleep(0.01)
            self.assertTrue(any(message.get("eventType") == "messageDelta" for message in connection.messages))
            self.assertTrue(any(message.get("eventType") == "completed" for message in connection.messages))
            self.assertEqual(terminal.agent_session_ids["claude"], "fake-session")

    def test_other_provider_runners_stream_semantic_events_without_a_tui(self):
        class Connection:
            def __init__(self):
                self.messages = []

            def send(self, message):
                self.messages.append(message)

            def send_error(self, code, message, terminal_id=None):
                self.messages.append({"type": "error", "code": code, "message": message, "terminalID": terminal_id})

        outputs = {
            "codex": (
                '{"type":"thread.started","thread_id":"codex-session"}\n'
                '{"type":"item.completed","item":{"type":"agent_message","text":"codex reply"}}\n'
                '{"type":"turn.completed"}\n'
            ),
            "opencode": (
                '{"type":"text","sessionID":"opencode-session","part":{"text":"opencode reply"}}\n'
                '{"type":"step_finish","part":{"reason":"stop"}}\n'
            ),
            "gemini": (
                '{"type":"init","session_id":"gemini-session"}\n'
                '{"type":"message","role":"assistant","content":"gemini reply","delta":true}\n'
                '{"type":"result"}\n'
            ),
        }
        with tempfile.TemporaryDirectory() as temporary_directory:
            directory = Path(temporary_directory)
            for provider, output in outputs.items():
                executable = directory / provider
                executable.write_text("#!/bin/sh\nprintf '%s' '" + output + "'\n")
                executable.chmod(0o755)
            for provider in outputs:
                connection = Connection()
                terminal = PtyTerminal(connection, f"terminal-{provider}", provider, directory)
                with patch.dict(os.environ, {"PATH": str(directory)}):
                    terminal.run_agent_prompt(provider, "hello")
                    deadline = time.time() + 5
                    while terminal.agent_process is not None and time.time() < deadline:
                        time.sleep(0.01)
                provider_messages = [message for message in connection.messages if message.get("provider") == provider]
                self.assertTrue(any(message.get("eventType") == "messageDelta" for message in provider_messages), provider)
                self.assertTrue(any(message.get("eventType") == "completed" for message in provider_messages), provider)
                self.assertEqual(terminal.agent_session_ids[provider], f"{provider}-session")

    def test_agent_launchers_never_bypass_provider_safety(self):
        source = (Path(__file__).resolve().parents[1] / "linux-host" / "vamp_terminal_host.py").read_text()
        self.assertNotIn("dangerously-skip-permissions", source)
        self.assertNotIn("dangerously-bypass-approvals-and-sandbox", source)
        self.assertNotIn('"--auto"', source)
        self.assertNotIn('"--yolo"', source)

    def test_rotate_revokes_existing_tokens(self):
        pairing = PairingState()
        token, _ = pairing.pair(pairing.code)
        self.assertTrue(pairing.valid_token(token))
        pairing.rotate()
        self.assertFalse(pairing.valid_token(token))

    def test_origin_must_match_host(self):
        self.assertTrue(origin_allowed(None, "127.0.0.1:9475"))
        self.assertTrue(origin_allowed("", "127.0.0.1:9475"))
        self.assertTrue(origin_allowed("http://127.0.0.1:9475", "127.0.0.1:9475"))
        self.assertFalse(origin_allowed("http://evil.example", "127.0.0.1:9475"))
        self.assertFalse(origin_allowed("null", "127.0.0.1:9475"))

    def test_agent_prompt_is_separated_from_flags(self):
        from unittest.mock import MagicMock

        terminal = PtyTerminal(MagicMock(), "one", "shell", Path("/tmp"))
        for provider in ("claude", "opencode", "codex"):
            arguments = terminal._agent_arguments(provider, provider, "--dangerously-skip-permissions")
            self.assertEqual(arguments[-2:], ["--", "--dangerously-skip-permissions"], provider)

    def test_non_loopback_listen_requires_explicit_flag(self):
        default = parse_args(["--listen", "0.0.0.0"])
        self.assertFalse(default.allow_non_loopback)
        allowed = parse_args(["--listen", "192.168.1.10", "--allow-non-loopback"])
        self.assertTrue(allowed.allow_non_loopback)

    def test_wildcard_listen_is_always_refused(self):
        with self.assertRaises(SystemExit):
            validate_listen_address("0.0.0.0", True)
        with self.assertRaises(SystemExit):
            validate_listen_address("::", False)
        validate_listen_address("127.0.0.1", False)
        validate_listen_address("192.168.1.10", True)

    def test_background_host_searches_provider_install_locations(self):
        directories = PtyTerminal._launcher_search_directories()
        home = str(Path.home())
        self.assertIn(f"{home}/.local/bin", directories)
        self.assertIn(f"{home}/.opencode/bin", directories)
        self.assertIn(f"{home}/.npm-global/bin", directories)
        self.assertIn(f"{home}/.bun/bin", directories)
        self.assertIn(f"{home}/.volta/bin", directories)


if __name__ == "__main__":
    unittest.main()
