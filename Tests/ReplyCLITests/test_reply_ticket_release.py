"""#1212: content-free reservation cleanup on completed CLI exit paths; synthetic socket only."""
import fcntl
import os
import signal
import subprocess
import tempfile
import unittest
from pathlib import Path

import test_reply_cli as support


class ReplyTicketReleaseTests(unittest.TestCase):
    def setUp(self):
        self.rig = support.ReplyCLITests()
        self.rig.setUp()
        self.addCleanup(self.rig.doCleanups)

    def test_refused_text_releases_ticket(self):
        self.exercise("text")

    def test_exhausted_check_retry_window_releases_ticket(self):
        self.exercise("retry")

    def test_request_bound_waiter_gives_up_and_releases_ticket(self):
        self.exercise("request")

    def test_sigterm_waiter_releases_ticket(self):
        self.exercise("signal")

    def test_audio_time_bound_releases_ticket(self):
        self.exercise("bound")

    def exercise(self, mode):
        controls = []
        pcm = None

        def response(index):
            if mode == "bound" and index == 0:
                # Grow only after preflight and ticket issuance, before acknowledging its text.
                with pcm.open("r+b") as audio:
                    audio.truncate(24_000 * 2 * 1801)
            if mode == "text":
                return {"delivered": 0, "code": "noRecipient", "error": "synthetic text refusal"}
            return {"delivered": 1}

        def queued(message, result):
            if mode == "retry" and message["action"] == "check":
                return {"delivered": 0, "code": "requestPending"}
            return result

        with tempfile.TemporaryDirectory(prefix="hail-release-") as scratch:
            with self.rig.reply_server(response, audio_queue=queued, queue_requests=controls,
                                       caller_may_vanish=True) as (path, frames):
                lock = Path(path).with_name("reply-audio.lock")
                with lock.open("w+") as holder:
                    if mode in ("request", "signal"):
                        fcntl.flock(holder, fcntl.LOCK_EX)
                    env = self.rig.speech_environment(1)
                    env["HAILD_REPLY_BACKGROUND"] = str(os.getpid())
                    args = [str(support.HAILD), "reply", "tmux:release", "--host", "mac-test",
                            "--socket", path]
                    if mode == "request":
                        args += ["--request", "00000000-0000-4000-8000-000000000001"]
                    if mode == "bound":
                        pcm = Path(scratch) / "oversized.pcm"
                        pcm.write_bytes(bytes(480))
                        args += ["--text", "synthetic", "--pcm16", str(pcm)]
                    else:
                        args += ["--say", "synthetic"]
                    job = subprocess.Popen(args, cwd=support.REPO, env=env, stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, start_new_session=True)
                    self.addCleanup(self.finish, job)
                    self.rig.wait_for(lambda: len(frames) == 1, 10)
                    if mode == "signal":
                        # Observe its actual kernel wait before cancellation, without a settling delay.
                        from test_queued_reply_stop import QueuedReplyStopTests
                        self.rig.wait_for(lambda: QueuedReplyStopTests.waiter_registered(
                            lock.with_name("reply-audio.waiters")), 10)
                        job.send_signal(signal.SIGTERM)
                    _, stderr = job.communicate(timeout=50)
                    self.assertNotEqual(job.returncode, 0, stderr)
                releases = [item for item in controls if item["action"] == "release"]
                self.assertEqual(len(releases), 1, controls)
                self.assertEqual(set(releases[0]), {"kind", "action", "ticket"})
                self.assertEqual(releases[0]["ticket"], next(
                    item["ticket"] for item in controls if item["action"] in ("check", "release")))
                self.assertFalse(any(item["action"] == "publish" for item in controls))
                self.assertEqual(len(frames), 1)
                if mode == "retry":
                    self.assertEqual(sum(item["action"] == "check" for item in controls), 8)

    @staticmethod
    def finish(job):
        if job.poll() is None:
            os.killpg(job.pid, signal.SIGKILL)
        job.communicate(timeout=10)
