#!/usr/bin/env python3
"""Small, dependency-free Linux terminal host for Vamp Terminal workflows.

The Linux host deliberately exposes a loopback WebSocket endpoint. Put it behind
`tailscale serve` or a named, Cloudflare Access-protected tunnel when it needs
to be reached away from the LAN. It does not open a public listener, implement
a relay, or pretend to be the iOS WebRTC host; it is the Safari/browser
companion for Linux machines.
"""

from __future__ import annotations

import argparse
import base64
import collections
import hashlib
import http.server
import json
import os
import pty
import secrets
import shutil
import signal
import socket
import struct
import subprocess
import threading
import time
import urllib.parse
import uuid
from pathlib import Path
from typing import Any


VERSION = "2.3.6"
DEFAULT_PORT = 9475
DEFAULT_MAX_TERMINALS = 8
PAIRING_TTL_SECONDS = 600
PAIRED_TOKEN_TTL_SECONDS = 30 * 60
PAIRING_CODE_DIGITS = 12
PAIRING_MAX_ATTEMPTS = 8
LOOPBACK_BIND_ADDRESSES = frozenset({"127.0.0.1", "localhost", "::1"})
WILDCARD_BIND_ADDRESSES = frozenset({"0.0.0.0", "::", "*"})
PAIRING_ATTEMPT_WINDOW_SECONDS = 60
# Subprotocol name used to carry the bearer token during the WebSocket
# handshake. The client offers this name followed by the token; the server
# validates the token and echoes only the name back. Keeping the token out of
# the URL avoids leaking it into browser history, referrers, and logs.
WEBSOCKET_AUTH_PROTOCOL = "vamp-auth"
ROOT = Path(__file__).resolve().parent
MAX_AGENT_PROMPT_BYTES = 64 * 1024
AGENT_PROVIDERS = (
    "opencode", "pi", "commandcode", "chatgpt", "claude", "kimi",
    "qwen", "codex", "aider", "grok", "gemini",
)
AGENT_DISPLAY_NAMES = {
    "opencode": "OpenCode",
    "pi": "Pi",
    "commandcode": "CommandCode",
    "chatgpt": "ChatGPT CLI",
    "claude": "Claude Code",
    "kimi": "Kimi",
    "qwen": "Qwen Code",
    "codex": "Codex CLI",
    "aider": "Aider",
    "grok": "Grok CLI",
    "gemini": "Gemini CLI",
}


def now() -> float:
    return time.time()


def clamp(value: Any, minimum: int, maximum: int, default: int) -> int:
    try:
        return max(minimum, min(maximum, int(value)))
    except (TypeError, ValueError):
        return default


def random_pairing_code() -> str:
    return f"{secrets.randbelow(10 ** PAIRING_CODE_DIGITS):0{PAIRING_CODE_DIGITS}d}"


def normalize_pairing_code(raw: str) -> str | None:
    digits = "".join(character for character in raw if character.isdigit())
    return digits if len(digits) == PAIRING_CODE_DIGITS else None


def validate_listen_address(listen: str, allow_non_loopback: bool) -> None:
    if listen in LOOPBACK_BIND_ADDRESSES:
        return
    if listen in WILDCARD_BIND_ADDRESSES:
        raise SystemExit(
            "refusing wildcard bind; keep the origin on 127.0.0.1 and use "
            "`tailscale serve` or Cloudflare Access"
        )
    if not allow_non_loopback:
        raise SystemExit(
            "refusing non-loopback bind; pass --allow-non-loopback if you accept the risk, "
            "or use `tailscale serve --bg http://127.0.0.1:%d`" % DEFAULT_PORT
        )


def json_bytes(value: Any) -> bytes:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def read_exact(sock: socket.socket, length: int) -> bytes:
    chunks: list[bytes] = []
    remaining = length
    while remaining:
        chunk = sock.recv(remaining)
        if not chunk:
            raise ConnectionError("socket closed")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def websocket_frame(payload: bytes, opcode: int = 0x1) -> bytes:
    length = len(payload)
    if length < 126:
        header = struct.pack("!BB", 0x80 | opcode, length)
    elif length <= 0xFFFF:
        header = struct.pack("!BBH", 0x80 | opcode, 126, length)
    else:
        header = struct.pack("!BBQ", 0x80 | opcode, 127, length)
    return header + payload


def read_websocket_frame(sock: socket.socket) -> tuple[int, bytes]:
    first, second = read_exact(sock, 2)
    opcode = first & 0x0F
    masked = bool(second & 0x80)
    if not masked:
        raise ValueError("client websocket frames must be masked")
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", read_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", read_exact(sock, 8))[0]
    if length > 4 * 1024 * 1024:
        raise ValueError("websocket message is too large")
    mask = read_exact(sock, 4) if masked else b""
    payload = bytearray(read_exact(sock, length))
    if masked:
        for index in range(length):
            payload[index] ^= mask[index % 4]
    return opcode, bytes(payload)


