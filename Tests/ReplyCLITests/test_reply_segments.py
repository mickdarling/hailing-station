"""#932 P2: synthetic segment rendering through the real CLI; no speech content in logs."""

import base64
import copy
import json
import os
import re
import signal
import statistics
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import test_reply_cli as support


class ReplySegmentCLITests(unittest.TestCase):
    def setUp(self):
        self.rig = support.ReplyCLITests()
        self.rig.setUp()
        self.addCleanup(self.rig.doCleanups)
        self.scratch = tempfile.TemporaryDirectory(prefix="hail-segments-")
        self.addCleanup(self.scratch.cleanup)
        self.record = Path(self.scratch.name) / "invocations"
        self.root = Path(self.scratch.name) / "output"
        self.root.mkdir(mode=0o700)

    def environment(self, counts="130000"):
        environment = self.rig.speech_environment(1)
        environment.update({
            "HAILD_REPLY_FOREGROUND": "1", "HAILD_REPLY_PACING": "off",
            "HAILD_REPLY_SEGMENT_MAX_SENTENCES": "1",
            "REPLY_RENDERER_TEST_STDOUT_BYTES": counts,
            "REPLY_RENDERER_TEST_INVOCATIONS": str(self.record),
            "REPLY_RENDERER_TEST_SEGMENT_BYTES": "1",
        })
        return environment

    def invocations(self):
        return [json.loads(line) for line in self.record.read_text().splitlines()] if self.record.exists() else []

    def run_speech(self, text, environment, binary=None):
        self.raw = []
        with self.rig.reply_server(lambda index: {"delivered": 1}, raw_requests=self.raw) as (path, frames):
            with mock.patch.object(support, "HAILD", binary or support.HAILD):
                result = self.rig.run_reply(
                    ["--say", text, "--renderer-output-root", str(self.root)], path, environment,
                )
            return result, frames

    def assert_outcome(self, expected):
        owner = self.invocations()[0]["owner"]
        result = subprocess.run(
            ["/usr/bin/log", "show", "--style", "ndjson", "--last", "2m", "--predicate",
             f'processID == {owner} AND subsystem == "com.mickdarling.hailing-station" '
             'AND category == "reply-timing-dev"'],
            capture_output=True, text=True, timeout=15, check=True,
        )
        messages = [json.loads(line).get("eventMessage", "") for line in result.stdout.splitlines()]
        outcomes = [message.rsplit("outcome=", 1)[1] for message in messages if "outcome=" in message]
        self.assertEqual(outcomes, [expected])  # one whole-reply timing outcome, never one per segment

    def assert_complete(self, frames, boundaries):
        audio = [frame for _, frame in frames if frame["type"] == "audio"]
        descriptor = frames[0][1]["payload"]["reply"]
        self.assertTrue(all(frame["payload"]["reply"] == descriptor for frame in audio))
        self.rig.assert_audio_identity(audio)
        self.assertEqual([i for i, frame in enumerate(audio) if frame["payload"].get("segmentEnd")], boundaries)
        self.assertEqual([frame["payload"]["final"] for frame in audio], [False] * (len(audio) - 1) + [True])
        return audio

    def test_multiple_segments_flush_remainders_in_order(self):
        text = "First sentence. Second sentence. Third sentence."
        result, frames = self.run_speech(text, self.environment())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(frames[0][1]["payload"]["text"], text)
        audio = self.assert_complete(frames, [3, 6])
        expected = [(1, 24000), (1, 36000), (1, 60000), (1, 10000),
                    (2, 60000), (2, 60000), (2, 10000),
                    (3, 60000), (3, 60000), (3, 10000)]
        self.assertEqual([base64.b64decode(frame["payload"]["bytes"]) for frame in audio[:-1]],
                         [bytes([value]) * size for value, size in expected])
        self.assertEqual(len(self.invocations()), 3)
        self.assertEqual(list(self.root.iterdir()), [])
        self.assertEqual(len({frame["id"] for _, frame in frames}), len(frames))
        self.assert_outcome("played")

    def test_exact_sized_segment_marks_held_frame(self):
        result, frames = self.run_speech("First. Second. Third.", self.environment("60000"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_complete(frames, [1, 2])
        self.assertEqual([len(base64.b64decode(f["payload"]["bytes"])) for _, f in frames[1:]],
                         [24000, 36000, 60000, 60000, 2])

    def test_files_only_fallback_segments_and_cleans_each_renderer(self):
        environment = self.environment()
        environment.pop("REPLY_RENDERER_TEST_STDOUT_BYTES")
        result, frames = self.run_speech("First. Second. Third.", environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        audio = self.assert_complete(frames, [0, 1])
        self.assertEqual([base64.b64decode(f["payload"]["bytes"]) for f in audio],
                         [bytes([0, 0, 1, 0])] * 3 + [bytes(2)])
        self.assertEqual(len(self.invocations()), 3)
        self.assertEqual(list(self.root.iterdir()), [])
        self.assert_outcome("played_unmeasured")

    def test_renderer_failure_in_segment_two_ends_reply_and_prevents_segment_three(self):
        environment = self.environment("60000")
        environment["REPLY_RENDERER_TEST_FAIL_SEGMENT"] = "2"
        environment["REPLY_RENDERER_TEST_RETAIN_FAILED_OUTPUT"] = "1"
        result, frames = self.run_speech("First. Second. Third.", environment)
        self.assertEqual(result.returncode, 1)
        self.assertIn("speech renderer exited unsuccessfully; owned output cleanup deferred", result.stderr)
        self.assert_complete(frames, [1])
        self.assertEqual(len(self.invocations()), 2)
        retained = list(self.root.glob("*/synthetic.raw"))
        self.assertEqual(len(retained), 1)  # abnormal renderer content is deferred; successful segment was removed
        self.assertEqual(retained[0].read_bytes(), bytes(4))
        self.assertTrue(all(not self.rig.alive(item["pid"]) for item in self.invocations()))
        self.assert_outcome("failed")

    def test_frame_budget_is_shared_across_segments(self):
        result, frames = self.run_speech("First. Second. Third.", self.environment("3600000"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("frame budget", result.stderr)
        audio = self.assert_complete(frames, [60])
        self.assertEqual(len(frames), 120)
        self.assertEqual(len(audio), 119)
        self.assertEqual(len(self.invocations()), 2)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_cancellation_mid_segment_stops_owned_child_and_later_segments(self):
        environment = self.environment("60000")
        environment["REPLY_RENDERER_TEST_STALL_AFTER_BYTES"] = "1"
        environment.pop("HAILD_REPLY_FOREGROUND")
        with self.rig.reply_server(lambda index: {"delivered": 1}) as (path, frames):
            result = self.rig.run_reply(["--say", "First. Second. Third.", "--socket", path,
                                         "--renderer-output-root", str(self.root)], path, environment)
            self.assertEqual(result.returncode, 0, result.stderr)
            job = self.rig.jobs[-1]
            self.rig.wait_for(lambda: len(frames) >= 2, 10)
            os.kill(job, signal.SIGTERM)  # bounded detached job cancels its Swift task cooperatively
            self.rig.await_jobs()
        self.assertEqual(len(self.invocations()), 1)
        self.assertTrue(all(not self.rig.alive(item["pid"]) for item in self.invocations()))
        self.assertEqual(list(self.root.iterdir()), [])
        # Existing Task cancellation also cancels terminal submission; no frames appear after retirement.
        self.assertFalse(any(frame["payload"].get("segmentEnd") for _, frame in frames))
        self.assert_outcome("cancelled")

    def test_supersession_mid_reply_never_starts_later_segment(self):
        environment = self.environment("2880000")
        environment.pop("HAILD_REPLY_FOREGROUND")
        environment.pop("HAILD_REPLY_PACING")
        with self.rig.reply_server(lambda index: {"delivered": 1}) as (path, frames):
            older = self.rig.run_reply(["--say", "First. Second. Third.",
                                        "--renderer-output-root", str(self.root)], path, environment)
            self.assertEqual(older.returncode, 0, older.stderr)
            newer = self.rig.run_reply(["--say", "Newer.", "--request", "00000000-0000-4000-8000-000000000001"],
                                       path, self.rig.speech_environment(1))
            self.assertEqual(newer.returncode, 0, newer.stderr)
            self.rig.await_jobs()
        old_id = frames[0][1]["payload"]["reply"]["id"]
        old_frames = [(at, f) for at, f in frames if f["payload"]["reply"]["id"] == old_id]
        self.assert_complete(old_frames, [])
        self.assertEqual(len(self.invocations()), 1)
        self.assertEqual(list(self.root.iterdir()), [])
        self.assertTrue(all(not self.rig.alive(item["pid"]) for item in self.invocations()))
        self.assert_outcome("superseded")

    @staticmethod
    def normalized_wire(raw):
        # Normalize only independently minted UUIDs and timestamp in the actual encoded wire bytes.
        frame = json.loads(raw)
        replacements = [(frame["id"], "00000000-0000-4000-8000-000000000001"),
                        (frame["payload"]["reply"]["id"], "00000000-0000-4000-8000-000000000002"),
                        (frame["payload"]["reply"]["audioStream"], "00000000-0000-4000-8000-000000000003")]
        for old, new in replacements:
            raw = raw.replace(old.encode(), new.encode())
        return re.sub(rb'"ts":[0-9]+', b'"ts":1', raw)

    def test_single_segment_matches_legacy_frames_byte_for_byte(self):
        # The expected legacy payload bytes and frame shapes also run when no parent executable is supplied.
        environment = self.environment()
        environment.pop("REPLY_RENDERER_TEST_SEGMENT_BYTES")
        result, frames = self.run_speech("One sentence.", environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_complete(frames, [])
        descriptor = frames[0][1]["payload"]["reply"]
        self.assertEqual(set(descriptor), {"id", "host", "target", "audioStream", "priority", "interruption"})
        self.assertEqual(set(frames[0][1]["payload"]), {"text", "final", "reply"})
        for _, frame in frames:
            self.assertEqual(set(frame), {"v", "id", "ts", "target", "source", "type", "payload"})
        for _, frame in frames[1:]:
            self.assertEqual(set(frame["payload"]),
                             {"codec", "sampleRate", "channels", "sequence", "streamId", "final", "bytes", "reply"})
        expected = copy.deepcopy(frames)
        sizes = [24000, 36000, 60000, 10000, 2]
        self.assertEqual(len(frames), 6)
        for index, size in enumerate(sizes):
            payload = expected[index + 1][1]["payload"]
            payload["bytes"] = base64.b64encode(bytes(size)).decode()
            payload["sequence"] = index
            payload["final"] = index == len(sizes) - 1
            payload.pop("segmentEnd", None)
        encoded = [json.dumps(f, sort_keys=True, separators=(",", ":")).encode() + b"\n" for _, f in expected]
        self.assertTrue([self.normalized_wire(raw) for raw in self.raw]
                        == [self.normalized_wire(raw) for raw in encoded])
        baseline = os.environ.get("REPLY_SEGMENTS_BASELINE_HAILD")
        if baseline:
            for counts in ["130000", "60000", None]:
                with self.subTest(mode=counts):
                    if counts:
                        environment["REPLY_RENDERER_TEST_STDOUT_BYTES"] = counts
                    else:
                        environment.pop("REPLY_RENDERER_TEST_STDOUT_BYTES", None)
                    current, _ = self.run_speech("One sentence.", environment)
                    current_wire = [self.normalized_wire(raw) for raw in self.raw]
                    previous, _ = self.run_speech("One sentence.", environment, Path(baseline))
                    self.assertEqual((current.returncode, previous.returncode), (0, 0))
                    self.assertTrue(current_wire == [self.normalized_wire(raw) for raw in self.raw])

    def test_pacing_admission_continues_across_segments(self):
        environment = self.environment("96000")
        environment.pop("HAILD_REPLY_FOREGROUND")
        environment.pop("HAILD_REPLY_PACING")
        result, frames = self.run_speech("First. Second. Third.", environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_complete(frames, [2, 4])
        audio_times = [at for at, f in frames if f["type"] == "audio" and not f["payload"]["final"]]
        # Six seconds share one three-second lead; resetting admission per segment would send all at once.
        self.assertGreaterEqual(audio_times[-1] - audio_times[0], 2.1)
        self.assertEqual(len(self.invocations()), 3)

    def test_sequential_fake_renderer_overhead(self):
        environment = self.environment("4")
        result, frames = self.run_speech("First. Second. Third. Fourth. Fifth.", environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_complete(frames, [0, 1, 2, 3])
        audio_times = [at for at, f in frames if f["type"] == "audio" and not f["payload"]["final"]]
        # Includes retirement/cleanup, next spawn and interpreter startup, PCM EOF and socket acknowledgement.
        gaps = [later - earlier for earlier, later in zip(audio_times, audio_times[1:])]
        print(f"#932 synthetic sequential overhead: median={statistics.median(gaps)*1000:.1f}ms "
              f"max={max(gaps)*1000:.1f}ms n={len(gaps)}", flush=True)

    def test_invalid_configuration_refused_before_text_or_renderer(self):
        for key in ["HAILD_REPLY_SEGMENT_MAX_SENTENCES", "HAILD_REPLY_SEGMENT_MAX_WORDS"]:
            for value in ["0", "301", "bad"]:
                environment = self.environment()
                environment[key] = value
                result, frames = self.run_speech("One sentence.", environment)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(frames, [])
                self.assertEqual(self.invocations(), [])
