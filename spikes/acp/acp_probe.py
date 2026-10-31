#!/usr/bin/env python3
"""Spike for #1076: drive an ACP (Agent Client Protocol) agent the way a haild plug would, and record shapes.

Usage:
  python3 acp_probe.py --cwd <scratch dir> [--mode MODE] [--list] [--load] [--prompt TEXT ...] [--show-text]
                       -- <agent command and args>

Round 2 (#1076): --mode switches the new session into a mode that asks before acting (session/set_mode), so the
permission requests can be recorded; --list calls session/list; --load restarts the agent and resumes the
session with session/load, then asks one question that needs the earlier turns.

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
- The agent's own stderr goes to <cwd>/agent-stderr.log (agent-stderr-resume.log for the --load process), which is
  never printed: it may hold private detail.

Exit codes: 0 done, 2 initialize failed, 3 session/new failed, 4 scratch directory already used, 5 --mode not
applied, 6 a timed-out prompt's cancellation was not confirmed (later prompts skipped).

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
    "Run the shell command `touch acp-exec-probe.txt` in the current directory.",
)
# Marker files the write and shell prompts would create; if either exists afterwards, the action ran.
MARKERS = {"write": "acp-probe.txt", "execute": "acp-exec-probe.txt"}
RESUME_PROMPT = "In one short sentence, what was the first thing I asked you in this session? Use no tools."


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
    def __init__(self, command: list, cwd: str, log_name: str = "agent-stderr.log"):
        environment = dict(os.environ)
        self.removed = sorted(name for name in CREDENTIAL_VARIABLES if environment.pop(name, None) is not None)
        self.stderr = open(os.path.join(cwd, log_name), "wb")
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
        # The direct child may already be reaped while a grandchild lives on, so signal the whole group, give it
        # a moment, then make sure with SIGKILL. A group that is already gone raises ProcessLookupError.
        for sig, pause in ((signal.SIGTERM, 1.0), (signal.SIGKILL, 0)):
            try:
                os.killpg(self.process.pid, sig)
            except (ProcessLookupError, PermissionError):
                break
            time.sleep(pause)
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        self.stderr.close()


class Probe:
    def __init__(self, agent: Agent, show_text: bool):
        self.agent = agent
        self.show_text = show_text
        self.update_kinds: dict = {}
        # Set when a timed-out prompt's cancellation could not be confirmed: the agent may still be working on
        # it, so anything sent afterwards would overlap it and its late output would be misattributed.
        self.unsettled = False

    def answer_agent_request(self, message: dict) -> None:
        method = message.get("method", "")
        if method == "session/request_permission":
            params = message.get("params") or {}
            options = params.get("options") or []
            tool_call = params.get("toolCall") or {}
            emit("permission_request", {
                "params_keys": sorted(params.keys()),
                "tool_call_keys": sorted(tool_call.keys()),
                "tool_kind": tool_call.get("kind"),
                "tool_title_chars": len(tool_call.get("title") or ""),
                "raw_input_shape": shape(tool_call.get("rawInput"), 1),
                "options": [{"kind": option.get("kind"), "name_chars": len(option.get("name", "")),
                             "option_id_chars": len(str(option.get("optionId", "")))} for option in options],
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
        the next prompt's timings. Agent requests are still answered; updates are counted under their kind, with
        timings discarded."""
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
            elif message.get("method") == "session/update":
                self.note_update(message.get("params") or {}, time.monotonic(), {})
            elif message.get("id") == request_id:
                emit("cancelled_prompt_response", (message.get("result") or {}).get("stopReason"))
                return
        self.unsettled = True
        emit("cancel_drain_timeout", {"seconds": seconds, "session": "unsettled; nothing more is sent to it"})

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


def initialize(probe: Probe) -> Optional[dict]:
    """Initialize the agent. Returns the initialize result, or None on failure."""
    emit("credential_variables_removed", probe.agent.removed)
    response, timings = probe.call("initialize", {
        "protocolVersion": PROTOCOL_VERSION,
        "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False},
        "clientInfo": {"name": "hailing-station-acp-probe", "version": "0.2"},
    }, 60)
    if not response or "error" in response:
        emit("initialize_failed", outcome_of(response))
        return None
    result = response.get("result") or {}
    emit("initialize", {
        "protocolVersion": result.get("protocolVersion"),
        "agentInfo": result.get("agentInfo"),
        "agentCapabilities": result.get("agentCapabilities"),
        "authMethods": [{"id": method.get("id"), "name": method.get("name")}
                        for method in result.get("authMethods") or []],
        "seconds": timings.get("response"),
    })
    return result


def outcome_of(response: Optional[dict]) -> Any:
    if response is None:
        return None
    if "error" in response:
        error = response.get("error") or {}
        return {"error": error.get("code"), "message_chars": len(str(error.get("message", "")))}
    return (response.get("result") or {}).get("stopReason")


