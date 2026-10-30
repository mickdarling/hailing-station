#!/usr/bin/env python3
"""Spike for #1073: reach a Claude Code cloud session from the Mac, the way haild would.

Sending uses only the documented CLI: `claude -p <text> --cloud <id> --output-format json`.
Reading uses the private, undocumented sessions events API (GET only), as mapped by
https://github.com/ThatCrispyToast/claude-rc-api. It can change or break at any time.

Safety rules this script keeps:
- The claude.ai token is read from the Keychain (or ~/.claude/.credentials.json) at the moment of use.
  It is never printed, written, logged or refreshed. Refresh tokens rotate, and refreshing here could
  sign the CLI out. If the token has expired, the script stops and says so.
- Output is meant to be pasteable into the public issue: session and organization IDs are redacted, and
  conversation text is replaced by its length. --show-text prints assistant text to stderr for synthetic
  test messages only; never paste that.
- The only write is the documented CLI send. No API call changes a session.

Run with python3 (3.9+, the macOS system Python is fine); no packages needed.

Subcommands:
  info       token status (expiry, scopes) and the session's metadata shape
  history    shapes of the newest events in the session
  send       documented CLI send only; records the JSON result or refusal (use on an archived session)
  roundtrip  note the newest event, send, then stream until the turn ends; reports timings and shapes
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Iterator, Optional

API = "https://api.anthropic.com"
KEYCHAIN_SERVICE = "Claude Code-credentials"
# The reference says any other value makes a message look like a peer message (2.1.220+). Reads only here,
# but keep the header to the documented-working set.
CLIENT_PLATFORM = "web_claude_ai"
SYNTHETIC_TEXT = "Hailing Station spike #1073 synthetic ping. Reply with one short sentence."


class SpikeError(Exception):
    pass


def redact(value: Optional[str]) -> str:
    if not value:
        return "<none>"
    prefix = value.split("_", 1)[0] + "_" if "_" in value else ""
    return f"{prefix}…{value[-4:]}" if len(value) > 8 else "<redacted>"


# ---------------------------------------------------------------- credentials (read-only, never refreshed)

def load_credentials() -> tuple[str, float, Optional[str], list]:
    raw = None
    if sys.platform == "darwin":
        found = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True,
        )
        if found.returncode == 0:
            raw = found.stdout.strip()
    if raw is None:
        path = os.path.expanduser("~/.claude/.credentials.json")
        if os.path.exists(path):
            with open(path, encoding="utf-8") as handle:
                raw = handle.read()
    if raw is None:
        raise SpikeError("no Claude Code credentials found; run `claude auth login` first")
    credentials = json.loads(raw)
    oauth = credentials.get("claudeAiOauth") or {}
    token = oauth.get("accessToken")
    if not token:
        raise SpikeError("credentials hold no claude.ai OAuth access token (API-key logins cannot use this API)")
    expires = float(oauth.get("expiresAt") or 0)
    expires_at = expires / 1000 if expires > 1e12 else expires
    organization = None
    try:
        with open(os.path.expanduser("~/.claude.json"), encoding="utf-8") as handle:
            organization = (json.load(handle).get("oauthAccount") or {}).get("organizationUuid")
    except (OSError, ValueError):
        pass
    organization = organization or credentials.get("organizationUuid")
    return token, expires_at, organization, list(oauth.get("scopes") or [])


def require_fresh(expires_at: float) -> None:
    remaining = expires_at - time.time()
    if expires_at and remaining <= 60:
        raise SpikeError(
            "the claude.ai token has expired or is about to; this script never refreshes it. "
            "Run any claude command that talks to the service (for example the `send` subcommand), "
            "then retry, and note in the issue whether the CLI refreshed it"
        )


# ---------------------------------------------------------------- HTTP

class Client:
    def __init__(self, token: str, organization: Optional[str]):
        self._token = token
        self._organization = organization

    def _headers(self, accept: str) -> dict:
        headers = {
            "Authorization": f"Bearer {self._token}",
            "anthropic-version": "2023-06-01",
            "anthropic-client-platform": CLIENT_PLATFORM,
            "Accept": accept,
        }
        if self._organization:
            headers["x-organization-uuid"] = self._organization
        return headers

    def open(self, path: str, accept: str = "application/json", timeout: float = 30, extra=None):
        headers = self._headers(accept)
        headers.update(extra or {})
        request = urllib.request.Request(API + path, headers=headers, method="GET")
        try:
            return urllib.request.urlopen(request, timeout=timeout)
        except urllib.error.HTTPError as error:
            # Report the status and error type only: bodies can echo sensitive data.
            kind = "unknown"
            try:
                kind = (json.loads(error.read().decode("utf-8", "replace")).get("error") or {}).get("type", kind)
            except ValueError:
                pass
            raise SpikeError(f"GET {path.split('?')[0]} -> HTTP {error.code} ({kind})") from None

    def get_json(self, path: str) -> Any:
        with self.open(path) as response:
            return json.loads(response.read().decode("utf-8"))


def candidate_ids(session: str) -> list[str]:
    """The CLI accepts session_… and cse_… forms; try the given one first, then the other prefix."""
    session = session.rstrip("/").split("/")[-1].split("?")[0]
    ids = [session]
    for old, new in (("session_", "cse_"), ("cse_", "session_")):
        if session.startswith(old):
            ids.append(new + session[len(old):])
    return ids


def resolve_session(client: Client, session: str) -> tuple[str, dict]:
    last_error = None
    for candidate in candidate_ids(session):
        try:
            return candidate, client.get_json(f"/v1/code/sessions/{urllib.parse.quote(candidate)}")
        except SpikeError as error:
            last_error = error
    raise SpikeError(f"session not readable under any ID form: {last_error}")


# ---------------------------------------------------------------- shapes (keys and types, never values)

def shape(value: Any, depth: int = 3) -> Any:
    if isinstance(value, dict):
        if depth == 0:
            return "{…}"
        return {key: shape(item, depth - 1) for key, item in value.items()}
    if isinstance(value, list):
        return [shape(value[0], depth - 1)] if value else []
    return type(value).__name__


def envelope_of(frame: Any) -> dict:
    """Find the event envelope (the dict carrying `payload`) whether or not the frame wraps it."""
    if isinstance(frame, dict):
        if "payload" in frame:
            return frame
        for key in ("data", "event", "client_event"):
            inner = frame.get(key)
            if isinstance(inner, dict) and "payload" in inner:
                return inner
    return frame if isinstance(frame, dict) else {}


def summarize(frame: Any) -> tuple[dict, str]:
    envelope = envelope_of(frame)
    payload = envelope.get("payload") or {}
    summary = {
        "seq": envelope.get("sequence_num"),
        "event_type": envelope.get("event_type"),
        "source": envelope.get("source"),
        "type": payload.get("type"),
    }
    if payload.get("subtype") is not None:
        summary["subtype"] = payload.get("subtype")
    text = ""
    if payload.get("type") in ("assistant", "user"):
        content = (payload.get("message") or {}).get("content") or []
        if isinstance(content, str):
            text = content
            summary["blocks"] = ["string"]
        else:
            summary["blocks"] = [block.get("type") for block in content if isinstance(block, dict)]
            text = "".join(block.get("text", "") for block in content
                           if isinstance(block, dict) and block.get("type") == "text")
        summary["text_chars"] = len(text)
    if payload.get("type") == "result":
        for key in ("is_error", "stop_reason", "num_turns"):
            if key in payload:
                summary[key] = payload[key]
    return summary, text


def sequence(frame: Any) -> Optional[int]:
    try:
        return int(envelope_of(frame).get("sequence_num"))
    except (TypeError, ValueError):
        return None


def sse_frames(response) -> Iterator[tuple[Optional[str], Optional[str], str]]:
    """Yield (event, id, data) per server-sent event; comment lines such as :keepalive are skipped."""
    event, event_id, data = None, None, []
    for raw in response:
        line = raw.decode("utf-8", "replace").rstrip("\r\n")
        if not line:
            if data:
                yield event, event_id, "\n".join(data)
            event, data = None, []
            continue
        if line.startswith(":"):
            yield None, None, ""  # heartbeat: lets the caller check its deadline
            continue
        field, _, value = line.partition(":")
        value = value[1:] if value.startswith(" ") else value
        if field == "event":
            event = value
        elif field == "data":
            data.append(value)
        elif field == "id":
            event_id = value


# ---------------------------------------------------------------- subcommands

def emit(label: str, value: Any) -> None:
    print(f"{label}: {json.dumps(value, sort_keys=True)}")


def newest_events(client: Client, session_id: str, limit: int) -> list:
    query = urllib.parse.urlencode({"limit": limit, "sort_order": "desc"})
    body = client.get_json(f"/v1/code/sessions/{urllib.parse.quote(session_id)}/events?{query}")
    return list(body.get("data") or []) if isinstance(body, dict) else []


def cli_send(session: str, text: str) -> tuple[dict, float]:
    started = time.monotonic()
    completed = subprocess.run(
        ["claude", "-p", text, "--cloud", session, "--output-format", "json"],
        capture_output=True, text=True, timeout=120,
    )
    elapsed = time.monotonic() - started
    result: dict = {"exit": completed.returncode}
    try:
        parsed = json.loads(completed.stdout)
        result["ok"] = parsed.get("ok")
        if parsed.get("error"):
            result["error"] = parsed.get("error")
        result["json_keys"] = sorted(parsed.keys())
    except ValueError:
        # Configuration errors print to stderr without JSON (per the docs); keep its first line.
        result["stderr"] = (completed.stderr.strip().splitlines() or [""])[0][:200]
    return result, elapsed


def command_info(client: Client, args, credentials) -> None:
    _, expires_at, organization, scopes = credentials
    emit("token", {
        "minutes_left": round((expires_at - time.time()) / 60, 1) if expires_at else None,
        "scopes": scopes,
        "organization": redact(organization),
    })
    session_id, metadata = resolve_session(client, args.session)
    emit("session_id_form", session_id.split("_", 1)[0])
    emit("metadata_shape", shape(metadata))
    flat = metadata.get("data", metadata) if isinstance(metadata, dict) else {}
    keep = ("session_status", "status", "environment_kind", "origin", "created_at", "updated_at")
    emit("metadata", {key: flat.get(key) for key in keep if isinstance(flat, dict) and key in flat})


def command_history(client: Client, args, _credentials) -> None:
    session_id, _ = resolve_session(client, args.session)
    events = newest_events(client, session_id, args.limit)
    if events:
        emit("first_event_shape", shape(events[0]))
    for event in reversed(events):
        emit("event", summarize(event)[0])


def command_send(_client: Optional[Client], args, _credentials) -> None:
    result, elapsed = cli_send(args.session, args.text)
    emit("cli_send", result)
    emit("cli_send_seconds", round(elapsed, 2))


def command_roundtrip(client: Client, args, _credentials) -> None:
    session_id, _ = resolve_session(client, args.session)
    before = newest_events(client, session_id, 1)
    cursor = sequence(before[0]) if before else 0
    emit("cursor_before_send", cursor)

    started = time.monotonic()
    result, send_seconds = cli_send(args.session, args.text)
    emit("cli_send", result)
    emit("cli_send_seconds", round(send_seconds, 2))
    if not result.get("ok"):
        raise SpikeError("the send was not accepted by the CLI; nothing to stream")

    query = urllib.parse.urlencode({"from_sequence_num": cursor or 0})
    path = f"/v1/code/sessions/{urllib.parse.quote(session_id)}/events/stream?{query}"
    deadline = started + args.timeout
    timings: dict = {}
    seen_shapes: set = set()
    last_seq = cursor
    with client.open(path, accept="text/event-stream", timeout=30) as stream:
        for event_name, _event_id, data in sse_frames(stream):
            now = time.monotonic()
            if now > deadline:
                emit("timeout_seconds", args.timeout)
                break
            if not data:
                continue
            try:
                frame = json.loads(data)
            except ValueError:
                emit("unparsed_frame", {"event": event_name, "chars": len(data)})
                continue
            seq = sequence(frame)
            if seq is not None and last_seq is not None and seq <= last_seq:
                continue  # replayed or duplicate: de-duplicate by sequence_num
            last_seq = seq if seq is not None else last_seq
            summary, text = summarize(frame)
            key = (event_name, summary.get("type"))
            if key not in seen_shapes:
                seen_shapes.add(key)
                emit("new_frame_shape", {"sse_event": event_name, "shape": shape(frame)})
            emit("event", dict(summary, sse_event=event_name, t=round(now - started, 2)))
            kind = summary.get("type")
            if kind == "user" and "user_seen" not in timings:
                timings["user_seen"] = round(now - started, 2)
            if kind == "assistant":
                timings.setdefault("first_assistant", round(now - started, 2))
                if args.show_text and text:
                    print(f"[assistant text, do not paste] {text}", file=sys.stderr)
            if kind == "result":
                timings["result"] = round(now - started, 2)
                break
    emit("timings_seconds", timings)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("subcommand", choices=("info", "history", "send", "roundtrip"))
    parser.add_argument("--session", required=True, help="cloud session ID (session_… or cse_…) or its claude.ai/code URL")
    parser.add_argument("--text", default=SYNTHETIC_TEXT, help="synthetic message for send/roundtrip")
    parser.add_argument("--limit", type=int, default=20, help="events for history")
    parser.add_argument("--timeout", type=float, default=300, help="roundtrip deadline in seconds")
    parser.add_argument("--show-text", action="store_true", help="print assistant text to stderr (synthetic only)")
    args = parser.parse_args()

    try:
        if args.subcommand == "send":
            command_send(None, args, None)
            return 0
        credentials = load_credentials()
        require_fresh(credentials[1])
        client = Client(credentials[0], credentials[2])
        {"info": command_info, "history": command_history, "roundtrip": command_roundtrip}[args.subcommand](
            client, args, credentials)
        return 0
    except SpikeError as error:
        print(f"spike: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
