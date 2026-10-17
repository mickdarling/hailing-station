"""Actual isolated CLI refusal, before any native factory; software descriptors and authored input only."""

import fcntl
import os
import pty
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
HAILD = REPO / ".build" / "debug" / "haild"
REFUSAL = ("haild: private coaching refused; use trusted local terminal controls"
           " and explicit private configuration\n")


class CoachingCLITests(unittest.TestCase):
    def run_refusal(self, output, input_descriptor=subprocess.DEVNULL):
        process = subprocess.Popen(
            [str(HAILD), "coaching", "--authored-invalid-option"], cwd=REPO,
            stdin=input_descriptor, stdout=subprocess.DEVNULL, stderr=output)
        try:
            self.assertEqual(process.wait(timeout=5), 64)
        finally:
            # Only this test's owned pre-factory process; never a running host or an unrelated child.
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)

    def fill(self, output):
        original = fcntl.fcntl(output, fcntl.F_GETFL)
        fcntl.fcntl(output, fcntl.F_SETFL, original | os.O_NONBLOCK)
        try:
            for _ in range(128):
                try:
                    os.write(output, b"x" * 8192)
                except BlockingIOError:
                    break
            else:
                self.fail("authored output did not reach backpressure")
        finally:
            fcntl.fcntl(output, fcntl.F_SETFL, original)
        # Darwin marks full pipes/PTYs with a kernel-only flag F_SETFL cannot clear; snapshot after filling.
        return fcntl.fcntl(output, fcntl.F_GETFL)

    def test_full_terminal_refusal_exits_without_drain_before_native_construction(self):
        controller, endpoint = pty.openpty()
        try:
            original = self.fill(endpoint)
            # Both descriptors qualify as terminals, but invalid config fails before native() runs.
            self.run_refusal(endpoint, endpoint)
            modes = os.O_ACCMODE | os.O_NONBLOCK | os.O_APPEND | os.O_ASYNC
            self.assertEqual(fcntl.fcntl(endpoint, fcntl.F_GETFL) & modes, original & modes)
        finally:
            os.close(controller)
            os.close(endpoint)

    def test_full_and_disconnected_pipe_refusal_exits_without_drain_or_sigpipe(self):
        for disconnected in (False, True):
            with self.subTest(disconnected=disconnected):
                reader, writer = os.pipe()
                try:
                    if disconnected:
                        os.close(reader)
                        reader = None
                        original = fcntl.fcntl(writer, fcntl.F_GETFL)
                    else:
                        original = self.fill(writer)
                    self.run_refusal(writer)
                    self.assertEqual(fcntl.fcntl(writer, fcntl.F_GETFL), original)
                finally:
                    if reader is not None:
                        os.close(reader)
                    os.close(writer)

    def test_available_refusal_is_constant_and_other_command_errors_are_unchanged(self):
        reader, writer = os.pipe()
        try:
            fcntl.fcntl(writer, fcntl.F_SETFL, fcntl.fcntl(writer, fcntl.F_GETFL) | os.O_NONBLOCK)
            self.run_refusal(writer)
            self.assertEqual(os.read(reader, 512).decode(), REFUSAL)
        finally:
            os.close(reader)
            os.close(writer)
        # Blocking redirected descriptors are unsupported rather than globally changing shared flags.
        result = subprocess.run([str(HAILD), "coaching", "--authored-invalid-option"], cwd=REPO,
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 64)
        self.assertEqual(result.stderr, "")
        self.assertEqual(result.stdout, "")
        ordinary = subprocess.run([str(HAILD), "unknown-authored-command"], cwd=REPO,
                                  capture_output=True, text=True, timeout=5)
        self.assertEqual(ordinary.returncode, 64)
        self.assertIn("usage:", ordinary.stderr.lower())
        self.assertNotIn(REFUSAL, ordinary.stderr)

    def test_regular_file_diagnostic_is_skipped_instead_of_assuming_nonblocking_file_io(self):
        with tempfile.TemporaryFile() as output:
            self.run_refusal(output)
            output.seek(0)
            self.assertEqual(output.read(), b"")
