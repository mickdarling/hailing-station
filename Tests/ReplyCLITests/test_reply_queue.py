"""#904: real detached CLI jobs sharing an audio turn; synthetic local frames only."""

import base64
import fcntl
import os
import signal
import subprocess
import unittest
import uuid
from pathlib import Path

import test_reply_cli as support


class ReplyQueueTests(unittest.TestCase):
    def setUp(self):
        self.rig = support.ReplyCLITests()
        self.rig.setUp()
        self.addCleanup(self.rig.doCleanups)

    def start_reply(self, path, target, seconds, request=False):
        arguments = [str(support.HAILD), "reply", target, "--host", "mac-test",
                     "--say", "synthetic queue test", "--socket", path]
        if request:
            arguments += ["--request", str(uuid.uuid4())]
        result = self.rig.track(subprocess.run(
            arguments, cwd=support.REPO, env=self.rig.speech_environment(seconds),
            capture_output=True, text=True, timeout=15, start_new_session=True,
        ))
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_cross_target_request_gets_all_audio_within_its_data_budget(self):
        with self.rig.reply_server(lambda index: {"delivered": 1}) as (path, frames):
            self.start_reply(path, "tmux:older", 60)
            newer = self.start_reply(path, "tmux:newer", 1, request=True)
            self.assertIn("queued behind another reply", newer.stderr)
            self.assertIn("streams in the background", newer.stdout)
            self.rig.wait_for(lambda: not self.rig.alive(self.rig.jobs[-1]), 65)
        old = [(at, frame) for at, frame in frames if frame["target"] == "tmux:older"]
        new = [(at, frame) for at, frame in frames if frame["target"] == "tmux:newer"]
        self.assert_complete_audio(old, 60, 50)
        self.assert_complete_audio(new, 1, 3)
        first_audio = next(at for at, frame in new if frame["type"] == "audio")
        waited = first_audio - new[0][0]  # last accepted text, not caller return or the older job's start
        print(f"#904 queue: newer first audio after text={waited:.3f}s; old=50 new=3 audio frames", flush=True)
        self.assertLess(waited, 40)
        self.assertGreater(first_audio, old[-1][0])

    def test_killed_waiter_releases_signal_and_holder_returns_to_small_lead(self):
        with self.rig.reply_server(lambda index: {"delivered": 1}) as (path, frames):
            self.start_reply(path, "tmux:older", 30)
            newer = self.start_reply(path, "tmux:newer", 1, request=True)
            self.assertIn("queued behind another reply", newer.stderr)
            waiters = Path(path).with_name("reply-audio.waiters")
            self.assertEqual(waiters.stat().st_mode & 0o777, 0o600)
            with waiters.open("r+") as probe:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                os.killpg(self.rig.jobs[-1], signal.SIGKILL)
                self.rig.wait_for(lambda: not self.rig.alive(self.rig.jobs[-1]), 5)
                # The holder briefly probes too; retry that observation rather than racing its exclusive lock.
                def released():
                    try:
                        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        return False
                    fcntl.flock(probe, fcntl.LOCK_UN)
                    return True
                self.rig.wait_for(released, 5)
            self.rig.wait_for(lambda: any(f["type"] == "audio" and f["payload"]["final"]
                                         for _, f in frames), 40)
        old = [(at, frame) for at, frame in frames if frame["target"] == "tmux:older"]
        self.assert_complete_audio(old, 30, 26)
        audio = [(at, frame) for at, frame in old if frame["type"] == "audio"]
        # A stale 20 s signal would finish in about 10 s; normal 3 s pacing finishes after 25 s.
        self.assertGreater(audio[-1][0] - audio[0][0], 25)

    def assert_complete_audio(self, frames, seconds, count):
        audio = [frame["payload"] for _, frame in frames if frame["type"] == "audio"]
        self.assertEqual(len(audio), count)
        self.assertEqual([frame["sequence"] for frame in audio], list(range(count)))
        self.assertEqual([frame["final"] for frame in audio], [False] * (count - 1) + [True])
        # The renderer uses a two-byte terminal marker in addition to the actual PCM.
        self.assertEqual(sum(len(base64.b64decode(frame["bytes"])) for frame in audio[:-1]), seconds * 48_000)
