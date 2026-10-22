"""Verification logging must not block test execution or hide its exit status (#185)."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


SWIFT = r'''import json, os, signal, stat, subprocess, sys, time
if sys.argv[1] == "build":
    # The tests are built once, before the lanes (#449).
    assert sys.argv[2:] == ["--build-tests", "-Xswiftc", "-warnings-as-errors"], sys.argv
    with open(os.environ["FAKE_SWIFT_CALLS"], "a") as calls:
        calls.write("build\n")
    sys.exit(0)
assert sys.argv[1:3] == ["test", "--skip-build"], sys.argv
# The parallel lane runs HailCoreTests alone, then every other target (#704); the timing suites run serially.
core = "^HailCoreTests\\."
selection, rest = sys.argv[3:-4], sys.argv[-4:]
assert rest[0] == "--experimental-event-stream-output", sys.argv
assert rest[2:] == ["--experimental-event-stream-version", "0"], sys.argv
events = rest[1]
if selection[:3] == ["--parallel", "--filter", core] and selection[3:4] == ["--skip"] and len(selection) == 5:
    lane = "parallel-core"
elif selection[:3] == ["--parallel", "--skip", core] and selection[3:4] == ["--skip"] and len(selection) == 5:
    lane = "parallel-rest"
elif selection[:2] == ["--no-parallel", "--filter"] and len(selection) == 3:
    lane = "serial"
else:
    raise AssertionError(sys.argv)
with open(os.environ["FAKE_SWIFT_CALLS"], "a") as calls:
    calls.write(lane + "\n")
mode = os.fstat(1).st_mode
if not stat.S_ISREG(mode) or mode & 0o077:
    print("test output is not an owner-only regular capture", file=sys.stderr)
    sys.exit(97)
# Console output is left block-buffered, as the real test runner's is when captured to a file.
print("fixture stdout")
print("fixture stderr", file=sys.stderr)
print("x" * 65536)

def event(kind, test):
    with open(events, "a") as stream:  # Swift Testing writes each event as it happens.
        stream.write(json.dumps({"kind": "event", "version": 0,
                                 "payload": {"kind": kind, "testID": test}}) + "\n")

if os.environ.get("FAKE_SWIFT_HANG"):
    event("testStarted", "Fake.Suite")
    event("testStarted", "Fake.Suite/finishes()/F.swift:1:1")
    event("testEnded", "Fake.Suite/finishes()/F.swift:1:1")
    event("testStarted", "Fake.Suite/hangsForever()/F.swift:2:1")
    print("unflushed tail that a stopped lane loses")
    # A descendant that ignores TERM, which only the KILL after the grace stops.
    child = subprocess.Popen([sys.executable, "-c",
                              "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(600)"])
    with open(os.environ["FAKE_SWIFT_CHILD"], "w") as pid:
        pid.write(str(child.pid))
    time.sleep(600)
if not os.environ.get("FAKE_SWIFT_EMPTY"):  # a lane whose selection matched nothing starts no test (#704)
    event("testStarted", "Fake.Suite/runs()/F.swift:1:1")
    event("testEnded", "Fake.Suite/runs()/F.swift:1:1")
failing = os.environ.get("FAKE_SWIFT_FAIL_LANE")
sys.exit(int(os.environ["FAKE_SWIFT_STATUS"]) if failing in (None, lane) else 0)
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
        # Every lane is captured and replayed; a failure stops at the first parallel half.
        lanes = ["parallel-core"] if status else ["parallel-core", "parallel-rest", "serial"]
        self.assertEqual((self.scratch / "swift-calls").read_text().split(), ["build"] + lanes)
        self.assertEqual(result.stdout.count("fixture stdout\n"), len(lanes))
        captures = list(self.scratch.glob("hailing-swift-tests.*"))
        self.assertEqual(len(captures), int(status != 0))
        self.assertEqual(len(list(self.scratch.glob("hailing-swift-events.*"))), int(status != 0))
        if status:
            self.assertIn(str(captures[0]), result.stderr)
            self.assertEqual(captures[0].stat().st_mode & 0o777, 0o600)

    def test_success_replays_complete_output_and_removes_only_success_capture(self):
        self.captures_regular_private_output_and_replays_every_byte(0)

    def test_failure_preserves_output_and_exact_test_status(self):
        self.captures_regular_private_output_and_replays_every_byte(7)

    def test_a_failing_second_half_fails_the_lane_with_its_status(self):
        # #704: the halves are separate processes; a green first half never masks a red second.
        self.env["FAKE_SWIFT_FAIL_LANE"] = "parallel-rest"
        result = self.run_lane(7)
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual((self.scratch / "swift-calls").read_text().split(),
                         ["build", "parallel-core", "parallel-rest"])
        self.assertEqual(len(list(self.scratch.glob("hailing-swift-tests.*"))), 1)

    def test_a_lane_that_starts_no_test_fails(self):
        # #704: `swift test` exits 0 when its selection matches nothing; the lane must not pass silently.
        self.env["FAKE_SWIFT_EMPTY"] = "1"
        result = self.run_lane()
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertIn("No test started in this lane", result.stderr)
        self.assertEqual((self.scratch / "swift-calls").read_text().split(), ["build", "parallel-core"])
        self.assertEqual(len(list(self.scratch.glob("hailing-swift-tests.*"))), 1)

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
        # #449: a hang fails fast with the started-but-unended test named from the event stream, not the
        # block-buffered console, and leaves no process behind, even one that ignores TERM.
        self.env.update(FAKE_SWIFT_HANG="1", HAIL_TEST_STALL_SECONDS="2",
                        FAKE_SWIFT_CHILD=str(self.scratch / "child-pid"))
        result = self.run_lane()
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertIn("Stalled: no test event for 2 s", result.stderr)
        self.assertIn("  Fake.Suite/hangsForever()/F.swift:2:1\n", result.stderr)
        self.assertNotIn("finishes()", result.stderr)
        self.assertNotIn("  Fake.Suite\n", result.stderr)
        self.assertEqual((self.scratch / "swift-calls").read_text().split(), ["build", "parallel-core"])
        child = int((self.scratch / "child-pid").read_text())
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and alive(child):
            time.sleep(0.1)
        self.assertFalse(alive(child), "the stalled lane's descendants must be stopped")
        for kind in ("tests", "events"):
            kept = list(self.scratch.glob(f"hailing-swift-{kind}.*"))
            self.assertEqual(len(kept), 1, kind)
            self.assertIn(str(kept[0]), result.stderr)

    def test_interrupting_verify_stops_the_running_lane(self):
        self.env.update(FAKE_SWIFT_HANG="1", HAIL_TEST_STALL_SECONDS="300",
                        FAKE_SWIFT_CHILD=str(self.scratch / "child-pid"))
        lane = subprocess.Popen(["bash", str(self.script), "test"], env=self.env,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        child_pid = self.scratch / "child-pid"
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not child_pid.exists():
            time.sleep(0.1)
        self.assertTrue(child_pid.exists(), "the fake lane never started")
        time.sleep(0.5)  # Let the lane's process record its child.
        lane.terminate()
        self.assertEqual(lane.wait(timeout=20), 130)
        child = int(child_pid.read_text())
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and alive(child):
            time.sleep(0.1)
        self.assertFalse(alive(child), "an interrupted verify must not leave the lane running")

    def test_a_stall_limit_that_is_not_a_positive_integer_is_refused_before_any_test(self):
        marker = self.scratch / "injected"
        for value in (f"a[$(touch {marker})]", "5m", "0", "-1", "1234567"):
            with self.subTest(value=value):
                self.env["HAIL_TEST_STALL_SECONDS"] = value
                result = self.run_lane()
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("HAIL_TEST_STALL_SECONDS must be a positive integer", result.stderr)
                self.assertFalse(marker.exists(), "the value must never be evaluated")
                self.assertFalse((self.scratch / "swift-calls").exists())


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
