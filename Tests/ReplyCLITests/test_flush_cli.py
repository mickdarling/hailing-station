"""Exercise `haild targets flush` (#894 ask 1) against a synthetic tmux: no daemon, real tmux server or device.

The synthetic pane is a one-line agent prompt; the test's private config directory holds the policy that allows it.
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HAILD = REPO / ".build" / "debug" / "haild"
FLUSH_TMUX = Path(__file__).parent / "fixtures" / "flush-tmux"
DRAFT = "ZULIP quartz"
TAINT_HINT = "restart haild"


class FlushCLITests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.state = os.path.join(self.scratch.name, "pane.json")
        self.environment = os.environ.copy()
        self.environment["HAIL_TMUX"] = str(FLUSH_TMUX)
        self.environment["HAIL_CONFIG_DIR"] = os.path.join(self.scratch.name, "config")
        self.environment["HAIL_FLUSH_STATE"] = self.state
        self.environment.pop("HAIL_REPLY_BRIDGE_TARGETS", None)
        self.pane(DRAFT, cursor=3)
        allowed = self.haild("targets", "allow", "tmux:demo")
        self.assertEqual(allowed.returncode, 0, allowed.stderr)

    def tearDown(self):
        self.scratch.cleanup()

    def pane(self, text, cursor, agent=True):
        with open(self.state, "w", encoding="utf-8") as handle:
            json.dump({"input": text, "cursor": cursor, "agent": agent}, handle)
        if os.path.exists(self.state + ".log"):
            os.remove(self.state + ".log")

    def shown(self):
        with open(self.state, encoding="utf-8") as handle:
            return json.load(handle)

    def keys(self):
        """Every key command the synthetic tmux received, as the `send-keys` string inside its `if-shell`."""
        if not os.path.exists(self.state + ".log"):
            return []
        with open(self.state + ".log", encoding="utf-8") as log:
            calls = [json.loads(line) for line in log]
        self.assertFalse([call for call in calls if call[:1] == ["send-keys"]], "an ungated key")
        return [call[5] for call in calls if call[:1] == ["if-shell"]]

    def haild(self, *arguments):
        return subprocess.run(
            [str(HAILD), *arguments], cwd=REPO, capture_output=True, text=True, timeout=30, check=False,
            env=self.environment, stdin=subprocess.DEVNULL,
        )

    def assert_private(self, result):
        """The draft reaches stdout alone; stderr (any log a wrapper keeps) has tokens and counts, never the words."""
        for word in DRAFT.split():
            self.assertNotIn(word, result.stderr)
        for line in result.stderr.splitlines():
            if "targets_flush" in line:
                self.assertRegex(
                    line, r"^haild: targets_flush cleared_chars=\d+ result=(empty|not_empty|refused) reason=[a-z_]+$"
                )

    def test_without_yes_and_without_a_terminal_it_shows_the_draft_and_sends_nothing(self):
        result = self.haild("targets", "flush", "tmux:demo")
        self.assertEqual(result.returncode, 8, result.stderr)
        self.assertEqual(result.stdout, DRAFT + "\n")
        self.assertIn("confirmation needed", result.stderr)
        self.assertIn("targets_flush cleared_chars=0 result=refused reason=confirmation_needed", result.stderr)
        self.assertEqual(self.keys(), [])
        self.assertEqual(self.shown()["input"], DRAFT)
        self.assert_private(result)

    def test_yes_clears_with_end_and_one_backspace_per_character(self):
        result = self.haild("targets", "flush", "tmux:demo", "--yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, DRAFT + "\n")
        self.assertEqual(self.keys(), [
            "send-keys -t %1 End", "send-keys -t %1 " + " ".join(["BSpace"] * len(DRAFT)),
        ])
        state = self.shown()
        self.assertEqual(state["input"], "")
        self.assertNotIn("interrupted", state)
        self.assertIn(f"targets_flush cleared_chars={len(DRAFT)} result=empty reason=none", result.stderr)
        self.assertIn("the prompt is now empty", result.stderr)
        self.assertIn(TAINT_HINT, result.stderr)
        self.assert_private(result)

    def test_an_empty_prompt_sends_nothing(self):
        self.pane("", cursor=0)
        result = self.haild("targets", "flush", "tmux:demo", "--yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertIn("nothing was sent", result.stderr)
        self.assertEqual(self.keys(), [])

    def test_refusals_send_nothing_and_say_why(self):
        for text, agent, reason in [
            (DRAFT, False, "not_agent"), ("[Pasted text #1 +4 lines]", True, "placeholder"),
        ]:
            with self.subTest(reason=reason):
                self.pane(text, cursor=len(text), agent=agent)
                result = self.haild("targets", "flush", "tmux:demo", "--yes")
                self.assertEqual(result.returncode, 4, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertIn(f"targets_flush cleared_chars=0 result=refused reason={reason}", result.stderr)
                self.assertIn("nothing was cleared", result.stderr)
                self.assertEqual(self.keys(), [])
                self.assert_private(result)

    def test_policy_and_usage_refuse_before_any_key(self):
        denied = self.haild("targets", "deny", "tmux:demo")
        self.assertEqual(denied.returncode, 0, denied.stderr)
        result = self.haild("targets", "flush", "tmux:demo", "--yes")
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(result.stdout, "")
        for arguments in [["targets", "flush"], ["targets", "flush", "tmux:demo", "--yes", "extra"],
                          ["targets", "flush", "--yes"], ["targets", "flush", "tmux:demo", "--force"]]:
            with self.subTest(arguments=arguments):
                self.assertEqual(self.haild(*arguments).returncode, 64)
        self.assertEqual(self.keys(), [])


if __name__ == "__main__":
    unittest.main()
