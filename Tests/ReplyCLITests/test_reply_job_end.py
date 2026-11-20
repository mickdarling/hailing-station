"""#1241: synthetic queued PCM, publication failure, and caller signals around ready."""
import base64
import os
import signal
from pathlib import Path
import unittest

import test_reply_cli as support


class ReplyJobEndTests(unittest.TestCase):
    def setUp(self):
        self.rig = support.ReplyCLITests()
        self.rig.setUp()
        self.addCleanup(self.rig.doCleanups)

    def test_queue_slash_heavy_stream_fits_and_logs_done_once(self):
        env = self.rig.speech_environment(3)
        env["REPLY_RENDERER_TEST_BYTE"] = "255"
        env["HAILD_REPLY_PACING"] = "off"
        raw = []
        with self.rig.reply_server(lambda index: {"delivered": 1}, raw_requests=raw) as (path, frames):
            result = self.rig.run_reply(["--say", "synthetic"], path, env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.rig.await_jobs()
        audio = [frame["payload"] for _, frame in frames if frame["type"] == "audio"]
        self.assertEqual([len(base64.b64decode(p["bytes"])) for p in audio], [24000, 36000, 60000, 24000, 2])
        self.assertTrue(audio[-1]["final"])
        self.assertTrue(all(len(line) - 1 <= 91477 for line in raw))
        self.assertEqual(self.rig.job_ends, [{"kind": "reply-job-ended", "reason": "done", "frames": 6,
                                             "audioMS": 3000}])

    def test_publication_failure_logs_primary_reason_after_terminal_recovery(self):
        env = self.rig.speech_environment(3)
        env["HAILD_REPLY_PACING"] = "off"
        def respond(index):
            return {"delivered": 0, "code": "publicationFailed", "error": "synthetic publication failure"} if index == 2 else {"delivered": 1}
        with self.rig.reply_server(respond) as (path, frames):
            result = self.rig.run_reply(["--say", "synthetic"], path, env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.rig.await_jobs()
        self.assertEqual(len(self.rig.job_ends), 1)
        report = self.rig.job_ends[0]
        self.assertEqual(report["reason"], "publication_failed")
        self.assertEqual(report["frames"], 3)  # text, accepted PCM, recovery terminal
        self.assertEqual(report["audioMS"], 500)
        self.assertTrue(frames[-1][1]["payload"]["final"])

    def test_signals_after_ready_preserve_both_chunks_and_terminal(self):
        env = self.rig.speech_environment(1)
        env["REPLY_RENDERER_TEST_STDOUT_BYTES"] = "60000"
        env["REPLY_RENDERER_TEST_PAUSE_AFTER_FIRST_FRAME"] = "1"
        resume = Path(os.environ["TMPDIR"]) / "resume-renderer"
        env["REPLY_RENDERER_TEST_RESUME_FILE"] = str(resume)
        with self.rig.reply_server(lambda index: {"delivered": 1}) as (path, frames):
            result = self.rig.run_reply(["--say", "synthetic"], path, env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(frames), 2)  # renderer is paused after its first chunk
            for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                os.kill(self.rig.jobs[-1], signum)
            resume.touch()
            self.rig.await_jobs()
        audio = [frame["payload"] for _, frame in frames if frame["type"] == "audio"]
        self.assertEqual([p["sequence"] for p in audio], [0, 1, 2])
        self.assertEqual([p["final"] for p in audio], [False, False, True])
        self.assertEqual([len(base64.b64decode(p["bytes"])) for p in audio], [24000, 36000, 2])
        self.assertEqual(len(self.rig.job_ends), 1)
        self.assertEqual(self.rig.job_ends[0]["reason"], "done")

    def test_sigterm_before_ready_still_cancels(self):
        self.rig.assert_caller_loss_before_ready_ends_the_job(signal.SIGTERM)
        self.assertEqual(len(self.rig.job_ends), 1)
        self.assertEqual(self.rig.job_ends[0]["reason"], "signal")

    def test_static_publication_failure_stays_primary_when_terminal_is_refused(self):
        env = self.rig.speech_environment(1)
        env["HAILD_REPLY_PACING"] = "off"
        pcm = Path(os.environ["TMPDIR"]) / "synthetic.pcm"
        pcm.write_bytes(bytes(49_152 * 2 + 2))
        def queued(message, response):
            frame = message.get("frame", {})
            payload = frame.get("payload", {})
            if message["action"] == "publish" and payload["sequence"] == 1 and not payload["final"]:
                return None  # publication may have happened; no acknowledgement
            return response
        def respond(index):
            return {"delivered": 1} if index < 3 else {"delivered": 0, "error": "reply stopped"}
        with self.rig.reply_server(respond, audio_queue=queued) as (path, frames):
            result = self.rig.run_reply(["--text", "synthetic", "--pcm16", str(pcm)], path, env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.rig.await_jobs()
        self.assertTrue(frames[-1][1]["payload"]["final"])
        self.assertEqual(self.rig.job_ends, [{"kind": "reply-job-ended", "reason": "publication_failed",
                                             "frames": 2, "audioMS": 1024}])
