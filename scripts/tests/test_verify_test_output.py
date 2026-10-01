"""Verification logging must not block test execution or hide its exit status (#185)."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SWIFT = r'''import os, stat, sys
assert sys.argv[1:] == ["test", "--parallel", "-Xswiftc", "-warnings-as-errors"]
mode = os.fstat(1).st_mode
if not stat.S_ISREG(mode) or mode & 0o077:
    print("test output is not an owner-only regular capture", file=sys.stderr)
    sys.exit(97)
print("fixture stdout")
print("fixture stderr", file=sys.stderr)
print("x" * 65536)
sys.exit(int(os.environ["FAKE_SWIFT_STATUS"]))
'''


class SuccessfulFixtureCleanup(unittest.TestCase):
    def run(self, result=None):
        result = result if result is not None else self.defaultTestResult()
        before = (len(result.errors), len(result.failures), len(result.unexpectedSuccesses))
        super().run(result)
        after = (len(result.errors), len(result.failures), len(result.unexpectedSuccesses))
        if before == after and hasattr(self, "scratch"):
            try:
                shutil.rmtree(self.scratch)
            except OSError:
                result.addError(self, sys.exc_info())
        return result


class VerifyTestOutputTests(SuccessfulFixtureCleanup):
    def setUp(self):
        self.scratch = Path(tempfile.mkdtemp(prefix="hailing-verify-output-test-"))
        self.bin = self.scratch / "bin"
        self.bin.mkdir(mode=0o700)
        self.write_tool("swift", SWIFT)
        self.write_tool("xcodebuild", "import sys; sys.exit(0)")
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        TMPDIR=str(self.scratch), FAKE_SWIFT_STATUS="0")
        self.script = Path(__file__).resolve().parents[1] / "verify.sh"

    def write_tool(self, name, source):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n{source}", encoding="utf-8")
        path.chmod(0o700)

    def run_lane(self, status=0):
        self.env["FAKE_SWIFT_STATUS"] = str(status)
        return subprocess.run(["bash", str(self.script), "test"], env=self.env,
                              capture_output=True, text=True, timeout=20)

    def captures_regular_private_output_and_replays_every_byte(self, status):
        result = self.run_lane(status)
        self.assertEqual(result.returncode, status, result.stderr)
        self.assertIn("fixture stdout\n", result.stdout)
        self.assertIn("fixture stderr\n", result.stdout)
        self.assertIn("x" * 65536 + "\n", result.stdout)
        captures = list(self.scratch.glob("hailing-swift-tests.*"))
        self.assertEqual(len(captures), int(status != 0))
        if status:
            self.assertIn(str(captures[0]), result.stderr)
            self.assertEqual(captures[0].stat().st_mode & 0o777, 0o600)

    def test_success_replays_complete_output_and_removes_only_success_capture(self):
        self.captures_regular_private_output_and_replays_every_byte(0)

    def test_failure_preserves_output_and_exact_test_status(self):
        self.captures_regular_private_output_and_replays_every_byte(7)

    def test_reporting_failure_cannot_make_success_look_successful(self):
        self.write_tool("cat", "import sys; sys.exit(9)")
        result = self.run_lane()
        self.assertEqual(result.returncode, 9)
        self.assertEqual(len(list(self.scratch.glob("hailing-swift-tests.*"))), 1)

    def test_test_failure_takes_precedence_over_reporting_failure(self):
        self.write_tool("cat", "import sys; sys.exit(9)")
        self.assertEqual(self.run_lane(7).returncode, 7)

    def test_capture_creation_failure_does_not_run_tests(self):
        self.write_tool("mktemp", "import sys; sys.exit(8)")
        self.assertEqual(self.run_lane().returncode, 8)
        self.assertEqual(list(self.scratch.glob("hailing-swift-tests.*")), [])

    def test_unwritable_notification_stderr_cannot_mask_test_failure(self):
        self.env["FAKE_SWIFT_STATUS"] = "7"
        with open(os.devnull, "rb") as unwritable:
            result = subprocess.run(["bash", str(self.script), "test"], env=self.env,
                                    stdout=subprocess.PIPE, stderr=unwritable, text=True, timeout=20)
        self.assertEqual(result.returncode, 7)
        self.assertIn("fixture stdout\n", result.stdout)
        self.assertEqual(len(list(self.scratch.glob("hailing-swift-tests.*"))), 1)


class VerifyFixtureCleanupTests(SuccessfulFixtureCleanup):
    def test_passing_fixture_removes_scratch_after_retention_assertions(self):
        case = VerifyTestOutputTests("test_failure_preserves_output_and_exact_test_status")
        result = case.run()
        self.assertTrue(result.wasSuccessful(), result.errors + result.failures)
        self.assertFalse(case.scratch.exists())

    def test_failed_fixture_preserves_scratch_and_capture_for_diagnosis(self):
        class FailingFixture(VerifyTestOutputTests):
            def test_controlled_failure(self):
                self.captures_regular_private_output_and_replays_every_byte(7)
                self.fail("controlled cleanup-policy failure")

        case = FailingFixture("test_controlled_failure")
        result = case.run()
        self.scratch = case.scratch
        self.assertEqual(len(result.failures), 1)
        self.assertTrue(case.scratch.is_dir())
        self.assertEqual(len(list(case.scratch.glob("hailing-swift-tests.*"))), 1)

    def test_errored_fixture_preserves_scratch_and_capture_for_diagnosis(self):
        class ErroredFixture(VerifyTestOutputTests):
            def test_controlled_error(self):
                self.captures_regular_private_output_and_replays_every_byte(7)
                raise RuntimeError("controlled cleanup-policy error")

        case = ErroredFixture("test_controlled_error")
        result = case.run()
        self.scratch = case.scratch
        self.assertEqual(len(result.errors), 1)
        self.assertTrue(case.scratch.is_dir())
        self.assertEqual(len(list(case.scratch.glob("hailing-swift-tests.*"))), 1)


if __name__ == "__main__":
    unittest.main()