class ClaudeSemanticParser:
    """Turn Claude's documented stream-json records into browser Chat events."""

    def __init__(self) -> None:
        self.session_id: str | None = None
        self.did_emit_message = False
        self.did_finish = False

    def consume(self, raw_line: bytes) -> list[dict[str, Any]]:
        try:
            value = json.loads(raw_line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return []
        if not isinstance(value, dict):
            return []
        session_id = value.get("session_id")
        if isinstance(session_id, str) and session_id:
            self.session_id = session_id

        events: list[dict[str, Any]] = []
        nested_event = value.get("event")
        delta = nested_event.get("delta") if isinstance(nested_event, dict) else None
        if isinstance(delta, dict) and delta.get("type") == "text_delta":
            text = delta.get("text")
            if isinstance(text, str) and text:
                self.did_emit_message = True
                events.append({"eventType": "messageDelta", "text": text})
        if value.get("type") == "result":
            if value.get("is_error") is True:
                events.append({"eventType": "failed", "message": str(value.get("result") or "Claude failed")})
            else:
                result = value.get("result")
                if not self.did_emit_message and isinstance(result, str) and result.strip():
                    self.did_emit_message = True
                    events.append({"eventType": "messageDelta", "text": result})
                events.append({"eventType": "completed"})
            self.did_finish = True
        return events


class OpenCodeSemanticParser:
    """Turn OpenCode's documented raw JSON events into browser Chat events."""

    def __init__(self) -> None:
        self.session_id: str | None = None
        self.did_finish = False

    def consume(self, raw_line: bytes) -> list[dict[str, Any]]:
        value = decode_json_object(raw_line)
        if value is None:
            return []
        session_id = value.get("sessionID")
        if isinstance(session_id, str) and session_id:
            self.session_id = session_id
        event_type = str(value.get("type") or "").lower()
        part = value.get("part") if isinstance(value.get("part"), dict) else {}
        if event_type == "text" and isinstance(part.get("text"), str) and part["text"]:
            return [{"eventType": "messageDelta", "text": part["text"]}]
        if event_type == "step_finish" and str(part.get("reason") or "").lower() == "stop":
            self.did_finish = True
            return [{"eventType": "completed"}]
        if event_type == "error":
            self.did_finish = True
            return [{"eventType": "failed", "message": json_error_message(value, "OpenCode failed")}]
        return []


class CodexSemanticParser:
    """Turn Codex exec's documented JSONL records into browser Chat events."""

    def __init__(self) -> None:
        self.session_id: str | None = None
        self.did_finish = False

    def consume(self, raw_line: bytes) -> list[dict[str, Any]]:
        value = decode_json_object(raw_line)
        if value is None:
            return []
        event_type = str(value.get("type") or "").lower()
        if event_type == "thread.started":
            session_id = value.get("thread_id")
            if isinstance(session_id, str) and session_id:
                self.session_id = session_id
        if event_type == "item.completed":
            item = value.get("item") if isinstance(value.get("item"), dict) else {}
            text = item.get("text")
            if item.get("type") == "agent_message" and isinstance(text, str) and text:
                return [{"eventType": "messageDelta", "text": text}]
        if event_type == "turn.completed":
            self.did_finish = True
            return [{"eventType": "completed"}]
        if event_type in {"turn.failed", "error"}:
            self.did_finish = True
            return [{"eventType": "failed", "message": json_error_message(value, "Codex failed")}]
        return []


class GeminiSemanticParser:
    """Turn Gemini CLI's documented stream-json records into Chat events."""

    def __init__(self) -> None:
        self.session_id: str | None = None
        self.did_finish = False

    def consume(self, raw_line: bytes) -> list[dict[str, Any]]:
        value = decode_json_object(raw_line)
        if value is None:
            return []
        event_type = str(value.get("type") or "").lower()
        if event_type == "init":
            session_id = value.get("session_id")
            if isinstance(session_id, str) and session_id:
                self.session_id = session_id
        if event_type == "message" and value.get("role") == "assistant":
            text = value.get("content")
            if isinstance(text, str) and text:
                return [{"eventType": "messageDelta", "text": text}]
        if event_type == "result":
            self.did_finish = True
            return [{"eventType": "completed"}]
        if event_type == "error" and str(value.get("severity") or "error").lower() == "error":
            self.did_finish = True
            return [{"eventType": "failed", "message": json_error_message(value, "Gemini failed")}]
        return []


def content_events(value: Any) -> list[dict[str, Any]]:
    if isinstance(value, str) and value:
        return [{"eventType": "messageDelta", "text": value}]
    if not isinstance(value, list):
        return []
    events: list[dict[str, Any]] = []
    for part in value:
        if not isinstance(part, dict) or not isinstance(part.get("text"), str) or not part["text"]:
            continue
        kind = str(part.get("type") or "").lower()
        events.append({
            "eventType": "thinkingDelta" if kind in {"thinking", "reasoning"} else "messageDelta",
            "text": part["text"],
        })
    return events


class PiSemanticParser:
    """Turn Pi's documented JSON event stream into browser Chat events."""

    def __init__(self) -> None:
        self.session_id: str | None = None
        self.did_finish = False

    def consume(self, raw_line: bytes) -> list[dict[str, Any]]:
        value = decode_json_object(raw_line)
        if value is None:
            return []
        events: list[dict[str, Any]] = []
        if str(value.get("type") or "").lower() == "session":
            session_id = value.get("id")
            if isinstance(session_id, str) and session_id:
                self.session_id = session_id
        assistant_event = value.get("assistantMessageEvent") if isinstance(value.get("assistantMessageEvent"), dict) else {}
        delta_type = str(assistant_event.get("type") or "").lower()
        delta = assistant_event.get("delta")
        if isinstance(delta, str) and delta:
            events.append({"eventType": "thinkingDelta" if delta_type == "thinking_delta" else "messageDelta", "text": delta})
        if str(value.get("type") or "").lower() == "agent_end":
            self.did_finish = True
            events.append({"eventType": "completed"})
        if str(value.get("type") or "").lower() == "error":
            self.did_finish = True
            events.append({"eventType": "failed", "message": json_error_message(value, "Pi failed")})
        return events


class GrokSemanticParser:
    """Turn Grok CLI streaming-json records into browser Chat events."""

    def __init__(self) -> None:
        self.session_id: str | None = None
        self.did_finish = False

    def consume(self, raw_line: bytes) -> list[dict[str, Any]]:
        value = decode_json_object(raw_line)
        if value is None:
            return []
        event_type = str(value.get("type") or "").lower()
        if event_type == "text" and isinstance(value.get("data"), str):
            return [{"eventType": "messageDelta", "text": value["data"]}]
        if event_type in {"thought", "thinking"} and isinstance(value.get("data"), str):
            return [{"eventType": "thinkingDelta", "text": value["data"]}]
        if event_type == "end":
            session_id = value.get("sessionId")
            if isinstance(session_id, str) and session_id:
                self.session_id = session_id
            self.did_finish = True
            return [{"eventType": "completed"}]
        if event_type == "error":
            self.did_finish = True
            return [{"eventType": "failed", "message": json_error_message(value, "Grok failed")}]
        return []


class KimiSemanticParser:
    """Turn Kimi's documented stream-json assistant messages into Chat events."""

    def __init__(self) -> None:
        self.session_id: str | None = None
        self.did_finish = False

    def consume(self, raw_line: bytes) -> list[dict[str, Any]]:
        value = decode_json_object(raw_line)
        if value is None:
            return []
        self.session_id = value.get("session_id") or value.get("sessionId") or self.session_id
        events: list[dict[str, Any]] = []
        if str(value.get("role") or "").lower() == "assistant":
            events.extend(content_events(value.get("content")))
        event_type = str(value.get("type") or "").lower()
        if event_type == "error":
            self.did_finish = True
            events.append({"eventType": "failed", "message": json_error_message(value, "Kimi failed")})
        elif event_type in {"end", "completed", "result"}:
            self.did_finish = True
            events.append({"eventType": "completed"})
        return events


class QwenSemanticParser:
    """Turn Qwen Code stream-json records into browser Chat events."""

    def __init__(self) -> None:
        self.session_id: str | None = None
        self.did_finish = False
        self.did_emit_message = False

    def consume(self, raw_line: bytes) -> list[dict[str, Any]]:
        value = decode_json_object(raw_line)
        if value is None:
            return []
        self.session_id = value.get("session_id") or value.get("sessionId") or self.session_id
        events: list[dict[str, Any]] = []
        event_type = str(value.get("type") or "").lower()
        if event_type == "assistant":
            message = value.get("message") if isinstance(value.get("message"), dict) else value
            events.extend(content_events(message.get("content")))
            self.did_emit_message |= any(event.get("eventType") == "messageDelta" for event in events)
        elif event_type == "stream_event":
            nested = value.get("event") if isinstance(value.get("event"), dict) else value
            delta = nested.get("delta")
            delta_type = ""
            if isinstance(delta, dict):
                delta_type = str(delta.get("type") or "").lower()
                delta = delta.get("text") or delta.get("value")
            if isinstance(delta, str) and delta:
                events.append({
                    "eventType": "thinkingDelta" if "thinking" in delta_type else "messageDelta",
                    "text": delta,
                })
                self.did_emit_message |= "thinking" not in delta_type
        elif event_type == "result":
            if not self.did_emit_message and isinstance(value.get("result"), str) and value["result"].strip():
                self.did_emit_message = True
                events.append({"eventType": "messageDelta", "text": value["result"]})
            self.did_finish = True
            if value.get("is_error") is True:
                events.append({"eventType": "failed", "message": json_error_message(value, "Qwen failed")})
            else:
                events.append({"eventType": "completed"})
        elif event_type == "error":
            self.did_finish = True
            events.append({"eventType": "failed", "message": json_error_message(value, "Qwen failed")})
        return events


class AiderSemanticParser:
    """Aider's scripted --message mode is plain streaming text."""

    def __init__(self) -> None:
        self.session_id: str | None = None
        self.did_finish = False

    def consume(self, raw_line: bytes) -> list[dict[str, Any]]:
        text = raw_line.decode("utf-8", errors="replace").replace("\r", "")
        return [{"eventType": "messageDelta", "text": text}] if text else []


def decode_json_object(raw_line: bytes) -> dict[str, Any] | None:
    try:
        value = json.loads(raw_line.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def json_error_message(value: dict[str, Any], fallback: str) -> str:
    message = value.get("message")
    if isinstance(message, str) and message.strip():
        return message
    error = value.get("error")
    if isinstance(error, str) and error.strip():
        return error
    if isinstance(error, dict) and isinstance(error.get("message"), str) and error["message"].strip():
        return error["message"]
    return fallback


def semantic_parser(provider: str) -> Any:
    parsers = {
        "opencode": OpenCodeSemanticParser,
        "pi": PiSemanticParser,
        "commandcode": AiderSemanticParser,
        "chatgpt": CodexSemanticParser,
        "claude": ClaudeSemanticParser,
        "kimi": KimiSemanticParser,
        "qwen": QwenSemanticParser,
        "codex": CodexSemanticParser,
        "aider": AiderSemanticParser,
        "grok": GrokSemanticParser,
        "gemini": GeminiSemanticParser,
    }
    return parsers[provider]()


class PairingState:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.code = ""
        self.expires_at = 0.0
        self._tokens: dict[str, float] = {}
        self.rotate()

    def rotate(self) -> None:
        with self._lock:
            self.code = random_pairing_code()
            self.expires_at = now() + PAIRING_TTL_SECONDS
            # A new pairing code is a new approval window. Existing bearer
            # tokens must not survive a rotate, or a stolen browser session
            # stays valid for the rest of the process lifetime.
            self._tokens.clear()

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return {
                "expiresAt": self.expires_at,
                "pairedClients": len(self._valid_tokens_locked()),
            }

    def pair(self, code: str) -> tuple[str, float] | None:
        with self._lock:
            normalized = normalize_pairing_code(code)
            if (
                normalized is None
                or now() > self.expires_at
                or not secrets.compare_digest(normalized, self.code)
            ):
                return None
            token = secrets.token_urlsafe(32)
            token_expires_at = now() + PAIRED_TOKEN_TTL_SECONDS
            self._tokens[self._digest(token)] = token_expires_at
            # A pairing code is a one-time approval, never a reusable password.
            self.code = random_pairing_code()
            self.expires_at = now() + PAIRING_TTL_SECONDS
            return token, token_expires_at

    def valid_token(self, token: str) -> bool:
        with self._lock:
            self._valid_tokens_locked()
            digest = self._digest(token)
            expires_at = self._tokens.get(digest, 0)
            return bool(token and now() < expires_at)

    @staticmethod
    def _digest(token: str) -> str:
        return hashlib.sha256(token.encode("utf-8")).hexdigest()

    def _valid_tokens_locked(self) -> dict[str, float]:
        current = now()
        self._tokens = {
            digest: expires_at
            for digest, expires_at in self._tokens.items()
            if expires_at > current
        }
        return self._tokens


class TerminalConnection:
    """One authenticated browser connection and its independent PTYs."""

    def __init__(self, host: "VampTerminalHost", sock: socket.socket) -> None:
        self.host = host
        self.sock = sock
        self.send_lock = threading.Lock()
        self.stop_event = threading.Event()
        self.terminals: dict[str, PtyTerminal] = {}

    def send(self, message: dict[str, Any]) -> None:
        if self.stop_event.is_set():
            return
        payload = json_bytes(message)
        try:
            with self.send_lock:
                self.sock.sendall(websocket_frame(payload))
        except OSError:
            self.stop_event.set()

    def send_error(self, code: str, message: str, terminal_id: str | None = None) -> None:
        body: dict[str, Any] = {"type": "error", "code": code, "message": message}
        if terminal_id:
            body["terminalID"] = terminal_id
        self.send(body)

    def open_terminal(self, payload: dict[str, Any]) -> None:
        terminal_id = str(payload.get("terminalID") or uuid.uuid4())
        if len(terminal_id) > 96 or any(character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for character in terminal_id):
            self.send_error("invalid-terminal", "terminalID must contain only letters, numbers, '-' or '_'")
            return
        if terminal_id in self.terminals:
            self.send_error("duplicate-terminal", "That terminal tab is already open", terminal_id)
            return
        if len(self.terminals) >= self.host.max_terminals:
            self.send_error(
                "capacity",
                f"This connection is limited to {self.host.max_terminals} terminals",
                terminal_id,
            )
            return

        title = str(payload.get("title") or "Terminal")[:80]
        try:
            working_directory = self.host.resolve_workspace(payload.get("workingDirectory"))
        except ValueError as error:
            self.send_error("invalid-workspace", str(error), terminal_id)
            return
        terminal = PtyTerminal(self, terminal_id, title, working_directory)
        self.terminals[terminal_id] = terminal
        try:
            terminal.start()
        except OSError as error:
            self.terminals.pop(terminal_id, None)
            self.send_error("spawn-failed", str(error), terminal_id)
            return

        self.send({
            "type": "terminalReady",
            "terminalID": terminal_id,
            "title": title,
            "workingDirectory": str(working_directory),
            "capabilities": {
                "supportsTerminal": True,
                "supportsMultipleTerminals": True,
                "maxTerminals": self.host.max_terminals,
                "supportsClipboard": True,
                "supportsResize": True,
                "supportsWorkspaces": True,
                "supportsChat": True,
                "supportsTaskPlans": False,
                "agentProviders": list(AGENT_PROVIDERS),
            },
        })
        command = payload.get("command")
        if isinstance(command, str) and command.strip():
            terminal.write(command.rstrip() + "\n")

    def close_terminal(self, terminal_id: str, reason: str = "closed", notify: bool = True) -> None:
        terminal = self.terminals.pop(terminal_id, None)
        if terminal:
            terminal.close()
            if notify:
                self.send({"type": "terminalClosed", "terminalID": terminal_id, "reason": reason})
        elif notify:
            self.send_error("unknown-terminal", "No terminal with that ID is open", terminal_id)

    def terminal_exited(self, terminal_id: str, reason: str) -> None:
        terminal = self.terminals.pop(terminal_id, None)
        if terminal:
            self.send({"type": "terminalClosed", "terminalID": terminal_id, "reason": reason})

    def handle(self, payload: dict[str, Any]) -> None:
        message_type = payload.get("type")
        terminal_id = str(payload.get("terminalID") or "")
        if message_type == "open":
            self.open_terminal(payload)
            return
        if message_type == "input":
            terminal = self.terminals.get(terminal_id)
            if not terminal:
                self.send_error("unknown-terminal", "No terminal with that ID is open", terminal_id)
                return
            data = payload.get("data")
            if isinstance(data, str) and len(data) <= 1_000_000:
                terminal.write(data)
            return
        if message_type == "agentPrompt":
            terminal = self.terminals.get(terminal_id)
            if not terminal:
                self.send_error("unknown-terminal", "No terminal with that ID is open", terminal_id)
                return
            provider = payload.get("provider")
            prompt = payload.get("prompt")
            if provider not in AGENT_PROVIDERS:
                self.send_error("unsupported-agent", "That provider does not offer supported semantic Chat", terminal_id)
                return
            if not isinstance(prompt, str) or not prompt.strip() or len(prompt.encode("utf-8")) > MAX_AGENT_PROMPT_BYTES:
                self.send_error("invalid-prompt", "The agent prompt is empty or too large", terminal_id)
                return
            terminal.run_agent_prompt(provider, prompt)
            return
        if message_type == "resize":
            terminal = self.terminals.get(terminal_id)
            if not terminal:
                self.send_error("unknown-terminal", "No terminal with that ID is open", terminal_id)
                return
            terminal.resize(
                clamp(payload.get("cols"), 2, 500, 80),
                clamp(payload.get("rows"), 2, 300, 24),
            )
            return
        if message_type == "close":
            self.close_terminal(terminal_id)
            return
        if message_type == "clipboardSet":
            data = payload.get("data")
            if isinstance(data, str) and len(data) <= 2_000_000:
                self.host.clipboard = data
                self.send({"type": "clipboardChanged", "length": len(data)})
            return
        if message_type == "clipboardGet":
            self.send({"type": "clipboard", "data": self.host.clipboard})
            return
        if message_type == "listWorkspaces":
            self.send({"type": "workspaceList", "workspaces": self.host.workspace_roots()})
            return
        if message_type == "ping":
            self.send({"type": "pong"})
            return
        self.send_error("unsupported-message", f"Unsupported message type: {message_type}")

    def run(self) -> None:
        try:
            self.send({
                "type": "hostReady",
                "product": "Vamp Terminal Linux Host",
                "protocolVersion": 1,
                "maxTerminals": self.host.max_terminals,
                "capabilities": self.host.capabilities(),
            })
            while not self.stop_event.is_set():
                opcode, raw = read_websocket_frame(self.sock)
                if opcode == 0x8:
                    break
                if opcode == 0x9:
                    with self.send_lock:
                        self.sock.sendall(websocket_frame(raw, opcode=0xA))
                    continue
                if opcode != 0x1:
                    continue
                payload = json.loads(raw.decode("utf-8"))
                if isinstance(payload, dict):
                    self.handle(payload)
        except (ConnectionError, OSError, ValueError, json.JSONDecodeError):
            pass
        finally:
            self.stop_event.set()
            for terminal_id in list(self.terminals):
                self.close_terminal(terminal_id, reason="connection-closed", notify=False)
            self.host.remove_connection(self)
            try:
                self.sock.close()
            except OSError:
                pass


class PtyTerminal:
    def __init__(self, connection: TerminalConnection, terminal_id: str, title: str, working_directory: Path) -> None:
        self.connection = connection
        self.terminal_id = terminal_id
        self.title = title
        self.working_directory = working_directory
        self.pid: int | None = None
        self.fd: int | None = None
        self.closed = threading.Event()
        self.agent_lock = threading.Lock()
        self.agent_process: subprocess.Popen[bytes] | None = None
        self.agent_session_ids: dict[str, str] = {}

    def start(self) -> None:
        pid, fd = pty.fork()
        if pid == 0:
            shell = os.environ.get("SHELL", "/bin/bash")
            if not os.path.isabs(shell) or not os.access(shell, os.X_OK):
                shell = "/bin/bash"
            environment = os.environ.copy()
            environment["TERM"] = "xterm-256color"
            environment["COLORTERM"] = "truecolor"
            environment["VAMP_TERMINAL"] = "1"
            os.chdir(self.working_directory)
            os.execvpe(shell, [shell, "-l"], environment)
        self.pid = pid
        self.fd = fd
        self.resize(80, 24)
        threading.Thread(target=self._read_loop, name=f"vamp-pty-{self.terminal_id}", daemon=True).start()

    def write(self, data: str) -> None:
        if self.closed.is_set() or self.fd is None:
            return
        try:
            os.write(self.fd, data.encode("utf-8", errors="replace"))
        except OSError:
            self.close()

    def run_agent_prompt(self, provider: str, prompt: str) -> None:
        with self.agent_lock:
            if self.agent_process is not None and self.agent_process.poll() is None:
                self.connection.send_error("agent-busy", "An agent is still working on the previous message", self.terminal_id)
                return
            launcher_name = {
                "commandcode": "cmd",
                "chatgpt": "codex",
            }.get(provider, provider)
            executable = self._resolve_launcher(launcher_name)
            if executable is None:
                self._send_agent_event(
                    provider,
                    "failed",
                    message=f"{AGENT_DISPLAY_NAMES[provider]} is not installed or is not on PATH",
                )
                return
            arguments = self._agent_arguments(provider, executable, prompt)
            environment = os.environ.copy()
            environment["TERM"] = "dumb"
            environment["NO_COLOR"] = "1"
            environment["PATH"] = os.pathsep.join(self._launcher_search_directories())
            try:
                process = subprocess.Popen(
                    arguments,
                    cwd=self.working_directory,
                    env=environment,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    start_new_session=True,
                )
            except OSError as error:
                self._send_agent_event(provider, "failed", message=str(error))
                return
            self.agent_process = process
        threading.Thread(
            target=self._read_agent,
            args=(provider, process),
            name=f"vamp-{provider}-{self.terminal_id}",
            daemon=True,
        ).start()

    def _agent_arguments(self, provider: str, executable: str, prompt: str) -> list[str]:
        session_id = self.agent_session_ids.get(provider)
        if provider == "opencode":
            arguments = [executable, "run", "--format", "json"]
            if session_id:
                arguments += ["--session", session_id]
            return arguments + ["--", prompt]
        if provider == "pi":
            arguments = [executable, "--mode", "json"]
            if session_id:
                arguments += ["--session", session_id]
            return arguments + ["--", prompt]
        if provider == "commandcode":
            return [executable, "-p", "--skip-onboarding", "--no-auto-update", "--", prompt]
        if provider == "chatgpt":
            if session_id:
                return [
                    executable, "exec", "resume", session_id,
                    "--json", "--skip-git-repo-check", "--", prompt,
                ]
            return [executable, "exec", "--json", "--skip-git-repo-check", "--", prompt]
        if provider == "claude":
            arguments = [
                executable,
                "--print",
                "--verbose",
                "--output-format", "stream-json",
                "--include-partial-messages",
            ]
            if session_id:
                arguments += ["--resume", session_id]
            return arguments + ["--", prompt]
        if provider == "codex":
            if session_id:
                return [
                    executable, "exec", "resume", session_id,
                    "--json", "--skip-git-repo-check", "--", prompt,
                ]
            return [executable, "exec", "--json", "--skip-git-repo-check", "--", prompt]
        if provider == "kimi":
            arguments = [executable, "--output-format", "stream-json"]
            if session_id:
                arguments += ["--session", session_id]
            return arguments + ["--prompt", prompt]
        if provider == "qwen":
            # Linux deliberately stays in the provider's safe plan mode; the
            # browser approval card must never be turned into a blanket
            # unattended approval bypass.
            arguments = [executable, "--output-format", "stream-json", "--include-partial-messages", "--approval-mode", "plan"]
            if session_id:
                arguments += ["--resume", session_id]
            return arguments + ["--prompt", prompt]
        if provider == "aider":
            return [executable, "--message", prompt, "--stream", "--no-pretty", "--no-auto-commits", "--no-check-update"]
        if provider == "grok":
            arguments = [executable, "--output-format", "streaming-json", "--single"]
            if session_id:
                arguments = [executable, "--resume", session_id] + arguments[1:]
            return arguments + ["--", prompt]
        if provider == "gemini":
            arguments = [executable, "--output-format", "stream-json", "--approval-mode", "plan"]
            if session_id:
                arguments += ["--resume", session_id]
            return arguments + ["--prompt", prompt]
        raise ValueError(f"unsupported agent provider: {provider}")

    def _read_agent(self, provider: str, process: subprocess.Popen[bytes]) -> None:
        parser = semantic_parser(provider)
        stderr_chunks: list[bytes] = []

        def drain_stderr() -> None:
            if process.stderr is None:
                return
            try:
                remaining = 64 * 1024
                while remaining > 0:
                    chunk = process.stderr.read(min(8192, remaining))
                    if not chunk:
                        break
                    stderr_chunks.append(chunk)
                    remaining -= len(chunk)
            finally:
                process.stderr.close()

        stderr_thread = threading.Thread(target=drain_stderr, name=f"vamp-{provider}-error-{self.terminal_id}", daemon=True)
        stderr_thread.start()
        if process.stdout is not None:
            try:
                for line in iter(process.stdout.readline, b""):
                    for event in parser.consume(line):
                        self._send_agent_event(provider, **event)
            finally:
                process.stdout.close()
        return_code = process.wait()
        stderr_thread.join(timeout=2)
        if parser.session_id:
            self.agent_session_ids[provider] = parser.session_id
        if not parser.did_finish:
            if return_code == 0:
                self._send_agent_event(provider, "completed")
            else:
                detail = b"".join(stderr_chunks).decode("utf-8", errors="replace").strip()
                self._send_agent_event(
                    provider,
                    "failed",
                    message=detail or f"{AGENT_DISPLAY_NAMES[provider]} exited with status {return_code}",
                )
        with self.agent_lock:
            if self.agent_process is process:
                self.agent_process = None

    def _send_agent_event(self, provider: str, eventType: str, text: str | None = None, message: str | None = None) -> None:
        event: dict[str, Any] = {
            "type": "agentEvent",
            "terminalID": self.terminal_id,
            "provider": provider,
            "eventType": eventType,
        }
        if text is not None:
            event["text"] = text
        if message is not None:
            event["message"] = message
        self.connection.send(event)

    @staticmethod
    def _launcher_search_directories() -> list[str]:
        home = str(Path.home())
        inherited = os.environ.get("PATH", "").split(os.pathsep)
        nvm_bins = sorted(
            (str(path) for path in (Path(home) / ".nvm" / "versions" / "node").glob("*/bin")),
            reverse=True,
        )
        common = [
            "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            f"{home}/.local/bin", f"{home}/bin", f"{home}/.npm-global/bin",
            f"{home}/.opencode/bin", f"{home}/.bun/bin", f"{home}/.cargo/bin",
            f"{home}/.deno/bin", f"{home}/.volta/bin", f"{home}/.asdf/shims",
            f"{home}/.local/share/mise/shims", f"{home}/.local/share/pnpm",
        ]
        seen: set[str] = set()
        return [path for path in inherited + common + nvm_bins if path and not (path in seen or seen.add(path))]

    @classmethod
    def _resolve_launcher(cls, name: str) -> str | None:
        return shutil.which(name, path=os.pathsep.join(cls._launcher_search_directories()))

    def resize(self, cols: int, rows: int) -> None:
        if self.closed.is_set() or self.fd is None:
            return
        import fcntl
        import termios

        size = struct.pack("HHHH", rows, cols, 0, 0)
        try:
            fcntl.ioctl(self.fd, termios.TIOCSWINSZ, size)
        except OSError:
            pass

    def close(self) -> None:
        if self.closed.is_set():
            return
        self.closed.set()
        with self.agent_lock:
            agent_process = self.agent_process
        if agent_process is not None and agent_process.poll() is None:
            try:
                os.killpg(agent_process.pid, signal.SIGTERM)
            except OSError:
                pass
        if self.pid:
            try:
                os.killpg(self.pid, signal.SIGTERM)
            except OSError:
                pass
            threading.Thread(target=self._reap, name=f"vamp-reap-{self.terminal_id}", daemon=True).start()
        if self.fd is not None:
            try:
                os.close(self.fd)
            except OSError:
                pass
            self.fd = None

    def _read_loop(self) -> None:
        assert self.fd is not None
        try:
            while not self.closed.is_set():
                output = os.read(self.fd, 64 * 1024)
                if not output:
                    break
                self.connection.send({
                    "type": "terminalOutput",
                    "terminalID": self.terminal_id,
                    "encoding": "base64",
                    "data": base64.b64encode(output).decode("ascii"),
                })
        except OSError:
            pass
        finally:
            if not self.closed.is_set():
                self.closed.set()
                self.connection.terminal_exited(self.terminal_id, "process-exited")
            threading.Thread(target=self._reap, name=f"vamp-reap-{self.terminal_id}", daemon=True).start()

    def _reap(self) -> None:
        if not self.pid:
            return
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass


class VampTerminalHost:
    def __init__(self, max_terminals: int) -> None:
        self.max_terminals = max(1, min(max_terminals, 8))
        self.pairing = PairingState()
        self.clipboard = ""
        self._lock = threading.Lock()
        self.connections: set[TerminalConnection] = set()

    def capabilities(self) -> dict[str, Any]:
        return {
            "terminal": True,
            "multipleTerminals": True,
            "maxTerminals": self.max_terminals,
            "clipboard": True,
            "resize": True,
            "workspaces": True,
            "chat": True,
            "agentProviders": list(AGENT_PROVIDERS),
            "taskPlans": False,
            "remoteControl": False,
        }

    def workspace_roots(self) -> list[dict[str, str]]:
        home = Path.home().resolve()
        candidates = [("Home", home)] + [
            (name, home / name)
            for name in ("Desktop", "Documents", "Downloads", "Developer", "Projects", "Sites")
        ]
        return [
            {"name": name, "path": str(path.resolve())}
            for name, path in candidates
            if path.is_dir() and os.access(path, os.R_OK | os.X_OK)
        ]

    def resolve_workspace(self, raw_path: Any) -> Path:
        home = Path.home().resolve()
        if raw_path in (None, "", "~"):
            return home
        if not isinstance(raw_path, str) or "\x00" in raw_path:
            raise ValueError("The workspace path is invalid")
        candidate = Path(os.path.expanduser(raw_path)).resolve(strict=True)
        if not candidate.is_dir():
            raise ValueError("The workspace is not a directory")
        if candidate != home and home not in candidate.parents:
            raise ValueError("The workspace must be inside the current user's home directory")
        if not os.access(candidate, os.R_OK | os.X_OK):
            raise ValueError("The workspace is not readable")
        return candidate

    def add_connection(self, connection: TerminalConnection) -> None:
        with self._lock:
            self.connections.add(connection)

    def remove_connection(self, connection: TerminalConnection) -> None:
        with self._lock:
            self.connections.discard(connection)

    def status(self) -> dict[str, Any]:
        with self._lock:
            terminal_count = sum(len(connection.terminals) for connection in self.connections)
            connection_count = len(self.connections)
        return {
            "product": "Vamp Terminal Linux Host",
            "version": VERSION,
            "protocolVersion": 1,
            "maxTerminalsPerConnection": self.max_terminals,
            "connections": connection_count,
            "terminals": terminal_count,
            "pairing": self.pairing.snapshot(),
            "capabilities": self.capabilities(),
        }

    def close(self) -> None:
        with self._lock:
            connections = list(self.connections)
        for connection in connections:
            connection.stop_event.set()
            try:
                connection.sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


class RequestHandler(http.server.BaseHTTPRequestHandler):
    # WebSocket upgrades are carried over HTTP/1.1. BaseHTTPRequestHandler
    # defaults to HTTP/1.0, which some local clients tolerate but reverse
    # proxies such as Cloudflare Tunnel do not reliably upgrade.
    protocol_version = "HTTP/1.1"
    server: "VampHTTPServer"

    def log_message(self, format: str, *args: Any) -> None:
        return

    def _send_json(self, status: int, value: Any) -> None:
        body = json_bytes(value)
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/api/status":
            self._send_json(200, self.server.host.status())
            return
        if parsed.path == "/ws":
            self._upgrade_websocket(parsed)
            return
        if parsed.path in ("/", "/index.html"):
            self._serve_file(ROOT / "index.html", "text/html; charset=utf-8")
            return
        self._send_json(404, {"error": "not-found"})

    def do_POST(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/api/pair":
            self._send_json(404, {"error": "not-found"})
            return
        if not self.server.allow_pair_attempt(self.client_address[0]):
            self._send_json(429, {"error": "too-many-attempts"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length > 8_192:
                raise ValueError("request too large")
            body = json.loads(self.rfile.read(length).decode("utf-8"))
            code = str(body.get("code", ""))
        except (ValueError, TypeError, json.JSONDecodeError):
            self._send_json(400, {"error": "invalid-json"})
            return
        if not origin_allowed(self.headers.get("Origin"), self.headers.get("Host")):
            self._send_json(403, {"error": "origin-not-allowed"})
            return
        pairing_result = self.server.host.pairing.pair(code)
        if pairing_result is None:
            self._send_json(403, {"error": "invalid-or-expired-code"})
            return
        token, token_expires_at = pairing_result
        print(
            f"New pairing code: {self.server.host.pairing.code} "
            f"(expires in {PAIRING_TTL_SECONDS // 60} minutes)",
            flush=True,
        )
        self._send_json(200, {"token": token, "expiresAt": token_expires_at})

    def _serve_file(self, path: Path, content_type: str) -> None:
        try:
            body = path.read_bytes()
        except OSError:
            self._send_json(404, {"error": "missing-asset"})
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(body)

    def _upgrade_websocket(self, parsed: urllib.parse.ParseResult) -> None:
        # The bearer token travels in the Sec-WebSocket-Protocol handshake
        # header (a subprotocol list: fixed name followed by the token) rather
        # than a ?token= URL query. URLs leak into browser history, referrer
        # headers, and any intermediary logs; handshake headers do not.
        protocols = [
            part.strip()
            for part in (self.headers.get("Sec-WebSocket-Protocol") or "").split(",")
        ]
        token = ""
        if len(protocols) >= 2 and protocols[0] == WEBSOCKET_AUTH_PROTOCOL:
            token = protocols[1]
        if not origin_allowed(self.headers.get("Origin"), self.headers.get("Host")):
            self._send_json(403, {"error": "origin-not-allowed"})
            return
        if not self.server.host.pairing.valid_token(token):
            self._send_json(403, {"error": "pair-first"})
            return
        key = self.headers.get("Sec-WebSocket-Key")
        if not key or self.headers.get("Upgrade", "").lower() != "websocket":
            self._send_json(400, {"error": "websocket-upgrade-required"})
            return
        accept = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
        ).decode("ascii")
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        # Echo the negotiated subprotocol name only; never the token.
        self.send_header("Sec-WebSocket-Protocol", WEBSOCKET_AUTH_PROTOCOL)
        self.end_headers()
        self.close_connection = True
        connection = TerminalConnection(self.server.host, self.connection)
        self.server.host.add_connection(connection)
        connection.run()


class VampHTTPServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], host: VampTerminalHost) -> None:
        self.host = host
        self._pair_attempts: dict[str, collections.deque[float]] = {}
        self._pair_attempts_lock = threading.Lock()
        super().__init__(address, RequestHandler)

    def allow_pair_attempt(self, address: str) -> bool:
        current = now()
        with self._pair_attempts_lock:
            attempts = self._pair_attempts.setdefault(address, collections.deque())
            while attempts and attempts[0] <= current - PAIRING_ATTEMPT_WINDOW_SECONDS:
                attempts.popleft()
            if len(attempts) >= PAIRING_MAX_ATTEMPTS:
                return False
            attempts.append(current)
            return True


def origin_allowed(origin: str | None, host_header: str | None) -> bool:
    """Same-origin rule used by the Mac Safari host.

    Native clients may omit Origin. A browser page on another origin must not
    be able to submit the visible pairing code or upgrade a WebSocket.
    """
    value = (origin or "").strip()
    if not value:
        return True
    if value.lower() == "null":
        return False
    expected = (host_header or "").strip().lower()
    if not expected:
        return False
    parsed = urllib.parse.urlsplit(value)
    scheme = (parsed.scheme or "").lower()
    if scheme not in ("http", "https"):
        return False
    host = (parsed.hostname or "").lower()
    if not host:
        return False
    default_port = 443 if scheme == "https" else 80
    port = parsed.port or default_port
    origin_authority = host if port == default_port else f"{host}:{port}"
    return origin_authority == expected


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the Vamp Terminal Linux browser host")
    parser.add_argument("--listen", default="127.0.0.1", help="Bind address; loopback is the safe default")
    parser.add_argument(
        "--allow-non-loopback",
        action="store_true",
        help="Permit --listen on a non-loopback address. Prefer Tailscale Serve instead.",
    )
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--max-terminals", type=int, default=DEFAULT_MAX_TERMINALS)
    parser.add_argument("--version", action="version", version=f"vamp-terminal-host {VERSION}")
    return parser.parse_args(argv)


def main() -> int:
    args = parse_args()
    if not 1 <= args.port <= 65535:
        raise SystemExit("--port must be between 1 and 65535")
    validate_listen_address(args.listen, args.allow_non_loopback)
    if args.listen not in LOOPBACK_BIND_ADDRESSES:
        print("warning: non-loopback binding is unsafe; prefer Tailscale Serve over a public listener", flush=True)

    host = VampTerminalHost(args.max_terminals)
    server = VampHTTPServer((args.listen, args.port), host)
    print("Vamp Linux Host", VERSION, flush=True)
    print(f"Local URL: http://{args.listen}:{args.port}/", flush=True)
    print(f"Pairing code: {host.pairing.code} (expires in {PAIRING_TTL_SECONDS // 60} minutes)", flush=True)
    print("Remote access (Tailscale): tailscale serve --bg http://127.0.0.1:%d" % args.port, flush=True)
    print("Remote access (Cloudflare Access): cloudflared tunnel run vamp-terminal", flush=True)

    def stop(_signum: int, _frame: Any) -> None:
        host.close()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    try:
        server.serve_forever()
    finally:
        host.close()
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
