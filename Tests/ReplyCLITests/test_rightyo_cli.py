"""Exercise RightyO JSONL dry run and the `--reply-to` dispatch client: no capture or provider submission.

Dispatch cases run the real `haild rightyo <target>` against a synthetic tmux (one listed session, nothing
deliverable) and a private owner-only socket answered by this test; no daemon, device or real target exists.
"""

import json
import os
import select
import socket
import subprocess
import tempfile
import threading
import unittest
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HAILD = REPO / ".build" / "debug" / "haild"
FIXTURE = REPO / "fixtures" / "rightyo" / "tool-events.jsonl"
ENROLLED = REPO / "fixtures" / "rightyo" / "enrolled-speakers.jsonl"
OVERRIDE = REPO / "fixtures" / "rightyo" / "enrolled-override.jsonl"
FORMED = REPO / "fixtures" / "rightyo" / "enrolled-formed-request.jsonl"
SYNTHETIC_TMUX = Path(__file__).parent / "fixtures" / "tmux"
SYNTHETIC_BINDING = "$1@1700000000/%1:4242"


class RightyoCLITests(unittest.TestCase):
    def invoke(self, content, session="tool-demo"):
        return subprocess.run(
            [str(HAILD), "rightyo", "--session", session, "--dry-run"],
            input=content, cwd=REPO, capture_output=True, text=True, timeout=15, check=False,
        )

    def test_shared_fixture_validates_one_request_without_transcript_logging(self):
        result = self.invoke(FIXTURE.read_text())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("request validated"), 1)
        self.assertNotIn("scheduled for Friday", result.stdout + result.stderr)
        self.assertNotIn("check our discussion", result.stdout + result.stderr)

    def test_attended_receipt_arrives_before_more_audio_or_stdin_eof(self):
        lines = FIXTURE.read_bytes().splitlines(keepends=True)
        prefix = b"".join(lines[:-1])
        self.assertLess(len(prefix), 4096)
        process = subprocess.Popen(
            [str(HAILD), "rightyo", "--session", "tool-demo", "--dry-run"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0,
        )
        try:
            process.stdin.write(prefix)
            process.stdin.flush()
            ready, _, _ = select.select([process.stdout], [], [], 3)
            self.assertTrue(ready, "request receipt waited for more input/EOF")
            receipt = os.read(process.stdout.fileno(), 1024)
            self.assertIn(b"request validated", receipt)
            process.stdin.write(lines[-1])
            process.stdin.close()
            self.assertEqual(process.wait(timeout=5), 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            for stream in [process.stdin, process.stdout, process.stderr]:
                if stream is not None:
                    stream.close()

    def test_incomplete_empty_malformed_and_foreign_session_refuse(self):
        for content in ["", "{not-json: invented-private-sentinel}\n", FIXTURE.read_text().splitlines()[0]]:
            with self.subTest(content=content[:20]):
                result = self.invoke(content)
                self.assertEqual(result.returncode, 8)
                self.assertNotIn("invented-private-sentinel", result.stdout + result.stderr)
        self.assertEqual(self.invoke(FIXTURE.read_text(), "wrong-session").returncode, 8)

    def test_producer_error_returns_failure_without_retracting_prior_receipt(self):
        events = [json.loads(line) for line in FIXTURE.read_text().splitlines()]
        events[-1]["phase"] = "error"
        result = self.invoke("\n".join(json.dumps(event) for event in events))
        self.assertEqual(result.returncode, 8)
        self.assertEqual(result.stdout.count("request validated"), 1)

    def test_oversized_record_is_refused(self):
        self.assertEqual(self.invoke(" " * 1_200_001).returncode, 8)

    def test_transcription_only_disabled_stream_is_accepted_without_request(self):
        events = [json.loads(line) for line in FIXTURE.read_text().splitlines()]
        events[0]["capabilities"]["activation"] = "disabled"
        selected = [events[0], events[1], events[-1]]
        result = self.invoke("\n".join(json.dumps(event) for event in selected))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_enrolled_speakers_past_fifteen_minutes_validate_one_request(self):
        result = self.invoke(ENROLLED.read_text(), "enrolled-demo")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("request validated"), 1)
        self.assertNotIn("check our discussion", result.stdout + result.stderr)
        events = [json.loads(line) for line in ENROLLED.read_text().splitlines()]
        events[0]["capabilities"]["speakers"] = "verified"
        self.assertEqual(self.invoke("\n".join(json.dumps(event) for event in events), "enrolled-demo").returncode, 8)

    def test_owner_override_fixture_prints_receipt_after_the_superseded_request(self):
        result = self.invoke(OVERRIDE.read_text(), "enrolled-demo")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("request validated"), 1)
        self.assertEqual(result.stdout.count("rightyo: override enrolled-demo:request\n"), 1)
        self.assertLess(result.stdout.index("request validated"), result.stdout.index("rightyo: override"))
        self.assertNotIn("delete the project", result.stdout + result.stderr)
        events = [json.loads(line) for line in OVERRIDE.read_text().splitlines()]
        events[-2]["role"] = "participant"
        self.assertEqual(self.invoke("\n".join(json.dumps(event) for event in events), "enrolled-demo").returncode, 8)

    def test_formed_request_fixture_validates_one_request_and_requires_the_text_once_advertised(self):
        result = self.invoke(FORMED.read_text(), "formed-demo")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("request validated"), 1)
        self.assertNotIn("archive the project", result.stdout + result.stderr)
        events = [json.loads(line) for line in FORMED.read_text().splitlines()]
        del events[-2]["formed_request"]
        self.assertEqual(self.invoke("\n".join(json.dumps(event) for event in events), "formed-demo").returncode, 8)


