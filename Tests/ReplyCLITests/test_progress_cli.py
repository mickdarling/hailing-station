"""Real one-shot CLI/private-socket transactions; no scheduler, provider, device or renderer runs."""
import json
import subprocess
import unittest
from test_notify_cli import NotifyCLITests, HAILD, REPO

TASK = "00000000-0000-4000-8000-000000000001"
TOKEN = "00000000-0000-4000-8000-000000000002"


class ProgressCLITests(unittest.TestCase):
    def transact(self, arguments, outcome="status", **fields):
        body = {"outcome": outcome, "outstanding": False, **fields}
        return NotifyCLITests.run_notify(self, arguments, {"delivered": 0, "progress": body}, command="progress")

    def test_enrollment_and_inspectable_owner_state(self):
        result, requests = self.transact(["start", "tmux:synthetic", "--task", TASK, "--every", "60"],
                                         task=TASK, intervalSeconds=60, setBy="agent")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(requests, [{"kind": "task_progress", "action": "start", "target": "tmux:synthetic",
                                     "task": TASK, "seconds": 60}])
        self.assertEqual(json.loads(result.stdout)["setBy"], "agent")
        _, owner = self.transact(["owner", TASK, "--command", "progress updates every 2 minutes"])
        self.assertEqual(owner[0]["command"], "progress updates every 2 minutes")

    def test_report_is_exact_token_and_request_independent(self):
        result, requests = self.transact(["report", TASK, "--token", TOKEN, "--say", "Synthetic progress",
                                          "--card", "Synthetic detail"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(requests, [{"kind": "task_progress", "action": "report", "task": TASK, "token": TOKEN,
                                     "text": "Synthetic progress", "card": "Synthetic detail"}])
        self.assertNotIn("request", requests[0])

    def test_unavailable_and_refused_are_visible(self):
        for outcome in ("not_enabled", "refused"):
            result, _ = self.transact(["status"], outcome=outcome, reason="synthetic_unavailable")
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout)["reason"], "synthetic_unavailable")

    def test_bad_intervals_unknown_authority_and_duplicate_flags_are_usage_errors(self):
        invalid = [["start", "tmux:synthetic", "--every", "0"], ["interval", TASK, "--every", "3601"],
                   ["report", TASK, "--request", TOKEN], ["report", TASK, "--token", TOKEN, "--token", TOKEN],
                   ["owner", TASK], ["start", "tmux:synthetic", "--task", "bad"]]
        for arguments in invalid:
            with self.subTest(arguments=arguments):
                result = subprocess.run([str(HAILD), "progress", *arguments], cwd=REPO, capture_output=True,
                                        text=True, timeout=15, check=False)
                self.assertEqual(result.returncode, 64)
