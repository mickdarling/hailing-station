"""Exercise `haild ambient reload|status` (#405) against a private owner-only socket answered by this test.

No daemon, device or RightyO runs: the test checks the exact request line, the plain output and the exit codes.
"""

import json
import os
import socket
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HAILD = REPO / ".build" / "debug" / "haild"


class AmbientCLITests(unittest.TestCase):
    def run_ambient(self, arguments, response, mode=0o600):
        with tempfile.TemporaryDirectory(prefix="hail-ambient-") as scratch:
            path = os.path.join(scratch, "replies.sock")
            requests, errors = [], []
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(path)
                os.chmod(path, mode)
                server.listen(1)
                server.settimeout(5)

                def answer():
                    try:
                        client, _ = server.accept()
                        with client:
                            client.settimeout(10)
                            request = b""
                            while not request.endswith(b"\n"):
                                chunk = client.recv(4096)
                                if not chunk:
                                    return
                                request += chunk
                            requests.append(request)
                            if response is not None:  # None: read the request, then close without answering.
                                client.sendall(json.dumps(response).encode() + b"\n")
                    except socket.timeout:
                        pass
                    except Exception as error:  # Hand thread failures back to the test.
                        errors.append(error)

                worker = threading.Thread(target=answer, daemon=True)
                worker.start()
                result = subprocess.run(
                    [str(HAILD), "ambient", *arguments, "--socket", path],
                    cwd=REPO, capture_output=True, text=True, timeout=20, check=False,
                )
                if not requests:  # haild never connected (a refused socket): release the waiting accept at once.
                    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as poke:
                        poke.connect(path)
                worker.join(timeout=12)
            self.assertFalse(errors, errors)
            return result, requests

    def report(self, outcome, **fields):
        body = {"outcome": outcome, "active": False, "liveChildren": 0}
        body.update(fields)
        return {"delivered": 0, "ambient": body}

    def test_reload_sends_the_exact_request_and_says_what_happened(self):
        result, requests = self.run_ambient(["reload"], self.report("reloaded", active=True, liveChildren=2))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([json.loads(r) for r in requests], [{"kind": "ambient", "action": "reload"}])
        self.assertTrue(result.stdout.startswith("reloaded: "))
        self.assertIn("audio around the restart may be lost", result.stdout)

    def test_outcomes_map_to_plain_lines_and_exit_codes(self):
        cases = [
            ("idle", 0, "idle: no active ambient stream"),
            ("busy", 75, "busy: "),
            ("stopping", 75, "stopping: "),
            ("not_enabled", 1, "not enabled: "),
        ]
        for outcome, code, prefix in cases:
            with self.subTest(outcome=outcome):
                result, _ = self.run_ambient(["reload"], self.report(outcome))
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertTrue(result.stdout.startswith(prefix), result.stdout)
        result, _ = self.run_ambient(["reload"], self.report("refused", reason="child unsafeConfig"))
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.strip(),
                         "refused: child unsafeConfig; the running child keeps the stream")

    def test_status_shows_the_stream_and_a_newer_install(self):
        report = self.report("status", active=True, deviceClass="phone", target="tmux:main",
                             since=100.0, childSince=200.0, installedAt=300.0, liveChildren=1)
        result, requests = self.run_ambient(["status"], report)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([json.loads(r) for r in requests], [{"kind": "ambient", "action": "status"}])
        lines = result.stdout.splitlines()
        self.assertEqual(lines[0], "active: yes")
        self.assertIn("device: phone", lines)
        self.assertIn("target: tmux:main", lines)
        self.assertIn("live children: 1", lines)
        self.assertTrue(any(line.startswith("installed: ") and "haild ambient reload" in line for line in lines))

    def test_idle_status_and_daemon_refusals(self):
        result, _ = self.run_ambient(["status"], self.report("status", target="tmux:main", installedAt=1.0))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[0], "active: no")
        self.assertNotIn("device:", result.stdout)
        result, _ = self.run_ambient(["reload"], {"delivered": 0, "error": "rate limited"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("refused: rate limited", result.stderr)
        # The current daemon's own refusal carries no version hint.
        self.assertNotIn("predate", result.stderr)

    def test_usage_and_a_socket_open_to_others_are_refused(self):
        for arguments in [[], ["on"], ["off"], ["reload", "--force"]]:
            with self.subTest(arguments=arguments):
                result = subprocess.run([str(HAILD), "ambient", *arguments], cwd=REPO, capture_output=True,
                                        text=True, timeout=15, check=False)
                self.assertEqual(result.returncode, 64)
        result, requests = self.run_ambient(["reload"], self.report("reloaded"), mode=0o666)
        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid owner-only reply socket", result.stderr)
        self.assertEqual(requests, [])

    def test_an_older_daemon_and_a_lost_answer_are_named(self):
        result, _ = self.run_ambient(["reload"], {"delivered": 0, "error": "frame decode failure",
                                                  "code": "decodeFailure"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("refused: frame decode failure", result.stderr)
        self.assertIn("may predate `haild ambient`", result.stderr)
        result, _ = self.run_ambient(["reload"], {"delivered": 0})
        self.assertIn("refused: no ambient report", result.stderr)
        result, requests = self.run_ambient(["reload"], None)
        self.assertEqual(len(requests), 1)
        self.assertEqual(result.returncode, 1)
        self.assertIn("unknown: no answer from the daemon", result.stderr)
        self.assertIn("haild ambient status", result.stderr)
        self.assertNotIn("dispatch", result.stderr)


if __name__ == "__main__":
    unittest.main()
