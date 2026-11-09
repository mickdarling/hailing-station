"""Tests for scripts/pr-shape.py's spec-reference check (#1161)."""
import importlib.util
import json
import subprocess
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "pr-shape.py"
spec = importlib.util.spec_from_file_location("pr_shape", SCRIPT)
pr_shape = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pr_shape)

REPO = "owner/repo"
BODY = "Part of #42\n\nSome change."


def returning(issue):
    """A fake `gh` that returns this issue as JSON, and records what it was asked."""
    calls = []

    def fetch(*args):
        calls.append(args)
        return json.dumps(issue)

    fetch.calls = calls
    return fetch


def failing(stderr, returncode=1):
    def fetch(*args):
        raise subprocess.CalledProcessError(returncode, ["gh", *args], output="", stderr=stderr)

    return fetch


class SpecProblemsTests(unittest.TestCase):
    def test_an_open_labelled_issue_has_no_problems(self):
        fetch = returning({"state": "open", "labels": [{"name": "type:feature"}]})
        self.assertEqual(pr_shape.spec_problems(REPO, BODY, fetch), [])
        # One REST lookup per run, as before (API budget).
        self.assertEqual(fetch.calls, [("api", "repos/owner/repo/issues/42")])

    def test_a_closed_issue_is_not_open(self):
        fetch = returning({"state": "closed", "labels": [{"name": "type:epic"}]})
        self.assertEqual(pr_shape.spec_problems(REPO, BODY, fetch), ["Spec issue #42 is not open."])

    def test_an_issue_without_a_spec_label_is_reported(self):
        fetch = returning({"state": "open", "labels": [{"name": "type:bug"}]})
        problems = pr_shape.spec_problems(REPO, BODY, fetch)
        self.assertEqual(len(problems), 1)
        self.assertTrue(problems[0].startswith("Spec issue #42 is not labelled as a spec"))

    def test_a_pull_request_number_is_named_as_one(self):
        fetch = returning({"state": "closed", "labels": [], "pull_request": {"url": "x"}})
        self.assertEqual(
            pr_shape.spec_problems(REPO, BODY, fetch),
            ["Spec reference #42 is a pull request; point 'Part of' or 'Closes' at the spec issue."],
        )

    def test_a_missing_number_does_not_exist(self):
        fetch = failing("gh: Not Found (HTTP 404)\n")
        self.assertEqual(pr_shape.spec_problems(REPO, BODY, fetch), ["Spec reference #42 doesn't exist in this repo."])

    def test_a_failed_lookup_says_it_could_not_read_the_issue(self):
        for stderr in ["gh: Bad Gateway (HTTP 502)\nretry later\n", "error connecting to api.github.com: connection reset\n"]:
            problems = pr_shape.spec_problems(REPO, BODY, failing(stderr))
            self.assertEqual(problems, [f"Could not read spec issue #42: {stderr.splitlines()[0]}"])
            self.assertNotIn("not an issue", problems[0])
        silent = pr_shape.spec_problems(REPO, BODY, failing("", returncode=4))
        self.assertEqual(silent, ["Could not read spec issue #42: gh exited with status 4"])

    def test_a_long_error_line_is_capped(self):
        problems = pr_shape.spec_problems(REPO, BODY, failing("x" * 5000 + "\n"))
        self.assertEqual(problems, ["Could not read spec issue #42: " + "x" * pr_shape.MAX_REASON + "…"])

    def test_a_body_without_a_reference_keeps_its_message(self):
        fetch = returning({})
        self.assertEqual(
            pr_shape.spec_problems(REPO, "No reference here.", fetch),
            ["PR body needs a 'Closes #N' or 'Part of #N' line pointing at the spec issue."],
        )
        self.assertEqual(fetch.calls, [])

    def test_the_first_reference_is_the_one_checked(self):
        fetch = returning({"state": "open", "labels": [{"name": "type:epic"}]})
        pr_shape.spec_problems(REPO, "Part of #252\n\nCloses #1161", fetch)
        self.assertEqual(fetch.calls, [("api", "repos/owner/repo/issues/252")])


if __name__ == "__main__":
    unittest.main()