def prompt(probe: Probe, session_id: Any, index: Any, text: str, timeout: float) -> None:
    if probe.agent.exited or probe.unsettled:
        reason = "agent exited" if probe.agent.exited else "an earlier prompt's cancellation was not confirmed"
        emit("prompt_skipped", {"prompt": index, "reason": reason})
        return
    response, timings = probe.call("session/prompt", {
        "sessionId": session_id, "prompt": [{"type": "text", "text": text}]}, timeout)
    emit("prompt_done", {"prompt": index, "stopReason": outcome_of(response), "timings": timings})


def report_modes(session: dict) -> list:
    modes = session.get("modes") or {}
    available = [mode.get("id") for mode in modes.get("availableModes") or []]
    emit("session_modes", {"current": modes.get("currentModeId"), "available": available})
    models = session.get("models") or {}
    emit("session_models", {"current": models.get("currentModelId"),
                            "available_count": len(models.get("availableModels") or [])})
    options = session.get("configOptions")
    if options is not None:
        emit("config_options_shape", shape(options, 2))
    return available


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cwd", required=True, help="scratch directory the agent session runs in")
    parser.add_argument("--prompt", action="append", help="prompt text (repeatable); defaults to three probes")
    parser.add_argument("--mode", help="switch the new session into this mode (session/set_mode) before prompting")
    parser.add_argument("--list", action="store_true", help="call session/list after the prompts")
    parser.add_argument("--load", action="store_true", help="restart the agent and resume the session (session/load)")
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--show-text", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER, help="-- then the agent command")
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("give the agent command after --")
    cwd = os.path.abspath(args.cwd)
    os.makedirs(cwd, exist_ok=True)
    stale = [kind for kind, name in MARKERS.items() if os.path.exists(os.path.join(cwd, name))]
    if stale:
        emit("refused", {"reason": "marker files already exist; use a fresh scratch directory", "markers": stale})
        return 4

    agent = Agent(command, cwd)
    probe = Probe(agent, args.show_text)
    try:
        if initialize(probe) is None:
            return 2
        response, timings = probe.call("session/new", {"cwd": cwd, "mcpServers": []}, 120)
        if not response or "error" in response:
            emit("session_new_failed", outcome_of(response))
            return 3
        session = response.get("result") or {}
        session_id = session.get("sessionId")
        emit("session_new", {"result_shape": shape(session), "seconds": timings.get("response")})
        available = report_modes(session)

        if args.mode:
            # Without the requested mode, any permission evidence would be misattributed, and the agent's own mode
            # might run the write and shell prompts unasked: stop before prompting.
            if args.mode not in available:
                emit("set_mode_skipped", {"mode": args.mode, "reason": "not offered by the agent; no prompts sent"})
                return 5
            response, timings = probe.call("session/set_mode", {"sessionId": session_id, "modeId": args.mode}, 30)
            applied = bool(response and "result" in response)
            emit("set_mode", {"mode": args.mode, "outcome": "ok" if applied else outcome_of(response),
                              "seconds": timings.get("response")})
            if not applied:
                emit("prompts_skipped", "the requested mode was not applied")
                return 5

        for index, text in enumerate(args.prompt or DEFAULT_PROMPTS, 1):
            prompt(probe, session_id, index, text, args.timeout)
        emit("actions_ran", {kind: os.path.exists(os.path.join(cwd, name)) for kind, name in MARKERS.items()})

        if args.list and not agent.exited and not probe.unsettled:
            response, timings = probe.call("session/list", {"cwd": cwd}, 30)
            result = (response or {}).get("result") or {}
            sessions = result.get("sessions") or []
            emit("session_list", {"outcome": "ok" if response and "result" in response else outcome_of(response),
                                  "result_shape": shape(result, 2), "count": len(sessions),
                                  "contains_this_session": any(isinstance(item, dict) and item.get("sessionId") == session_id
                                                               for item in sessions),
                                  "seconds": timings.get("response")})
        emit("update_kind_counts", probe.update_kinds)
    finally:
        agent.close()

    if args.load:
        resume(command, cwd, args, session_id)
    # 6: a prompt timed out and its cancellation was never confirmed, so later prompts were not sent.
    return 6 if probe.unsettled else 0


def resume(command: list, cwd: str, args, session_id: Any) -> None:
    """A fresh agent process resumes the session, then answers a question that needs the earlier turns."""
    emit("resume", "starting a fresh agent process")
    agent = Agent(command, cwd, log_name="agent-stderr-resume.log")
    probe = Probe(agent, args.show_text)
    try:
        initialized = initialize(probe)
        if initialized is None:
            return
        if not (initialized.get("agentCapabilities") or {}).get("loadSession"):
            emit("load_skipped", "agent does not advertise loadSession")
            return
        response, timings = probe.call("session/load", {"sessionId": session_id, "cwd": cwd, "mcpServers": []}, 120)
        emit("session_load", {"outcome": "ok" if response and "result" in response else outcome_of(response),
                              "result_shape": shape((response or {}).get("result"), 2),
                              "replayed_update_kinds": dict(probe.update_kinds), "seconds": timings.get("response")})
        if response and "result" in response:
            probe.update_kinds = {}
            prompt(probe, session_id, "resume", RESUME_PROMPT, args.timeout)
            emit("resume_update_kind_counts", probe.update_kinds)
    finally:
        agent.close()


if __name__ == "__main__":
    sys.exit(main())
