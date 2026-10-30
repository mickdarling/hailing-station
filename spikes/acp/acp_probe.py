#!/usr/bin/env python3
"""Spike for #1076: drive an ACP (Agent Client Protocol) agent the way a haild plug would, and record shapes.

Usage:
  python3 acp_probe.py --cwd <scratch dir> [--prompt TEXT ...] [--show-text] -- <agent command and args>

What it does:
- Starts the agent with stdio pipes and an environment with provider credential variables removed, so the
  harness must use its own stored login (the seat principle, #1074). It reports which variables were removed,
  by name only.
- Speaks JSON-RPC 2.0 as newline-delimited JSON: initialize, session/new, then one session/prompt per --prompt.
- Advertises no filesystem or terminal capability. Any fs/* or terminal/* request is refused (-32601).
- Answers session/request_permission by choosing a reject option (reject_once, else reject_always), or
  cancelled if none exists. Nothing the agent asks permission for is ever allowed.
- Prints one JSON line per observation to stdout: method names, update kinds, keys, lengths and timings.
  Message text appears only as character counts. --show-text prints agent text to stderr, for synthetic
  prompts only; never paste it.
- The agent's own stderr goes to <cwd>/agent-stderr.log, which is never printed: it may hold private detail.

Standard library only; Python 3.9+.
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import signal
import subprocess
import sys
import threading
import time
from typing import Any, Optional

PROTOCOL_VERSION = 1
# Credentials only. Configuration (base URLs, provider switches) is the harness's own business under the
# seat principle and is left alone.
CREDENTIAL_VARIABLES = (
    "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY",
)
DEFAULT_PROMPTS = (
    "Hailing Station ACP spike #1076. Reply with one short sentence and use no tools.",
    "Create a file named acp-probe.txt containing the word hello in the current directory.",
)


def emit(label: str, value: Any) -> None:
    print(json.dumps({label: value}, sort_keys=True), flush=True)


def shape(value: Any, depth: int = 3) -> Any:
    if isinstance(value, dict):
        return "{…}" if depth <= 0 else {key: shape(item, depth - 1) for key, item in value.items()}
    if isinstance(value, list):
        if depth <= 0:
            return "[…]"
        return [shape(value[0], depth - 1)] if value else []
    return type(value).__name__


def text_of(content: Any) -> str:
    if isinstance(content, dict):
        return content.get("text", "") if content.get("type") == "text" else ""
    if isinstance(content, list):
        return "".join(text_of(item) for item in content)
    return ""


class Agent:
    def __init__(self, command: list, cwd: str):
        environment = dict(os.environ)
        self.removed = sorted(name for name in CREDENTIAL_VARIABLES if environment.pop(name, None) is not None)
        self.stderr = open(os.path.join(cwd, "agent-stderr.log"), "wb")
        # Its own process group, so close() also stops a harness that an npx or node wrapper started.
        self.process = subprocess.Popen(
            command, cwd=cwd, env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
            start_new_session=True,
        )
        self.exited = False
        self.inbox: "queue.Queue[Optional[dict]]" = queue.Queue()
        self.next_id = 0
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self) -> None:
        assert self.process.stdout is not None
        for raw in self.process.stdout:
            line = raw.decode("utf-8", "replace").strip()
            if not line:
                continue
            try:
                self.inbox.put(json.loads(line))
            except ValueError:
                self.inbox.put({"_unparsed": len(line)})
        self.inbox.put(None)

    def send(self, message: dict) -> None:
        if self.exited:
            return
        assert self.process.stdin is not None
        try:
            self.process.stdin.write((json.dumps(message) + "\n").encode("utf-8"))
            self.process.stdin.flush()
        except (BrokenPipeError, ValueError):
            self.exited = True

    def request(self, method: str, params: dict) -> int:
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})
        return self.next_id

    def close(self) -> None:
        try:
            if self.process.stdin:
                self.process.stdin.close()
            self.process.wait(timeout=5)
        except Exception:
            pass
        try:
            os.killpg(self.process.pid, signal.SIGTERM)
            self.process.wait(timeout=5)
        except (ProcessLookupError, PermissionError):
            pass
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGKILL)
        self.stderr.close()


class Probe:
    def __init__(self, agent: Agent, show_text: bool):
        self.agent = agent
        self.show_text = show_text
        self.update_kinds: dict = {}

    def answer_agent_request(self, message: dict) -> None:
        method = message.get("method", "")
        if method == "session/request_permission":
            params = message.get("params") or {}
            options = params.get("options") or []
            emit("permission_request", {
                "tool_call_keys": sorted((params.get("toolCall") or {}).keys()),
                "tool_kind": (params.get("toolCall") or {}).get("kind"),
                "options": [{"kind": option.get("kind"), "name_chars": len(option.get("name", ""))}
                            for option in options],
            })
            chosen = next((option for kind in ("reject_once", "reject_always")
                           for option in options if option.get("kind") == kind), None)
            outcome = ({"outcome": "selected", "optionId": chosen.get("optionId")} if chosen
                       else {"outcome": "cancelled"})
            emit("permission_answer", outcome.get("outcome") if not chosen else chosen.get("kind"))
            self.agent.send({"jsonrpc": "2.0", "id": message["id"], "result": {"outcome": outcome}})
            return
        emit("refused_agent_request", method)
        self.agent.send({"jsonrpc": "2.0", "id": message["id"],
                         "error": {"code": -32601, "message": "not supported by this client"}})

    def note_update(self, params: dict, started: float, timings: dict) -> None:
        update = params.get("update") or {}
        kind = update.get("sessionUpdate", "?")
        if kind not in self.update_kinds:
            self.update_kinds[kind] = 0
            emit("new_update_shape", {"kind": kind, "shape": shape(update)})
        self.update_kinds[kind] += 1
        elapsed = round(time.monotonic() - started, 2)
        detail: dict = {"kind": kind, "t": elapsed}
        if kind in ("agent_message_chunk", "agent_thought_chunk", "user_message_chunk"):
            text = text_of(update.get("content"))
            detail["text_chars"] = len(text)
            if kind == "agent_message_chunk":
                timings.setdefault("first_agent_text", elapsed)
                if self.show_text and text:
                    print(f"[agent text, do not paste] {text}", file=sys.stderr, flush=True)
        if kind in ("tool_call", "tool_call_update"):
            detail.update({"tool_" + key: update.get(key) for key in ("kind", "status") if key in update})
        if kind == "available_commands_update":
            detail["commands"] = len(update.get("availableCommands") or [])
        emit("update", detail)

    def drain(self, request_id: int, seconds: float) -> None:
        """After session/cancel, wait for the cancelled prompt's response so its late updates do not land in
        the next prompt's timings. Agent requests are still answered; updates are counted, not timed."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                message = self.agent.inbox.get(timeout=0.5)
            except queue.Empty:
                continue
            if message is None:
                self.agent.exited = True
                return
            if "method" in message and "id" in message:
                self.answer_agent_request(message)
            elif message.get("id") == request_id:
                emit("cancelled_prompt_response", (message.get("result") or {}).get("stopReason"))
                return
        emit("cancel_drain_timeout", seconds)

    def call(self, method: str, params: dict, timeout: float) -> tuple[Optional[dict], dict]:
        """Send a request and pump agent traffic until its response arrives. Returns (response, timings)."""
        started = time.monotonic()
        request_id = self.agent.request(method, params)
        timings: dict = {}
        deadline = started + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                emit("timeout", {"method": method, "seconds": timeout})
                if method == "session/prompt":
                    self.agent.send({"jsonrpc": "2.0", "method": "session/cancel",
                                     "params": {"sessionId": params.get("sessionId")}})
                    self.drain(request_id, 15)
                return None, timings
            try:
                message = self.agent.inbox.get(timeout=min(remaining, 1.0))
            except queue.Empty:
                continue
            if message is None:
                self.agent.exited = True
                emit("agent_exited", {"code": self.agent.process.poll(), "during": method})
                return None, timings
            if "_unparsed" in message:
                emit("unparsed_line_chars", message["_unparsed"])
            elif "method" in message and "id" in message:
                self.answer_agent_request(message)
            elif message.get("method") == "session/update":
                self.note_update(message.get("params") or {}, started, timings)
            elif "method" in message:
                emit("notification", message.get("method"))
            elif message.get("id") == request_id:
                timings["response"] = round(time.monotonic() - started, 2)
                return message, timings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cwd", required=True, help="scratch directory the agent session runs in")
    parser.add_argument("--prompt", action="append", help="prompt text (repeatable); defaults to two probes")
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--show-text", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER, help="-- then the agent command")
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("give the agent command after --")
    cwd = os.path.abspath(args.cwd)
    os.makedirs(cwd, exist_ok=True)

    agent = Agent(command, cwd)
    emit("credential_variables_removed", agent.removed)
    probe = Probe(agent, args.show_text)
    try:
        response, timings = probe.call("initialize", {
            "protocolVersion": PROTOCOL_VERSION,
            "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False},
            "clientInfo": {"name": "hailing-station-acp-probe", "version": "0.1"},
        }, 60)
        if not response or "error" in response:
            emit("initialize_failed", (response or {}).get("error"))
            return 2
        result = response.get("result") or {}
        emit("initialize", {
            "protocolVersion": result.get("protocolVersion"),
            "agentInfo": result.get("agentInfo"),
            "agentCapabilities": result.get("agentCapabilities"),
            "authMethods": [{"id": method.get("id"), "name": method.get("name")}
                            for method in result.get("authMethods") or []],
            "seconds": timings.get("response"),
        })

        response, timings = probe.call("session/new", {"cwd": cwd, "mcpServers": []}, 120)
        if not response or "error" in response:
            error = (response or {}).get("error") or {}
            emit("session_new_failed", {"code": error.get("code"), "message": error.get("message")})
            return 3
        session = response.get("result") or {}
        emit("session_new", {"result_shape": shape(session), "seconds": timings.get("response")})
        modes = session.get("modes") or {}
        models = session.get("models") or {}
        emit("session_modes", {"current": modes.get("currentModeId"),
                               "available": [mode.get("id") for mode in modes.get("availableModes") or []]})
        emit("session_models", {"current": models.get("currentModelId"),
                                "available": [model.get("modelId") for model in models.get("availableModels") or []]})

        for index, text in enumerate(args.prompt or DEFAULT_PROMPTS, 1):
            if agent.exited:
                emit("prompt_skipped", {"prompt": index, "reason": "agent exited"})
                continue
            response, timings = probe.call("session/prompt", {
                "sessionId": session.get("sessionId"),
                "prompt": [{"type": "text", "text": text}],
            }, args.timeout)
            outcome = None
            if response is not None:
                outcome = (response.get("result") or {}).get("stopReason") if "result" in response \
                    else {"error": (response.get("error") or {}).get("code")}
            emit("prompt_done", {"prompt": index, "stopReason": outcome, "timings": timings})
        probe_file = os.path.join(cwd, "acp-probe.txt")
        emit("probe_file_written", os.path.exists(probe_file))
        emit("update_kind_counts", probe.update_kinds)
        return 0
    finally:
        agent.close()


if __name__ == "__main__":
    sys.exit(main())
