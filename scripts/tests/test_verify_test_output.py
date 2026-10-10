"""Verification logging must not block test execution or hide its exit status (#185)."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


SWIFT = r'''import os, stat, subprocess, sys, time
if sys.argv[1] == "build":
    # The tests are built once, before the lanes, so the lanes' --verbose output is test events only (#449).
    assert sys.argv[2:] == ["--build-tests", "-Xswiftc", "-warnings-as-errors"], sys.argv
    with open(os.environ["FAKE_SWIFT_CALLS"], "a") as calls:
        calls.write("build\n")
    sys.exit(0)
assert sys.argv[1:4] == ["test", "--skip-build", "--verbose"], sys.argv
lane = sys.argv[4:6]
assert lane[0] in ("--parallel", "--no-parallel"), sys.argv
assert lane[1] == ("--skip" if lane[0] == "--parallel" else "--filter"), sys.argv
assert len(sys.argv) == 7, sys.argv
with open(os.environ["FAKE_SWIFT_CALLS"], "a") as calls:
    calls.write(lane[0] + "\n")
mode = os.fstat(1).st_mode
if not stat.S_ISREG(mode) or mode & 0o077:
    print("test output is not an owner-only regular capture", file=sys.stderr)
    sys.exit(97)
print("fixture stdout")
print("fixture stderr", file=sys.stderr)
print("x" * 65536)
if os.environ.get("FAKE_SWIFT_HANG"):
    print("\u25c7 Test finishes() started.")
    print("\u2714 Test finishes() passed after 0.001 seconds.")
    print("\u25c7 Test hangsForever() started.", flush=True)
    # A child that would outlive its parent if only the parent were stopped.
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(600)"])
    with open(os.environ["FAKE_SWIFT_CHILD"], "w") as pid:
        pid.write(str(child.pid))
    time.sleep(600)
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
                        TMPDIR=str(self.scratch), FAKE_SWIFT_STATUS="0",
                        FAKE_SWIFT_CALLS=str(self.scratch / "swift-calls"))
        # CI sets this for the real lanes; the fixtures must capture into their own scratch (#264).
        self.env.pop("HAIL_TEST_CAPTURE_DIR", None)
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
        # Both lanes are captured and replayed; a failure stops at the parallel lane.
        lanes = ["--parallel"] if status else ["--parallel", "--no-parallel"]
        self.assertEqual((self.scratch / "swift-calls").read_text().split(), ["build"] + lanes)
        self.assertEqual(result.stdout.count("fixture stdout\n"), len(lanes))
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

    def test_capture_directory_override_keeps_failed_captures_there(self):
        captures = self.scratch / "ci" / "test-captures"
        self.env["HAIL_TEST_CAPTURE_DIR"] = str(captures)
        result = self.run_lane(7)
        self.assertEqual(result.returncode, 7, result.stderr)
        kept = list(captures.glob("hailing-swift-tests.*"))
        self.assertEqual(len(kept), 1)
        self.assertIn(str(kept[0]), result.stderr)
        self.assertEqual(list(self.scratch.glob("hailing-swift-tests.*")), [])

    def test_unwritable_notification_stderr_cannot_mask_test_failure(self):
        self.env["FAKE_SWIFT_STATUS"] = "7"
        with open(os.devnull, "rb") as unwritable:
            result = subprocess.run(["bash", str(self.script), "test"], env=self.env,
                                    stdout=subprocess.PIPE, stderr=unwritable, text=True, timeout=20)
        self.assertEqual(result.returncode, 7)
        self.assertIn("fixture stdout\n", result.stdout)
        self.assertEqual(len(list(self.scratch.glob("hailing-swift-tests.*"))), 1)


    def test_a_silent_lane_is_stopped_and_names_the_unfinished_test(self):
        # #449: a hang fails fast with the started-but-unfinished test named, and leaves no process behind.
        self.env.update(FAKE_SWIFT_HANG="1", HAIL_TEST_STALL_SECONDS="2",
                        FAKE_SWIFT_CHILD=str(self.scratch / "child-pid"))
        result = self.run_lane()
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertIn("Stalled: no test output for 2 s", result.stderr)
        self.assertIn("  hangsForever()\n", result.stderr)
        self.assertNotIn("finishes()", result.stderr)
        self.assertIn("fixture stdout\n", result.stdout)
        self.assertEqual((self.scratch / "swift-calls").read_text().split(), ["build", "--parallel"])
        child = int((self.scratch / "child-pid").read_text())
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and alive(child):
            time.sleep(0.1)
        self.assertFalse(alive(child), "the stalled lane's descendants must be stopped")
        captures = list(self.scratch.glob("hailing-swift-tests.*"))
        self.assertEqual(len(captures), 1)
        self.assertIn(str(captures[0]), result.stderr)


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


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
