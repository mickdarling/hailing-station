"""Exercise `haild notify` (#609) against a private owner-only socket answered by this test.

No daemon, device or renderer runs: the test checks the exact request line, the plain output and the exit codes.
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


class NotifyCLITests(unittest.TestCase):
    def run_notify(self, arguments, response, mode=0o600):
        """Runs `haild notify`, answering its one request with `response`; returns (result, requests)."""
        with tempfile.TemporaryDirectory(prefix="hail-notify-") as scratch:
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
                                chunk = client.recv(65536)
                                if not chunk:
                                    return
                                request += chunk
                            requests.append(json.loads(request))
                            if response is not None:  # None: read the request, then close without answering.
                                client.sendall(json.dumps(response).encode() + b"\n")
                    except socket.timeout:
                        pass
                    except Exception as error:  # Hand thread failures back to the test.
                        errors.append(error)

                worker = threading.Thread(target=answer, daemon=True)
                worker.start()
                result = subprocess.run(
                    [str(HAILD), "notify", *arguments, "--socket", path], cwd=REPO, capture_output=True,
                    text=True, timeout=20, check=False,
                )
                if not requests:  # haild never connected (a refused socket): release the waiting accept at once.
                    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as poke:
                        poke.connect(path)
                worker.join(timeout=12)
            self.assertFalse(errors, errors)
            return result, requests

    @staticmethod
    def report(outcome, **fields):
        body = {"outcome": outcome, "push": False, "held": 0, "quiet": False}
        body.update(fields)
        return {"delivered": 0, "update": body}

    def test_an_update_is_sent_exactly_and_held(self):
        result, requests = self.run_notify(["tmux:work", "--say", "The deck is built", "--card", "PR #1"],
                                           self.report("held", held=2))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(requests, [{"kind": "update", "action": "submit", "target": "tmux:work",
                                     "text": "The deck is built", "card": "PR #1"}])
        self.assertEqual(result.stdout.strip(), "held: 2 updates waiting")
        self.assertNotIn("The deck is built", result.stdout + result.stderr)

    def test_an_action_update_names_the_push(self):
        result, requests = self.run_notify(["tmux:work", "--action", "--say", "Build failed"],
                                           self.report("held", held=1, push=True))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(requests[0]["priority"], "action")
        self.assertEqual(result.stdout.splitlines(), [
            "held: 1 update waiting",
            "push: suggested (nothing is spoken yet; raise your own notification)",
        ])

    def test_refusals_map_to_lines_and_exit_codes(self):
        cases = [
            (self.report("refused", reason="rate_limited", retryAfter=120), 75,
             "refused: rate_limited; try again in 120 s"),
            (self.report("refused", reason="unknown_target"), 1, "refused: unknown_target"),
            (self.report("refused", reason="full"), 1, "refused: full"),
            (self.report("not_enabled"), 1, "not enabled: haild is running without --session-updates"),
        ]
        for response, code, line in cases:
            with self.subTest(response=response):
                result, _ = self.run_notify(["tmux:work", "--say", "Done"], response)
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual(result.stdout.strip(), line)

    def test_status_and_quiet_on(self):
        result, requests = self.run_notify(["status"], self.report("status", held=3, quiet=True))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(requests, [{"kind": "update", "action": "status"}])
        self.assertEqual(result.stdout.splitlines(), ["held: 3 updates waiting", "quiet: on"])
        _, requests = self.run_notify(["quiet", "on"], self.report("status", quiet=True))
        self.assertEqual(requests, [{"kind": "update", "action": "quiet_on"}])

    def test_usage_a_lost_answer_and_a_socket_open_to_others(self):
        for arguments in [[], ["quiet"], ["quiet", "off"], ["tmux:work"], ["tmux:work", "--say"],
                          ["tmux:work", "--say", "x", "--say", "y"], ["tmux:work", "--say", "x", "--announce"],
                          ["status", "--say", "x"], ["--say", "x"], ["tmux:work", "--say", "x", "--session", "J"]]:
            with self.subTest(arguments=arguments):
                result = subprocess.run([str(HAILD), "notify", *arguments], cwd=REPO, capture_output=True,
                                        text=True, timeout=15, check=False)
                self.assertEqual(result.returncode, 64)
        result, requests = self.run_notify(["status"], self.report("status"), mode=0o666)
        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid owner-only reply socket", result.stderr)
        self.assertEqual(requests, [])
        result, requests = self.run_notify(["status"], None)
        self.assertEqual(len(requests), 1)
        self.assertEqual(result.returncode, 1)
        self.assertIn("unknown: no answer from the daemon", result.stderr)
        result, _ = self.run_notify(["status"], {"delivered": 0, "error": "frame decode failure",
                                                 "code": "decodeFailure"})
        self.assertIn("may predate `haild notify`", result.stderr)


if __name__ == "__main__":
    unittest.main()