class RightyoReplyToCLITests(unittest.TestCase):
    """`--reply-to <connection>`: arg shapes, the dispatch wire shape, receipts and refusal exit codes."""

    CONNECTION = str(uuid.uuid4()).upper()

    def test_reply_to_and_socket_argument_shapes_are_usage_errors(self):
        shapes = [
            ["tmux:demo", "--session", "tool-demo", "--reply-to", "not-a-uuid"],
            ["tmux:demo", "--session", "tool-demo", "--reply-to", ""],
            ["tmux:demo", "--session", "tool-demo", "--reply-to"],
            ["--session", "tool-demo", "--dry-run", "--reply-to", self.CONNECTION],
            ["--session", "tool-demo", "--dry-run", "--socket", "/nonexistent/replies.sock"],
            ["tmux:demo", "--session", "tool-demo", "--socket", "/nonexistent/replies.sock"],
            ["tmux:demo", "--session", "tool-demo", "--reply-to", self.CONNECTION, "--socket"],
            ["tmux:demo", "--session", "tool-demo", "--dry-run"],
            # A value-taking option never consumes another option or runs out of arguments.
            ["tmux:demo", "--session", "--dry-run"],
            ["tmux:demo", "--session"],
            ["tmux:demo", "--session", ""],
            ["tmux:demo", "--session", "tool-demo", "--reply-to", "--socket", "/nonexistent/replies.sock"],
            ["tmux:demo", "--session", "tool-demo", "--reply-to", self.CONNECTION, "--socket", "-"],
            ["tmux:demo", "--session", "tool-demo", "--reply-to", self.CONNECTION, "--socket", ""],
            ["tmux:demo", "--session", "tool-demo", "--reply-to", self.CONNECTION, "--socket"],
            ["--session", "--dry-run"],
        ]
        for arguments in shapes:
            with self.subTest(arguments=arguments):
                result = subprocess.run(
                    [str(HAILD), "rightyo", *arguments], input="", cwd=REPO,
                    capture_output=True, text=True, timeout=15, check=False,
                )
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn("[--reply-to <connection-UUID>] [--socket <path>]", result.stderr)
                self.assertIn("[--single-terminal-reply-fallback]", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_dispatch_carries_the_prompt_for_the_named_connection_and_prints_the_owned_request(self):
        owner = str(uuid.uuid4()).upper()
        result, requests = self.dispatch([{"delivered": 1, "request": owner}])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(requests), 1)
        request = json.loads(requests[0])
        self.assertEqual(request["kind"], "dispatch")
        self.assertEqual(request["connection"].upper(), self.CONNECTION)
        self.assertEqual(request["target"], "tmux:demo")
        self.assertEqual(request["binding"], SYNTHETIC_BINDING)
        # The prompt is the compact JSON followed by the host's reply block, which names the real target.
        body, _, block = request["text"].rpartition(" Reply: answer briefly; ")
        prompt = json.loads(body)
        self.assertEqual(prompt["request_id"], "tool-demo:request")
        self.assertTrue(block.endswith(
            "run haild reply tmux:demo --say '<spoken answer>' (single-quote the answer and keep it free of "
            "single quotes; single-terminal fallback only)."), block)
        self.assertNotIn('"', block)
        self.assertNotIn("--request", block)
        self.assertNotIn("\n", block)
        self.assertEqual(
            result.stdout,
            f"rightyo: request delivered to tmux:demo for connection {self.CONNECTION} (reply request {owner})\n",
        )
        self.assertIn(f"dispatched by the running daemon for connection {self.CONNECTION}", result.stderr)
        self.assertNotIn("scheduled for Friday", result.stdout + result.stderr)

    def test_null_ownership_is_delivered_and_says_so(self):
        for response in [{"delivered": 1, "request": None},
                         {"delivered": 1, "request": None, "code": "publicationFailed",
                          "error": "dispatch refused [ownershipLost]: handed off, but no reply ownership survived"}]:
            with self.subTest(response=response):
                result, requests = self.dispatch([response])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(requests), 1)
                self.assertEqual(
                    result.stdout,
                    f"rightyo: request delivered to tmux:demo for connection {self.CONNECTION} (no reply ownership)\n",
                )
                if "error" in response:
                    self.assertIn(response["error"], result.stderr)

    def test_refusals_map_to_the_direct_path_codes_or_exit_one_with_the_reason(self):
        cases = [
            ({"delivered": 0, "request": None, "code": "publicationFailed",
              "error": "dispatch refused [confirmationRequired]: target requires confirmation at the Mac"},
             8, "RightyO input refused"),
            ({"delivered": 0, "request": None, "code": "publicationFailed",
              "error": "dispatch refused [bindingMismatch]: target binding differs from the pinned binding"},
             7, "denied: target tmux:demo changed since it was allowed"),
            ({"delivered": 0, "request": None, "code": "noRecipient",
              "error": "dispatch refused [unknownConnection]: no live connection has that id"},
             1, "haild: dispatch refused [unknownConnection]: no live connection has that id\n"),
            ({"delivered": 0, "request": None, "code": "publicationFailed",
              "error": "dispatch refused [deliveryRefused]: target action was refused"},
             1, "[deliveryRefused]"),
            ({"delivered": 0, "error": "rate limited"}, 1, "rate limited"),
            ({"delivered": 1}, 1, "answered as a reply, not a dispatch"),
            ({"delivered": 2, "request": None}, 1, "dispatch refused without a reason"),
            (None, 1, ""),
        ]
        for response, code, message in cases:
            with self.subTest(response=response):
                result, requests = self.dispatch([response])
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual(len(requests), 1)
                self.assertIn(message, result.stderr)
                self.assertEqual(result.stdout, "")

    def test_missing_socket_refuses_before_any_dispatch(self):
        with tempfile.TemporaryDirectory(prefix="hail-rightyo-nosock-") as scratch:
            result = self.run_rightyo(os.path.join(scratch, "absent.sock"), scratch)
        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid owner-only reply socket", result.stderr)
        self.assertEqual(result.stdout, "")

    def dispatch(self, responses):
        with tempfile.TemporaryDirectory(prefix="hail-rightyo-dispatch-") as scratch:
            path = os.path.join(scratch, "replies.sock")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(path)
                os.chmod(path, 0o600)
                server.listen(4)
                server.settimeout(0.1)
                requests, errors = [], []
                finished = threading.Event()

                def answer():
                    try:
                        while not finished.is_set():
                            try:
                                client, _ = server.accept()
                            except socket.timeout:
                                continue
                            with client:
                                client.settimeout(10)
                                request = b""
                                while not request.endswith(b"\n"):
                                    chunk = client.recv(65536)
                                    if not chunk:
                                        raise AssertionError("CLI closed before sending a request")
                                    request += chunk
                                requests.append(request)
                                index = len(requests) - 1
                                response = responses[index] if index < len(responses) else {
                                    "delivered": 0, "request": None, "error": "unexpected request",
                                }
                                if response is not None:
                                    client.sendall(json.dumps(response).encode() + b"\n")
                    except Exception as error:  # Hand thread failures back to the test.
                        errors.append(error)

                worker = threading.Thread(target=answer, daemon=True)
                worker.start()
                try:
                    result = self.run_rightyo(path, scratch)
                finally:
                    finished.set()
                    worker.join(timeout=12)
                self.assertFalse(worker.is_alive())
                self.assertFalse(errors, errors)
                return result, requests

    def run_rightyo(self, socket_path, scratch):
        environment = os.environ.copy()
        environment["HAIL_TMUX"] = str(SYNTHETIC_TMUX)
        environment["HAIL_CONFIG_DIR"] = os.path.join(scratch, "config")
        environment.pop("HAIL_REPLY_BRIDGE_TARGETS", None)
        return subprocess.run(
            [str(HAILD), "rightyo", "tmux:demo", "--session", "tool-demo", "--allow-synthetic",
             "--reply-to", self.CONNECTION, "--socket", socket_path],
            input=FIXTURE.read_text(), cwd=REPO, capture_output=True, text=True, timeout=30, check=False,
            env=environment, start_new_session=True,
        )
