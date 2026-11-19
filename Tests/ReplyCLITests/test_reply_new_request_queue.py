"""#1246: real detached CLI jobs, synthetic PCM/socket; no physical playback claim."""
import base64
import fcntl
import os
import signal
import time
import uuid
import tempfile
import unittest
from pathlib import Path

import test_reply_cli as support


class ReplyNewRequestQueueTests(unittest.TestCase):
    def setUp(self):
        self.rig = support.ReplyCLITests()
        self.rig.setUp()
        self.addCleanup(self.rig.doCleanups)

    def test_same_target_request_waits_for_every_segment_and_terminal(self):
        older_env = self.rig.speech_environment(3)
        older_env.update(HAILD_REPLY_SEGMENT_MAX_SENTENCES="1", HAILD_REPLY_SEGMENT_MAX_WORDS="300",
                         REPLY_RENDERER_TEST_BYTE="7")
        newer_env = self.rig.speech_environment(1)
        newer_env.update(HAILD_REPLY_SEGMENT_MAX_SENTENCES="1", HAILD_REPLY_SEGMENT_MAX_WORDS="300",
                         REPLY_RENDERER_TEST_BYTE="9")
        with tempfile.TemporaryDirectory(prefix="h1246-") as scratch:
            # The second segment exceeds the 20 s queued lead: a waiter cannot race a nearly ended reply.
            older_env["REPLY_RENDERER_TEST_STDOUT_BYTES"] = "192000,1440000"
            older_env["REPLY_RENDERER_TEST_INVOCATIONS"] = str(Path(scratch) / "invocations")
            with self.rig.reply_server(lambda index: {"delivered": 1}) as (path, frames):
                older = self.rig.run_reply(["--say", "First synthetic sentence. Second synthetic sentence.",
                                            "--request", "22222222-2222-4222-8222-222222222222"], path, older_env)
                self.assertEqual(older.returncode, 0, older.stderr)
                self.rig.wait_for(lambda: any(f["payload"].get("segmentEnd") for _, f in frames), support.SLOW)
                newer = self.rig.run_reply(["--say", "Next synthetic sentence.", "--request",
                                            "11111111-1111-4111-8111-111111111111"], path, newer_env)
                self.assertEqual(newer.returncode, 0, newer.stderr)
                self.assertIn("queued behind another reply", newer.stderr)
                self.rig.wait_for(lambda: sum(f["type"] == "audio" and f["payload"]["final"]
                                             for _, f in frames) == 2, support.SLOW)
                self.assertFalse(list(Path(path).parent.glob("reply-audio.stop-*")))
        streams = {}
        for index, (_, frame) in enumerate(frames):
            if frame["type"] == "audio":
                streams.setdefault(frame["payload"]["streamId"], []).append((index, frame["payload"]))
        self.assertEqual(len(streams), 2)
        first, second = sorted(streams.values(), key=lambda entries: entries[0][0])
        self.assertTrue(first[-1][1]["final"])
        self.assertTrue(second[-1][1]["final"])
        self.assertEqual(sum(bool(payload.get("segmentEnd")) for _, payload in first), 1)
        for stream, value, expected in [(first, 7, 1632000), (second, 9, 48000)]:
            self.assertEqual([p["sequence"] for _, p in stream], list(range(len(stream))))
            pcm = b"".join(base64.b64decode(p["bytes"]) for _, p in stream if not p["final"])
            self.assertEqual(pcm, bytes([value]) * expected)
        self.assertLess(first[-1][0], second[0][0])
        text_positions = [i for i, (_, f) in enumerate(frames) if f["type"] == "text"]
        self.assertLess(text_positions[1], first[-1][0])

    def test_dead_previous_epoch_records_are_collected(self):
        # Reviewer probe: ten unlocked historical records survive a daemon restart.
        with self.rig.reply_server(lambda index: {"delivered": 1}) as (path, frames):
            directory = Path(path).parent
            orphans = [directory / f"reply-audio.ticket-{str(uuid.uuid4()).upper()}-1" for _ in range(10)]
            for orphan in orphans:
                orphan.touch(mode=0o600)
            # A live historical waiter must survive cleanup without blocking current-epoch admission.
            live = directory / f"reply-audio.ticket-{str(uuid.uuid4()).upper()}-1"
            with live.open("w") as record:
                fcntl.flock(record, fcntl.LOCK_EX)
                result = self.rig.run_reply(["--say", "Synthetic reply."], path, self.rig.speech_environment(1))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.rig.wait_for(lambda: len(self.rig.job_ends) == 1, 10)
                self.assertEqual(list(directory.glob("reply-audio.ticket-*")), [live])
                self.assertTrue(any(frame["type"] == "audio" for _, frame in frames))
            # Once its kernel lock is released, a subsequent job collects it too.
            result = self.rig.run_reply(["--say", "Synthetic reply."], path, self.rig.speech_environment(1))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.rig.wait_for(lambda: len(self.rig.job_ends) == 2, 10)
            self.assertFalse(list(directory.glob("reply-audio.ticket-*")))

    def test_orphan_cleanup_progresses_across_bounded_scan_passes(self):
        with self.rig.reply_server(lambda index: {"delivered": 1}) as (path, frames):
            directory = Path(path).parent
            # More than one 4096-entry scan: reaching the bound must defer, clean and make progress.
            epoch = str(uuid.uuid4()).upper()
            for position in range(1, 4_201):
                (directory / f"reply-audio.ticket-{epoch}-{position}").touch(mode=0o600)
            result = self.rig.run_reply(["--say", "Synthetic reply."], path, self.rig.speech_environment(1))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.rig.wait_for(lambda: len(self.rig.job_ends) == 1, 10)
            self.assertFalse(list(directory.glob("reply-audio.ticket-*")))
            self.assertTrue(any(frame["type"] == "audio" for _, frame in frames))

    def launch(self, path, request, seconds=1, **overrides):
        environment = self.rig.speech_environment(seconds)
        environment.update(overrides)
        result = self.rig.run_reply(["--say", "Synthetic reply.", "--request", request], path, environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    @staticmethod
    def audio_order(frames):
        order = []
        for _, frame in frames:
            if frame["type"] == "audio":
                request = frame["payload"]["reply"]["request"]
                if request not in order:
                    order.append(request)
        return order

    def test_85_second_first_reply_preserves_every_queued_frame(self):
        requests = [str(uuid.uuid4()).upper() for _ in range(2)]
        with self.rig.reply_server(lambda index: {"delivered": 1}) as (path, frames):
            self.launch(path, requests[0], 85, REPLY_RENDERER_TEST_BYTE="7")
            result = self.launch(path, requests[1], REPLY_RENDERER_TEST_BYTE="9")
            self.assertIn("queued behind another reply", result.stderr)
            self.rig.wait_for(lambda: len(self.rig.job_ends) == 2, 110)
        self.assertEqual(self.audio_order(frames), requests)
        for request, seconds, value in zip(requests, [85, 1], [7, 9]):
            audio = [f["payload"] for _, f in frames if f["type"] == "audio"
                     and f["payload"]["reply"]["request"] == request]
            self.assertTrue(audio and audio[-1]["final"])
            self.assertEqual([p["sequence"] for p in audio], list(range(len(audio))))
            pcm = b"".join(base64.b64decode(p["bytes"]) for p in audio if not p["final"])
            self.assertEqual(pcm, bytes([value]) * (48000 * seconds))
        first_end = max(i for i, (_, f) in enumerate(frames) if f["type"] == "audio"
                        and f["payload"]["reply"]["request"] == requests[0])
        second_start = min(i for i, (_, f) in enumerate(frames) if f["type"] == "audio"
                           and f["payload"]["reply"]["request"] == requests[1])
        self.assertLess(first_end, second_start)

    def test_three_waiters_follow_ticket_order_in_repeated_poll_race(self):
        # Reuse review_queue_probe.py's held lock and deliberately unfavorable polling offset, with 3 waiters.
        for iteration in range(8):
            with self.subTest(iteration=iteration):
                requests = [str(uuid.uuid4()).upper() for _ in range(3)]
                ended = len(self.rig.job_ends)
                with self.rig.reply_server(lambda index: {"delivered": 1}) as (path, frames):
                    with open(Path(path).parent / "reply-audio.lock", "w") as held:
                        fcntl.flock(held, fcntl.LOCK_EX)
                        self.launch(path, requests[0])
                        first = time.monotonic()
                        time.sleep(0.12)
                        self.launch(path, requests[1])
                        time.sleep(0.04)
                        self.launch(path, requests[2])
                        release = first + 0.28
                        while release < time.monotonic():
                            release += 0.25
                        time.sleep(max(0, release - time.monotonic()))
                        fcntl.flock(held, fcntl.LOCK_UN)
                    self.rig.wait_for(lambda: len(self.rig.job_ends) == ended + 3, 15)
                self.assertEqual(self.audio_order(frames), requests)

    def test_killed_waiter_does_not_wedge_later_tickets(self):
        requests = [str(uuid.uuid4()).upper() for _ in range(3)]
        with self.rig.reply_server(lambda index: {"delivered": 1}) as (path, frames):
            with open(Path(path).parent / "reply-audio.lock", "w") as held:
                fcntl.flock(held, fcntl.LOCK_EX)
                self.launch(path, requests[0])
                dead = self.rig.jobs[-1]
                self.launch(path, requests[1])
                self.launch(path, requests[2])
                os.kill(dead, signal.SIGKILL)  # only the job this test launched
                self.rig.wait_for(lambda: not self.rig.alive(dead), 5)
                released = time.monotonic()
                fcntl.flock(held, fcntl.LOCK_UN)
            self.rig.wait_for(lambda: len(self.rig.job_ends) == 2, 10)
            first_audio = min(at for at, f in frames if f["type"] == "audio")
            self.assertLess(first_audio - released, 2)
            self.assertFalse(list(Path(path).parent.glob("reply-audio.ticket-*")))
        self.assertEqual(self.audio_order(frames), requests[1:])

    def test_queue_lifetime_has_an_honest_timeout_reason_and_no_audio(self):
        with self.rig.reply_server(lambda index: {"delivered": 1}) as (path, frames):
            with open(Path(path).parent / "reply-audio.lock", "w") as held:
                fcntl.flock(held, fcntl.LOCK_EX)
                self.launch(path, str(uuid.uuid4()).upper(), HAILD_REPLY_QUEUE_SECONDS="1")
                self.rig.wait_for(lambda: len(self.rig.job_ends) == 1, 10)
            self.assertFalse(list(Path(path).parent.glob("reply-audio.ticket-*")))
        self.assertFalse(any(f["type"] == "audio" for _, f in frames))
        self.assertEqual(self.rig.job_ends[0]["audioSkipReason"], "queue_timeout")
        self.assertEqual(self.rig.job_ends[0]["reason"], "refused")

    def test_explicit_stop_while_waiting_skips_before_turn_release(self):
        stopped = False
        def audio_queue(message, response):
            if stopped and message["action"] == "check":
                return {"delivered": 0, "replyAudio": {"skipped": True, "reason": "stopped"}}
            return response
        with self.rig.reply_server(lambda index: {"delivered": 1}, audio_queue=audio_queue) as (path, frames):
            with open(Path(path).parent / "reply-audio.lock", "w") as held:
                fcntl.flock(held, fcntl.LOCK_EX)
                self.launch(path, str(uuid.uuid4()).upper())
                stopped = True
                self.rig.wait_for(lambda: len(self.rig.job_ends) == 1, 25)
            self.assertFalse(list(Path(path).parent.glob("reply-audio.ticket-*")))
        self.assertFalse(any(f["type"] == "audio" for _, f in frames))

    def test_legacy_unticketed_wait_retains_40_second_request_deadline(self):
        started = time.monotonic()
        controls = []
        with self.rig.reply_server(lambda index: {"delivered": 1},
                                   audio_queue=self.rig.legacy_audio_queue, queue_requests=controls) as (path, frames):
            with open(Path(path).parent / "reply-audio.lock", "w") as held:
                fcntl.flock(held, fcntl.LOCK_EX)
                self.launch(path, str(uuid.uuid4()).upper(), HAILD_REPLY_QUEUE_SECONDS="1")
                self.rig.wait_for(lambda: len(self.rig.job_ends) == 1, 55)
            self.assertFalse(list(Path(path).parent.glob("reply-audio.ticket-*")))
        self.assertGreaterEqual(time.monotonic() - started, 39)
        self.assertFalse(any(f["type"] == "audio" for _, f in frames))
        self.assertEqual(self.rig.job_ends[0]["reason"], "refused")
        self.assertEqual([item["action"] for item in controls], ["enqueue"])
