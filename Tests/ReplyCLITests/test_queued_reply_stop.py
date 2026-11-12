"""#1212: real CLI jobs waiting on a held flock; owner-only socket replies are synthetic."""

import contextlib
import signal
import fcntl
import os
import subprocess
import tempfile
import unittest
import uuid
from pathlib import Path

import test_reply_cli as support


class QueuedReplyStopTests(unittest.TestCase):
    def setUp(self):
        self.rig = support.ReplyCLITests()
        self.rig.setUp()
        self.addCleanup(self.rig.doCleanups)

    def test_stopped_waiter_keeps_text_and_never_submits_audio(self):
        self.exercise(skipped=True, pcm=False)

    def test_pcm_waiter_skips_cleanly_too(self):
        self.exercise(skipped=True, pcm=True)

    def test_later_waiter_publishes_with_its_daemon_ticket(self):
        self.exercise(skipped=False, pcm=False)

    def test_queue_controls_retry_only_explicit_prepublication_refusals(self):
        self.exercise(skipped=False, pcm=False, mode="retry")

    def test_stop_between_admission_and_first_audio_exits_cleanly(self):
        self.exercise(skipped=False, pcm=False, mode="publish_skip")

    def test_legacy_daemon_cannot_silently_admit_unguarded_queued_audio(self):
        self.exercise(skipped=False, pcm=False, mode="legacy")

    def test_exact_old_daemon_decode_refusal_uses_legacy_audio_once(self):
        self.exercise(skipped=False, pcm=False, mode="old", contended=False)

    def test_new_daemon_decode_refusal_fails_closed(self):
        self.exercise(skipped=False, pcm=False, mode="new_decode", contended=False)

    def test_uncoded_decode_refusal_fails_closed(self):
        self.exercise(skipped=False, pcm=False, mode="uncoded", contended=False)

    def test_inexact_old_daemon_error_fails_closed(self):
        self.exercise(skipped=False, pcm=False, mode="wrong_error", contended=False)

    def test_explicit_null_queue_report_fails_closed(self):
        self.exercise(skipped=False, pcm=False, mode="null_report", contended=False)

    def test_exact_old_signal_at_check_never_downgrades(self):
        self.exercise(skipped=False, pcm=False, mode="old_check", contended=False)

    def test_exact_old_signal_at_publish_never_downgrades(self):
        self.exercise(skipped=False, pcm=False, mode="old_publish", contended=False)

    def test_malformed_ticket_response_fails_closed(self):
        self.exercise(skipped=False, pcm=False, mode="malformed", contended=False)

    def test_connection_loss_at_ticket_keeps_text_and_fails_closed(self):
        self.exercise(skipped=False, pcm=False, mode="connection", contended=False)

    def test_stop_between_ticket_and_text_keeps_text_but_skips_audio(self):
        self.exercise(skipped=True, pcm=False, contended=False)

    def test_uncontended_job_holding_lock_at_stop_skips_before_rendering(self):
        self.exercise(skipped=True, pcm=False, contended=False)

    def test_uncontended_job_after_stop_publishes_every_frame_with_ticket(self):
        self.exercise(skipped=False, pcm=False, contended=False)

    def test_daemon_restart_refuses_stale_waiter_without_audio_skip(self):
        self.exercise(skipped=False, pcm=False, mode="stale")

    def test_capacity_refusal_keeps_speech_text_and_card_without_rendering(self):
        self.exercise(skipped=False, pcm=False, mode="capacity", contended=False)

    def test_capacity_refusal_keeps_pcm_text_and_card_without_audio(self):
        self.exercise(skipped=False, pcm=True, mode="capacity", contended=False)

    def test_expired_check_has_distinct_note(self):
        self.exercise(skipped=True, pcm=True, skip_reason="expired")

    def test_wait_budget_check_has_distinct_note(self):
        self.exercise(skipped=True, pcm=True, skip_reason="wait_budget")

    def test_expired_publish_has_distinct_note(self):
        self.exercise(skipped=False, pcm=True, mode="publish_skip", skip_reason="expired")

    def test_wait_budget_publish_has_distinct_note(self):
        self.exercise(skipped=False, pcm=True, mode="publish_skip", skip_reason="wait_budget")

    def test_capacity_without_actual_text_delivery_is_refused(self):
        self.exercise(skipped=False, pcm=True, mode="capacity", contended=False, text_deliveries=0)

    def test_audio_only_pcm_capacity_refusal_is_nonzero_and_not_retried(self):
        controls = []

        def queued(message, response):
            return {"delivered": 0, "replyAudio": {"skipped": True, "reason": "capacity"}}

        with tempfile.TemporaryDirectory(prefix="hail-capacity-") as scratch:
            audio = Path(scratch) / "synthetic.pcm"
            audio.write_bytes(bytes(480))
            with self.rig.reply_server(lambda index: {"delivered": 1}, audio_queue=queued,
                                       queue_requests=controls) as (path, frames):
                environment = self.rig.speech_environment(1)
                environment["HAILD_REPLY_BACKGROUND"] = str(os.getpid())
                result = subprocess.run([str(support.HAILD), "reply", "tmux:capacity", "--host", "mac-test",
                                         "--socket", path, "--pcm16", str(audio)], cwd=support.REPO,
                                        env=environment, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(result.stderr,
                                 b"haild: reply audio dropped: capacity; no text or card delivered\n")
                self.assertEqual([item["action"] for item in controls], ["enqueue"])
                self.assertEqual(frames, [])

    def exercise(self, skipped, pcm, mode=None, contended=True, skip_reason="stopped", text_deliveries=1):
        request = str(uuid.uuid4()).upper()
        controls, attempts, wire_order = [], {}, []

        def frame_response(index):
            wire_order.append("frame")
            return {"delivered": text_deliveries}

        def queue_response(message, response):
            action = message["action"]
            if action == "release":
                return {"delivered": 0, "replyAudio": {"skipped": False}}
            attempts[action] = attempts.get(action, 0) + 1
            wire_order.append(action)
            if mode == "capacity" and action == "enqueue":
                return {"delivered": 0, "replyAudio": {"skipped": True, "reason": "capacity"}}
            if mode == "malformed" and action == "enqueue":
                return {"delivered": "zero"}
            if (mode in ("old", "new_decode", "uncoded", "wrong_error", "null_report") and action == "enqueue"
                    or mode == "old_check" and action == "check"
                    or mode == "old_publish" and action == "publish"):
                # Exact response from f3f97bc7 and cc36af90: unknown kind falls through to submitReply.
                refusal = {"delivered": 0, "code": "decodeFailure",
                           "error": "reply refused [decodeFailure]: frame decode failure"}
                if mode == "new_decode":
                    refusal["replyAudio"] = {"skipped": False}
                elif mode == "null_report":
                    refusal["replyAudio"] = None
                elif mode == "uncoded":
                    del refusal["code"]
                elif mode == "wrong_error":
                    refusal["error"] = "frame decode failure"
                return refusal
            if mode == "connection" and action == "enqueue":
                return None
            if mode == "legacy" and action == "enqueue":
                return {"delivered": 1}
            if mode == "retry" and attempts[action] == 1:
                if action == "enqueue":
                    return {"delivered": 0, "error": "rate limited"}
                if action == "check":
                    return {"delivered": 0, "code": "requestPending"}
            if action == "check":
                # The check is after acquisition even without contention; the job owns this kernel lock.
                with lock.open("r+") as observer:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(observer, fcntl.LOCK_EX | fcntl.LOCK_NB)
                if mode == "stale":
                    return {"delivered": 0, "error": "invalid reply payload", "code": "invalidReplyPayload"}
                return {"delivered": 0, "replyAudio": {"skipped": skipped, "reason": skip_reason if skipped else None}}
            if mode == "publish_skip" and action == "publish":
                return {"delivered": 0, "replyAudio": {"skipped": True, "reason": skip_reason}}
            return response

        with tempfile.TemporaryDirectory(prefix="hail-queue-stop-") as scratch:
            with self.rig.reply_server(frame_response, audio_queue=queue_response,
                                       queue_requests=controls) as (path, frames):
                lock = Path(path).with_name("reply-audio.lock")
                with lock.open("w+") as holder:
                    if contended:
                        fcntl.flock(holder, fcntl.LOCK_EX)
                    environment = self.rig.speech_environment(1)
                    renderer_pid = Path(scratch) / "renderer.pid"
                    environment["REPLY_RENDERER_TEST_PIDFILE"] = str(renderer_pid)
                    # Direct detached-job mode keeps the child owned and waitable by this test. No renderer is
                    # spawned until admission, and the kernel lock is released only after observing its ticket.
                    environment["HAILD_REPLY_BACKGROUND"] = str(os.getpid())
                    arguments = [str(support.HAILD), "reply", "tmux:queue", "--host", "mac-test",
                                 "--socket", path, "--request", request, "--metadata", "synthetic card"]
                    if pcm:
                        audio = Path(scratch) / "synthetic.pcm"
                        audio.write_bytes(bytes(480))
                        arguments += ["--text", "synthetic response", "--pcm16", str(audio)]
                    else:
                        arguments += ["--say", "synthetic response"]
                    job = subprocess.Popen(arguments, cwd=support.REPO, env=environment,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                    self.addCleanup(self.finish_job, job)
                    self.rig.wait_for(lambda: len(controls) >= 1, 10)
                    self.assertEqual(controls[0]["action"], "enqueue")
                    self.rig.wait_for(lambda: len(frames) >= 1, 10)
                    self.assertEqual(wire_order[:wire_order.index("frame")], ["enqueue"] * attempts["enqueue"])
                    self.assertEqual(frames[0][1]["payload"]["text"], "synthetic response")
                    self.assertEqual(frames[0][1]["payload"]["metadata"], "synthetic card")
                    if contended and mode not in ("legacy", "connection", "new_decode", "uncoded", "wrong_error"):
                        self.rig.wait_for(lambda: self.waiter_registered(lock.with_name("reply-audio.waiters")), 10)
                    fcntl.flock(holder, fcntl.LOCK_UN)
                    stdout, stderr = job.communicate(timeout=15)
                    self.assertEqual(job.returncode, 1 if mode in ("legacy", "stale", "connection", "new_decode",
                                                                    "uncoded", "wrong_error", "old_check",
                                                                    "old_publish", "malformed", "null_report")
                                     or mode == "capacity" and text_deliveries == 0 else 0, stderr.decode())
                    if mode == "capacity":
                        expected = b"haild: reply audio dropped: capacity"
                        if text_deliveries == 0:
                            expected += b"; no text or card delivered"
                        self.assertEqual(stderr, expected + b"\n")
                    if skipped or mode == "publish_skip":
                        expected = {"stopped": b"reply audio skipped after a stop", "expired": b"reply audio expired",
                                    "wait_budget": b"reply audio skipped: stop wait budget"}[skip_reason]
                        notes = [line for line in stderr.splitlines() if line != b"haild: reply audio queued behind another reply"]
                        self.assertEqual(notes, [b"haild: " + expected])
                    if mode == "old":
                        self.assertEqual(stderr.count(b"reply_audio_queue unsupported"), 1)
                        self.assertEqual([item["action"] for item in controls if item["action"] != "release"], ["enqueue"])
                        self.assertGreater(len(frames), 1)
                        self.assertTrue(frames[-1][1]["payload"]["final"])
                        return
                    if mode in ("connection", "new_decode", "uncoded", "wrong_error", "malformed", "null_report", "capacity"):
                        self.assertFalse(renderer_pid.exists())
                        self.assertNotIn(b"reply_audio_queue unsupported", stderr)
                        self.assertEqual(len(frames), 1)
                        self.assertEqual([item["action"] for item in controls if item["action"] != "release"], ["enqueue"])
                        return
                    if mode in ("old_check", "old_publish"):
                        self.assertNotIn(b"reply_audio_queue unsupported", stderr)
                        audio_frames = [frame for _, frame in frames if frame["type"] == "audio"]
                        # The mock records attempted frames before refusing them. Every attempt stays ticketed;
                        # no legacy raw frame may follow a check/publish refusal.
                        self.assertEqual(len(audio_frames), attempts.get("publish", 0))
                        self.assertTrue(all(item.get("ticket") for item in controls if item["action"] == "publish"))
                        self.assertEqual([c for c in controls if c["action"] != "release"][-1]["action"],
                                         mode.removeprefix("old_"))
                        return
                    if mode == "legacy":
                        self.assertIn(b"daemon does not support queued reply audio", stderr)
                        self.assertEqual(len(frames), 1)
                        return
                    if mode == "stale":
                        self.assertNotIn(b"reply audio skipped after a stop", stderr)
                        self.assertEqual(len(frames), 1)
                        self.assertEqual([item["action"] for item in controls if item["action"] != "release"], ["enqueue", "check"])
                        return
                    if contended:
                        self.assertIn(b"reply audio queued behind another reply", stderr)
                    else:
                        self.assertNotIn(b"reply audio queued behind another reply", stderr)
                checks = [item for item in controls if item["action"] == "check"]
                ticket = checks[-1]["ticket"]
                self.assertGreater(ticket["position"], 0)
                self.assertEqual(checks[-1]["frame"]["payload"]["reply"]["request"], request)
                if mode == "publish_skip":
                    self.assertEqual(len(frames), 2)
                    self.assertFalse(frames[-1][1]["payload"]["final"])
                    self.assertEqual(attempts["publish"], 1)
                elif skipped:
                    self.assertEqual([item["action"] for item in controls if item["action"] != "release"], ["enqueue", "check"])
                    self.assertEqual(len(frames), 1)  # completed job, not a negative assertion after a delay
                    self.assertFalse(renderer_pid.exists())
                else:
                    publications = [item for item in controls if item["action"] == "publish"]
                    self.assertTrue(publications)
                    self.assertEqual(len(publications), sum(frame[1]["type"] == "audio" for frame in frames))
                    self.assertTrue(all(item["ticket"] == ticket for item in publications))
                    self.assertTrue(frames[-1][1]["payload"]["final"])
                if mode == "retry":
                    self.assertEqual(attempts["enqueue"], 2)
                    self.assertEqual(attempts["check"], 2)
                    self.assertEqual(checks[0], checks[1])

    @staticmethod
    def waiter_registered(path):
        if not path.exists():
            return False
        with path.open("r+") as observer:
            try:
                fcntl.flock(observer, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
        return False

    @staticmethod
    def finish_job(job):
        if job.poll() is None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(job.pid, signal.SIGKILL)
        job.communicate(timeout=10)
