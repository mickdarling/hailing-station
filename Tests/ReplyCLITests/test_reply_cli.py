"""Exercise the real haild CLI against a private local reply socket."""

import base64
import contextlib
import json
import os
import signal
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import uuid
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
HAILD = REPO / ".build" / "debug" / "haild"


class ReplyCLITests(unittest.TestCase):
    def test_usage_documents_request_identity(self):
        for arguments in [[], ["unknown-command"]]:
            with self.subTest(arguments=arguments):
                result = subprocess.run(
                    [str(HAILD), *arguments], cwd=REPO,
                    capture_output=True, text=True, timeout=15, check=False,
                )
                self.assertEqual(result.returncode, 64)
                self.assertIn("--request <opaque-request-UUID>", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_request_identity_is_retained_on_text(self):
        request_id = str(uuid.uuid4()).upper()
        frames = self.submit_frames(["--text", "synthetic reply", "--request", request_id], 1)
        self.assert_reply_identity(frames, request_id)
        self.assertEqual(frames[0]["type"], "text")
        self.assertNotIn("audioStream", frames[0]["payload"]["reply"])

    def test_request_identity_is_shared_by_text_and_static_pcm_segments(self):
        request_id = str(uuid.uuid4()).upper()
        with tempfile.TemporaryDirectory(prefix="hail-reply-pcm-") as scratch:
            pcm = Path(scratch) / "synthetic.raw"
            pcm.write_bytes(b"\x00\x00" * (24 * 1024 + 1))
            frames = self.submit_frames(
                ["--text", "synthetic reply", "--pcm16", str(pcm), "--request", request_id], 3,
            )
        self.assert_reply_identity(frames, request_id)
        self.assertEqual([frame["type"] for frame in frames], ["text", "audio", "audio"])
        self.assert_audio_identity(frames[1:])
        self.assertEqual([frame["payload"]["final"] for frame in frames[1:]], [False, True])

    def test_request_identity_is_shared_by_vbsay_text_pcm_and_final_marker(self):
        request_id = str(uuid.uuid4()).upper()
        environment = os.environ.copy()
        environment["PATH"] = str(Path(__file__).parent / "fixtures") + os.pathsep + environment["PATH"]
        frames = self.submit_frames(["--say", "synthetic reply", "--request", request_id], 3, environment)
        self.assert_reply_identity(frames, request_id)
        self.assertEqual([frame["type"] for frame in frames], ["text", "audio", "audio"])
        self.assert_audio_identity(frames[1:])
        self.assertEqual([frame["payload"]["final"] for frame in frames[1:]], [False, True])

    def test_vbsay_stdout_is_relayed_in_ramped_frames(self):
        # 0.5 s, 0.75 s, then 1.25 s frames, the remainder, and the terminal marker (#268).
        request_id = str(uuid.uuid4()).upper()
        environment = os.environ.copy()
        environment["PATH"] = str(Path(__file__).parent / "fixtures") + os.pathsep + environment["PATH"]
        environment["REPLY_RENDERER_TEST_STDOUT_BYTES"] = "130000"
        frames = self.submit_frames(["--say", "synthetic reply", "--request", request_id], 6, environment)
        self.assert_reply_identity(frames, request_id)
        self.assertEqual([frame["type"] for frame in frames], ["text"] + ["audio"] * 5)
        self.assert_audio_identity(frames[1:])
        sizes = [len(base64.b64decode(frame["payload"]["bytes"])) for frame in frames[1:]]
        self.assertEqual(sizes, [24_000, 36_000, 60_000, 10_000, 2])
        self.assertEqual([frame["payload"]["sequence"] for frame in frames[1:]], [0, 1, 2, 3, 4])
        self.assertEqual([frame["payload"]["final"] for frame in frames[1:]], [False] * 4 + [True])

    def test_speech_longer_than_the_old_frame_budget_plays_in_full(self):
        # 150 s of speech: the old 119-frame job budget stopped at about 146 s (#430). Pacing off keeps it fast;
        # the pacer's timing is covered by ReplyStreamPacerTests.
        environment = os.environ.copy()
        environment["PATH"] = str(Path(__file__).parent / "fixtures") + os.pathsep + environment["PATH"]
        environment["REPLY_RENDERER_TEST_STDOUT_BYTES"] = str(24_000 * 2 * 150)
        environment["HAILD_REPLY_PACING"] = "off"
        frames = self.submit_frames(["--say", "synthetic reply"], 123, environment)
        audio = frames[1:]
        self.assertEqual([frame["payload"]["sequence"] for frame in audio], list(range(122)))
        self.assertEqual(sum(len(base64.b64decode(frame["payload"]["bytes"])) for frame in audio[:-1]), 7_200_000)
        self.assertEqual([frame["payload"]["final"] for frame in audio], [False] * 121 + [True])

    def test_static_pcm_longer_than_the_old_frame_budget_plays_in_full(self):
        with tempfile.TemporaryDirectory(prefix="hail-reply-long-pcm-") as scratch:
            path = Path(scratch) / "long.pcm"
            path.write_bytes(bytes(24_000 * 2 * 150))
            environment = os.environ.copy()
            environment["HAILD_REPLY_PACING"] = "off"
            frames = self.submit_frames(["--text", "synthetic reply", "--pcm16", str(path)], 148, environment)
            audio = frames[1:]
            self.assertEqual(len(audio), 147)
            self.assertEqual(sum(len(base64.b64decode(frame["payload"]["bytes"])) for frame in audio), 7_200_000)
            self.assertTrue(audio[-1]["payload"]["final"])

    def test_paced_reply_returns_at_once_and_streams_the_rest_in_the_background(self):
        # 30 s of speech, paced: the first 20 s go at once, the rest at playback speed (#430).
        environment = self.speech_environment(30)
        with self.reply_server(lambda index: {"delivered": 1}) as (path, frames):
            started = time.monotonic()
            result = self.run_reply(["--say", "synthetic reply"], path, environment)
            returned = time.monotonic() - started
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertLess(returned, 3)
            self.assertIn("streams in the background", result.stdout)
            self.wait_for(lambda: len(frames) == 27, 30)
            last = frames[-1][0] - started
        self.assertGreater(last, 5)
        audio = [frame for _, frame in frames[1:]]
        self.assertEqual([frame["payload"]["sequence"] for frame in audio], list(range(26)))
        self.assertTrue(audio[-1]["payload"]["final"])

    def test_request_reply_stays_unpaced_in_the_foreground(self):
        # A host-minted request expires two minutes after it was made, so its reply is not paced past it.
        environment = self.speech_environment(30)
        with self.reply_server(lambda index: {"delivered": 1}) as (path, frames):
            started = time.monotonic()
            result = self.run_reply(
                ["--say", "synthetic reply", "--request", str(uuid.uuid4()).upper()], path, environment,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertLess(time.monotonic() - started, 3)
            self.assertEqual(len(frames), 27)
            self.assertIn("submitted 27 frames", result.stdout)

    def test_stop_mid_stream_ends_the_background_job_and_its_renderer(self):
        environment = self.speech_environment(150)
        with tempfile.TemporaryDirectory(prefix="hail-reply-stop-") as scratch:
            pidfile = Path(scratch) / "renderer.pid"
            environment["REPLY_RENDERER_TEST_PIDFILE"] = str(pidfile)
            stopped = {"delivered": 0, "error": "reply stopped"}
            with self.reply_server(lambda index: {"delivered": 1} if index < 10 else stopped) as (path, frames):
                result = self.run_reply(["--say", "synthetic reply"], path, environment)
                self.assertEqual(result.returncode, 0, result.stderr)
                job = int(result.stdout.rsplit("pid ", 1)[1].rstrip(")\n"))
                renderer = int(pidfile.read_text())
                self.wait_for(lambda: not self.alive(job) and not self.alive(renderer), 10)
            # Ten accepted, the refused one, then at most the terminal marker: nothing of the other 140 s.
            self.assertLessEqual(len(frames), 12)

    def test_detached_reply_refused_on_its_first_audio_reports_the_failure(self):
        environment = self.speech_environment(30)
        refused = {"delivered": 0, "error": "reply stopped"}
        with self.reply_server(lambda index: {"delivered": 1} if index == 0 else refused) as (path, frames):
            result = self.run_reply(["--say", "synthetic reply"], path, environment)
        self.assertEqual(result.returncode, 1)
        self.assertIn("speech reply publication failed", result.stderr)
        self.assertNotIn("background", result.stdout)

    def test_a_second_detached_reply_queues_its_audio_behind_the_first(self):
        # Codex P1 on #466: the phone plays replies in turn, so the second's audio waits for the first's to finish.
        first_environment = self.speech_environment(30)
        second_environment = self.speech_environment(5)
        with self.reply_server(lambda index: {"delivered": 1}) as (path, frames):
            first = self.run_reply(["--say", "first reply"], path, first_environment)
            self.assertEqual(first.returncode, 0, first.stderr)
            started = time.monotonic()
            second = self.run_reply(["--say", "second reply"], path, second_environment)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertLess(time.monotonic() - started, 3)
            self.assertIn("queued behind another reply", second.stderr)
            # 27 frames for the first (text + 26 audio), 7 for the second (text + 6 audio).
            self.wait_for(lambda: len(frames) == 34, 40)
        streams = {}
        for index, (_, frame) in enumerate(frames):
            if frame["type"] == "audio":
                streams.setdefault(frame["payload"]["streamId"], []).append(index)
        first_audio, second_audio = sorted(streams.values(), key=lambda indexes: indexes[0])
        self.assertEqual((len(first_audio), len(second_audio)), (26, 6))
        self.assertGreater(second_audio[0], first_audio[-1])

    def test_a_detached_reply_resends_a_frame_refused_for_the_shared_rate(self):
        # Codex P2 on #466: that refusal comes before anything is published, so the same frame is sent again.
        environment = self.speech_environment(5)
        environment["HAILD_REPLY_PACING"] = "off"
        limited = {"delivered": 0, "error": "rate limited"}
        with self.reply_server(lambda index: limited if index == 3 else {"delivered": 1}) as (path, frames):
            result = self.run_reply(["--say", "synthetic reply"], path, environment)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.wait_for(lambda: len(frames) == 8, 15)
        self.assertEqual(frames[3][1]["id"], frames[4][1]["id"])
        audio = [frame for _, frame in frames[1:] if frame["id"] != frames[3][1]["id"]] + [frames[4][1]]
        self.assertEqual(sorted(frame["payload"]["sequence"] for frame in audio), list(range(6)))

    def test_high_rate_pcm_that_cannot_be_paced_in_time_is_refused_before_text(self):
        # 13 minutes at 96 kHz is under the 30-minute audio bound but needs ~3,050 short frames (Codex P1 on #466).
        with tempfile.TemporaryDirectory(prefix="hail-reply-high-rate-") as scratch:
            path = Path(scratch) / "high-rate.pcm"
            with open(path, "wb") as handle:
                handle.truncate(96_000 * 2 * 780)  # sparse: only its size is read before the refusal
            with self.reply_server(lambda index: {"delivered": 1}) as (socket_path, frames):
                result = self.run_reply(
                    ["--text", "synthetic reply", "--pcm16", str(path), "--sample-rate", "96000"], socket_path,
                    os.environ.copy(),
                )
            self.assertEqual(result.returncode, 1)
            self.assertIn("can be paced", result.stderr)
            self.assertEqual(frames, [])

    def test_audio_only_pcm_at_the_paced_frame_limit_is_admitted(self):
        # Exactly 3,000 segments and no text frame: within the 3,000-frame paced limit (Codex P2 on #466).
        self.assert_preflight_admits(3_000 * 48 * 1_024, [], {})

    def test_unpaced_pcm_skips_the_paced_frame_limit(self):
        # With pacing off the paced frame limit does not apply; the audio bound and the endpoint's limit still do.
        self.assert_preflight_admits(96_000 * 2 * 780, ["--text", "synthetic reply"], {"HAILD_REPLY_PACING": "off"})

    def assert_preflight_admits(self, size, arguments, overrides):
        with tempfile.TemporaryDirectory(prefix="hail-reply-preflight-") as scratch:
            path = Path(scratch) / "long.pcm"
            with open(path, "wb") as handle:
                handle.truncate(size)
            environment = os.environ.copy()
            environment.update(overrides)
            stopped = {"delivered": 0, "error": "reply stopped"}
            first_audio = 1 if arguments else 0
            respond = lambda index: {"delivered": 1} if index <= first_audio else stopped  # noqa: E731
            with self.reply_server(respond) as (socket_path, frames):
                result = self.run_reply(
                    [*arguments, "--pcm16", str(path), "--sample-rate", "96000"], socket_path, environment,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("can be paced", result.stderr)
            self.assertEqual(frames[first_audio][1]["type"], "audio")

    def test_interrupting_the_caller_before_ready_ends_the_job(self):
        self.assert_caller_loss_before_ready_ends_the_job(signal.SIGINT)

    def test_killing_the_caller_before_ready_publishes_nothing_more(self):
        self.assert_caller_loss_before_ready_ends_the_job(signal.SIGKILL)

    def assert_caller_loss_before_ready_ends_the_job(self, signum):
        # The text frame is held unanswered, so the job is mid-handshake when its caller goes.
        environment = self.speech_environment(30)
        release = threading.Event()

        def respond(index):
            if index == 0:
                release.wait(10)
            return {"delivered": 1}

        with self.reply_server(respond) as (path, frames):
            caller = subprocess.Popen(
                [str(HAILD), "reply", "tmux:test", "--host", "mac-test", "--say", "synthetic reply",
                 "--socket", path],
                cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment, start_new_session=True,
            )
            try:
                self.wait_for(lambda: len(frames) == 1, 10)
                job = self.child_of(caller.pid)
                caller.send_signal(signum)
                caller.wait(timeout=10)
                release.set()
                self.wait_for(lambda: not self.alive(job), 10)
            finally:
                release.set()
                if caller.poll() is None:
                    caller.kill()
                caller.communicate(timeout=10)
            time.sleep(0.3)
            self.assertEqual(len(frames), 1, [frame["type"] for _, frame in frames])

    def test_interrupting_the_caller_cancels_a_stalled_renderer_and_cleans_up(self):
        # Codex P2 on #466: the renderer writes nothing, so only cancellation (not a broken pipe) can end it.
        environment = self.speech_environment(30)
        environment["REPLY_RENDERER_TEST_STALL"] = "1"
        with tempfile.TemporaryDirectory(prefix="hail-reply-stall-") as scratch:
            root = Path(scratch) / "output"
            root.mkdir(mode=0o700)
            pidfile = Path(scratch) / "renderer.pid"
            environment["REPLY_RENDERER_TEST_PIDFILE"] = str(pidfile)
            with self.reply_server(lambda index: {"delivered": 1}) as (path, frames):
                caller = subprocess.Popen(
                    [str(HAILD), "reply", "tmux:test", "--host", "mac-test", "--say", "synthetic reply",
                     "--renderer-output-root", str(root), "--socket", path],
                    cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment,
                    start_new_session=True,
                )
                try:
                    self.wait_for(lambda: pidfile.exists() and pidfile.read_text(), 10)
                    job, renderer = self.child_of(caller.pid), int(pidfile.read_text())
                    caller.send_signal(signal.SIGINT)
                    caller.wait(timeout=10)
                    self.wait_for(lambda: not self.alive(job) and not self.alive(renderer), 10)
                finally:
                    if caller.poll() is None:
                        caller.kill()
                    caller.communicate(timeout=10)
            self.assertEqual(len(frames), 1)
            # A cancelled renderer defers its owned leaf, as every abnormal outcome does; nothing else is left.
            self.assertLessEqual(len(list(root.iterdir())), 1)

    @staticmethod
    def child_of(parent):
        listing = subprocess.run(["ps", "-A", "-o", "pid=,ppid="], capture_output=True, text=True).stdout
        children = [int(pid) for pid, ppid in (line.split() for line in listing.splitlines()) if int(ppid) == parent]
        if len(children) != 1:
            raise AssertionError(f"expected one detached job, found {children}")
        return children[0]

    def speech_environment(self, seconds):
        environment = os.environ.copy()
        environment["PATH"] = str(Path(__file__).parent / "fixtures") + os.pathsep + environment["PATH"]
        environment["REPLY_RENDERER_TEST_STDOUT_BYTES"] = str(24_000 * 2 * seconds)
        environment.pop("HAILD_REPLY_PACING", None)
        return environment

    def run_reply(self, arguments, path, environment):
        return subprocess.run(
            [str(HAILD), "reply", "tmux:test", "--host", "mac-test", *arguments, "--socket", path],
            cwd=REPO, capture_output=True, text=True, timeout=15, check=False, env=environment,
            start_new_session=True,
        )

    @staticmethod
    def alive(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        try:
            # A reaped-by-launchd zombie still answers kill(0); ps shows its state.
            state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout
        except OSError:
            return True
        return bool(state.strip()) and not state.strip().startswith("Z")

    def wait_for(self, condition, seconds):
        deadline = time.monotonic() + seconds
        while not condition():
            self.assertLess(time.monotonic(), deadline, "condition not met in time")
            time.sleep(0.05)

    @contextlib.contextmanager
    def reply_server(self, respond):
        """A private reply socket answering frame N with respond(N); yields (path, [(arrival, frame)])."""
        with tempfile.TemporaryDirectory(prefix="hail-reply-serve-") as scratch:
            path = os.path.join(scratch, "reply.sock")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(path)
                os.chmod(path, 0o600)
                server.listen(16)
                server.settimeout(0.1)
                frames, errors = [], []
                finished = threading.Event()

                def answer():
                    try:
                        while not finished.is_set():
                            try:
                                client, _ = server.accept()
                            except socket.timeout:
                                continue
                            with client:
                                client.settimeout(10)
                                request = b""
                                while not request.endswith(b"\n"):
                                    chunk = client.recv(65536)
                                    if not chunk:
                                        raise AssertionError("CLI closed before sending a frame")
                                    request += chunk
                                index = len(frames)
                                frames.append((time.monotonic(), json.loads(request)))
                                client.sendall(json.dumps(respond(index)).encode() + b"\n")
                    except Exception as error:
                        errors.append(error)

                worker = threading.Thread(target=answer, daemon=True)
                worker.start()
                try:
                    yield path, frames
                finally:
                    finished.set()
                    worker.join(timeout=5)
                self.assertFalse(errors, errors)

    def test_stop_mid_reply_cuts_a_long_reply_off(self):
        # The host refuses a stopped reply's next frame; the CLI must stop there, not keep sending 150 s of audio.
        environment = os.environ.copy()
        environment["PATH"] = str(Path(__file__).parent / "fixtures") + os.pathsep + environment["PATH"]
        environment["REPLY_RENDERER_TEST_STDOUT_BYTES"] = str(24_000 * 2 * 150)
        environment["HAILD_REPLY_PACING"] = "off"
        stopped = {"delivered": 0, "error": "reply stopped"}
        result, requests = self.submit_responses(
            [{"delivered": 1}] * 10 + [stopped] * 5, ["--say", "synthetic"], environment,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("speech reply publication failed", result.stderr)
        frames = [json.loads(request) for request in requests]
        # Ten accepted, the refused one, then at most the terminal marker for the phone's player.
        self.assertLessEqual(len(frames), 12)
        if len(frames) == 12:
            self.assertTrue(frames[-1]["payload"]["final"])

    def test_owned_renderer_inherits_job_group_and_uses_explicit_private_root(self):
        request_id = str(uuid.uuid4()).upper()
        with tempfile.TemporaryDirectory(prefix="hail-renderer-owned-") as scratch:
            root = Path(scratch) / "output"
            root.mkdir(mode=0o700)
            record = Path(scratch) / "record.json"
            environment = os.environ.copy()
            environment["PATH"] = str(Path(__file__).parent / "fixtures") + os.pathsep + environment["PATH"]
            environment["REPLY_RENDERER_TEST_ROOT"] = str(root)
            environment["REPLY_RENDERER_TEST_RECORD"] = str(record)
            # This caller-created job group is inherited by haild and its exact renderer child.
            frames = self.submit_frames(
                ["--say", "synthetic reply", "--request", request_id, "--renderer-output-root", str(root)],
                3, environment,
            )
            proof = json.loads(record.read_text())
            self.assertTrue(all(proof.values()), proof)
            self.assertEqual(list(root.iterdir()), [])
            self.assertTrue(root.is_dir())
        self.assert_reply_identity(frames, request_id)
        self.assert_audio_identity(frames[1:])
        self.assertEqual([frame["payload"]["final"] for frame in frames[1:]], [False, True])

    def test_renderer_root_is_validated_before_text_publication(self):
        with tempfile.TemporaryDirectory(prefix="hail-renderer-invalid-") as scratch:
            root = Path(scratch) / "root"
            root.mkdir(mode=0o755)
            alias = Path(scratch) / "alias"
            alias.symlink_to(root, target_is_directory=True)
            for path in [root, alias, Path(scratch) / "missing"]:
                with self.subTest(path=path.name):
                    result = subprocess.run(
                        [str(HAILD), "reply", "tmux:test", "--say", "synthetic reply",
                         "--renderer-output-root", str(path), "--socket", str(Path(scratch) / "absent.sock")],
                        cwd=REPO, capture_output=True, text=True, timeout=15, check=False,
                    )
                    self.assertEqual(result.returncode, 1)
                    self.assertIn("invalid private renderer output root", result.stderr)
                    self.assertNotIn("absent.sock", result.stderr)
                    self.assertEqual(result.stdout, "")
            self.assertEqual(list(root.iterdir()), [])

    def test_nonzero_renderer_is_visible_failure_and_defers_owned_leaf_cleanup(self):
        with tempfile.TemporaryDirectory(prefix="hail-renderer-nonzero-") as scratch:
            root = Path(scratch) / "output"
            root.mkdir(mode=0o700)
            environment = os.environ.copy()
            environment["PATH"] = str(Path(__file__).parent / "fixtures") + os.pathsep + environment["PATH"]
            environment["REPLY_RENDERER_TEST_NONZERO"] = "1"
            result, requests = self.submit_responses(
                [{"delivered": 1}], ["--say", "synthetic", "--renderer-output-root", str(root)], environment,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("speech renderer exited unsuccessfully", result.stderr)
            self.assertEqual(len(requests), 1)
            self.assertEqual(result.stdout, "")
            self.assertIn("owned output cleanup deferred", result.stderr)
            self.assertEqual(len(list(root.iterdir())), 1)

    def test_accepted_text_then_refused_audio_preserves_fixed_primary_publication_failure(self):
        self.assert_audio_publication_failure(
            {"delivered": 0, "code": "noRecipient", "error": "synthetic-private-endpoint-detail"},
        )

    def test_accepted_text_then_lost_audio_ack_preserves_primary_failure_without_whole_command_retry(self):
        self.assert_audio_publication_failure(None)

    def assert_audio_publication_failure(self, audio_response):
        environment = os.environ.copy()
        environment["PATH"] = str(Path(__file__).parent / "fixtures") + os.pathsep + environment["PATH"]
        with tempfile.TemporaryDirectory(prefix="hail-renderer-publication-") as scratch:
            root = Path(scratch) / "output"
            root.mkdir(mode=0o700)
            result, requests = self.submit_responses(
                [{"delivered": 1}, audio_response],
                ["--say", "synthetic", "--renderer-output-root", str(root)], environment,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("speech reply publication failed", result.stderr)
            self.assertIn("owned output cleanup deferred", result.stderr)
            self.assertNotIn("synthetic-private-endpoint-detail", result.stderr)
            self.assertNotIn(str(root), result.stderr)
            self.assertEqual(result.stdout, "")
            self.assertEqual(len(requests), 2)
            frames = [json.loads(request) for request in requests]
            self.assertEqual([frame["type"] for frame in frames], ["text", "audio"])
            self.assertEqual(frames[0]["payload"]["reply"], frames[1]["payload"]["reply"])
            self.assertEqual(frames[1]["payload"]["sequence"], 0)
            self.assertFalse(frames[1]["payload"]["final"])
            self.assertEqual(len(list(root.iterdir())), 1)

    def test_legacy_text_does_not_invent_request_identity(self):
        frames = self.submit_frames(["--text", "synthetic reply"], 1)
        self.assertNotIn("request", frames[0]["payload"]["reply"])

    def test_pending_retries_identical_frame_until_committed(self):
        pending = {"delivered": 0, "code": "requestPending", "error": "request pending"}
        result, requests = self.submit_responses([pending, pending, {"delivered": 1}])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(requests), 3)
        self.assertTrue(all(request == requests[0] for request in requests))
        self.assertIn("submitted 1 frame; 1 terminal delivery", result.stdout)

    def test_pending_then_failed_handoff_is_not_retried_again(self):
        result, requests = self.submit_responses([
            {"delivered": 0, "code": "requestPending", "error": "request pending"},
            {"delivered": 0, "code": "noRecipient", "error": "no recipient"},
        ])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(requests), 2)
        self.assertEqual(requests[0], requests[1])
        self.assertIn("no recipient", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_perpetual_pending_has_bounded_attempts(self):
        pending = {"delivered": 0, "code": "requestPending", "error": "request pending"}
        result, requests = self.submit_responses([pending] * 8)
        self.assertEqual(result.returncode, 1)
        # The monotonic deadline may expire before the attempt cap under scheduling contention.
        # A causal injected-clock test separately proves all eight attempts when time permits.
        self.assertGreaterEqual(len(requests), 1)
        self.assertLessEqual(len(requests), 8)
        self.assertTrue(all(request == requests[0] for request in requests))
        self.assertIn("retry budget", result.stderr)

    def test_other_refusals_counts_and_untyped_pending_do_not_retry(self):
        responses = [
            {"delivered": 0}, {"delivered": 2}, {"delivered": -1},
            {"delivered": 0, "error": "rate limited"},
            {"delivered": 0, "error": "request pending"},
            {"delivered": 0, "code": "publicationFailed", "error": "publication failed"},
            {"delivered": 0, "code": "notUniqueRecipient", "error": "ambiguous recipient"},
            {"delivered": 1, "code": "requestPending"},
            {"delivered": 1, "code": "noRecipient"},
            {"delivered": 0, "code": "unknownCode", "error": "unknown refusal"},
        ]
        for response in responses:
            with self.subTest(response=response):
                result, requests = self.submit_responses([response])
                self.assertEqual(result.returncode, 1)
                self.assertEqual(len(requests), 1)
                self.assertEqual(result.stdout, "")

    def test_ambiguous_socket_completion_does_not_retry(self):
        result, requests = self.submit_responses([None])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(requests), 1)
        self.assertEqual(result.stdout, "")

    def test_zero_recipient_refuses_before_speech_generation(self):
        # An empty PATH ensures any accidental attempt to start vbsay fails visibly. The expected
        # refusal must be recipient admission, before any audio frames or renderer invocation.
        environment = os.environ.copy()
        environment["PATH"] = ""
        result, requests = self.submit_responses(
            [{"delivered": 0}], arguments=["--say", "synthetic diagnostic"], environment=environment,
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(requests), 1)
        self.assertIn("exactly one recipient", result.stderr)
        self.assertNotIn("vbsay", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_pending_audio_reuses_descriptor_and_sequence(self):
        environment = os.environ.copy()
        environment["PATH"] = str(Path(__file__).parent / "fixtures") + os.pathsep + environment["PATH"]
        pending = {"delivered": 0, "code": "requestPending", "error": "request pending"}
        result, requests = self.submit_responses(
            [pending, {"delivered": 1}, pending, {"delivered": 1}, {"delivered": 1}],
            arguments=["--say", "synthetic diagnostic"], environment=environment,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(requests), 5)
        self.assertEqual(requests[0], requests[1])
        self.assertEqual(requests[2], requests[3])
        frames = [json.loads(request) for request in requests]
        descriptor = frames[0]["payload"]["reply"]
        self.assertTrue(all(frame["payload"]["reply"] == descriptor for frame in frames))
        self.assertEqual([frame["payload"]["sequence"] for frame in frames[2:]], [0, 0, 1])
        self.assertIn("submitted 3 frames; 3 terminal deliveries", result.stdout)

    def test_missing_speech_renderer_after_text_is_visible_failure(self):
        environment = os.environ.copy()
        environment["PATH"] = ""
        result, requests = self.submit_responses(
            [{"delivered": 1}], arguments=["--say", "synthetic diagnostic"], environment=environment,
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(requests), 1)
        self.assertIn("speech renderer unavailable", result.stderr)
        self.assertEqual(result.stdout, "")

    def submit_responses(self, responses, arguments=None, environment=None):
        arguments = arguments or ["--text", "synthetic reply"]
        request_id = str(uuid.uuid4()).upper()
        with tempfile.TemporaryDirectory(prefix="hail-reply-outcome-") as scratch:
            path = os.path.join(scratch, "reply.sock")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(path)
                os.chmod(path, 0o600)
                server.listen(16)
                server.settimeout(0.1)
                requests, errors = [], []
                finished = threading.Event()

                def answer():
                    try:
                        while not finished.is_set():
                            try:
                                client, _ = server.accept()
                            except socket.timeout:
                                continue
                            with client:
                                client.settimeout(10)
                                request = b""
                                while not request.endswith(b"\n"):
                                    chunk = client.recv(8192)
                                    if not chunk:
                                        raise AssertionError("CLI closed before sending a frame")
                                    request += chunk
                                requests.append(request)
                                index = len(requests) - 1
                                response = responses[index] if index < len(responses) else {
                                    "delivered": 0, "error": "unexpected retry",
                                }
                                if response is not None:
                                    client.sendall(json.dumps(response).encode() + b"\n")
                    except Exception as error:
                        errors.append(error)

                worker = threading.Thread(target=answer, daemon=True)
                worker.start()
                try:
                    result = subprocess.run(
                        [str(HAILD), "reply", "tmux:test", "--host", "mac-test", *arguments,
                         "--request", request_id, "--socket", path],
                        cwd=REPO, capture_output=True, text=True, timeout=15, check=False, env=environment,
                        start_new_session=True,
                    )
                finally:
                    finished.set()
                    worker.join(timeout=12)
                self.assertFalse(worker.is_alive())
                self.assertFalse(errors, errors)
                return result, requests

    def test_invalid_request_identity_is_refused_before_connecting(self):
        for request_id in ["not-a-uuid", "device-name", ""]:
            with self.subTest(request_id=request_id):
                result = subprocess.run(
                    [str(HAILD), "reply", "tmux:test", "--host", "mac-test", "--text", "synthetic reply",
                     "--request", request_id],
                    cwd=REPO, capture_output=True, text=True, timeout=15, check=False,
                )
                self.assertEqual(result.returncode, 1)
                self.assertIn("request", result.stderr.lower())
                self.assertNotIn("socket", result.stderr.lower())

    def test_explicit_empty_or_invalid_host_is_refused_before_connecting(self):
        for host in ["", "bad host", "a..b"]:
            with self.subTest(host=host):
                result = subprocess.run(
                    [str(HAILD), "reply", "tmux:test", "--host", host, "--text", "synthetic reply",
                     "--socket", "/nonexistent/hail-test.sock"],
                    cwd=REPO, capture_output=True, text=True, timeout=15, check=False,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(result.stderr.startswith("usage:"), result.stderr)

    def assert_reply_identity(self, frames, request_id):
        descriptor = frames[0]["payload"]["reply"]
        self.assertEqual(descriptor["request"], request_id)
        self.assertEqual(descriptor["host"], "mac-test")
        self.assertEqual(descriptor["target"], "tmux:test")
        for frame in frames:
            self.assertEqual(frame["payload"]["reply"], descriptor)
            self.assertEqual(frame["source"], "mac-test")
            self.assertEqual(frame["target"], "tmux:test")

    def assert_audio_identity(self, frames):
        for sequence, frame in enumerate(frames):
            payload = frame["payload"]
            self.assertEqual(payload["sequence"], sequence)
            self.assertEqual(payload["streamId"], payload["reply"]["audioStream"])

    def submit_frames(self, arguments, count, environment=None):
        with tempfile.TemporaryDirectory(prefix="hail-reply-cli-") as scratch:
            path = os.path.join(scratch, "reply.sock")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(path)
                os.chmod(path, 0o600)
                server.listen(count)
                frames = []
                errors = []

                def answer():
                    try:
                        server.settimeout(10)
                        for _ in range(count):
                            with server.accept()[0] as client:
                                client.settimeout(10)
                                request = b""
                                while not request.endswith(b"\n"):
                                    chunk = client.recv(8192)
                                    if not chunk:
                                        raise AssertionError("CLI closed before sending a frame")
                                    request += chunk
                                frames.append(json.loads(request))
                                client.sendall(b'{"delivered":1}\n')
                    except Exception as error:
                        errors.append(error)

                worker = threading.Thread(target=answer, daemon=True)
                worker.start()
                result = subprocess.run(
                    [str(HAILD), "reply", "tmux:test", "--host", "mac-test", *arguments, "--socket", path],
                    cwd=REPO, capture_output=True, text=True, timeout=15, check=False, env=environment,
                    start_new_session=True,
                )
                worker.join(timeout=12)
                self.assertFalse(worker.is_alive())
                self.assertFalse(errors, errors)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(frames), count)
                return frames

    def test_refusal_codes_are_printed_without_enum_wrappers(self):
        reasons = {
            "sourceHostMismatch": "source host mismatch",
            "listenerNotReady": "listener not ready",
            "invalidReplyPayload": "invalid reply payload",
            "replyTargetMissing": "reply target missing",
            "auditFailure": "audit failure",
            "decodeFailure": "frame decode failure",
            "internal": "internal failure",
        }
        for code, reason in reasons.items():
            with self.subTest(code=code), tempfile.TemporaryDirectory(prefix="hail-reply-cli-") as scratch:
                path = os.path.join(scratch, "reply.sock")
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                    server.bind(path)
                    os.chmod(path, 0o600)
                    server.listen(1)
                    errors = []

                    def answer():
                        try:
                            server.settimeout(10)
                            with server.accept()[0] as client:
                                request = b""
                                while not request.endswith(b"\n"):
                                    chunk = client.recv(8192)
                                    if not chunk:
                                        raise AssertionError("CLI closed before sending a frame")
                                    request += chunk
                                self.assertEqual(json.loads(request)["target"], "tmux:test")
                                response = {"delivered": 0, "error": f"reply refused [{code}]: {reason}"}
                                client.sendall(json.dumps(response).encode() + b"\n")
                        except Exception as error:  # Hand thread failures back to the test.
                            errors.append(error)

                    worker = threading.Thread(target=answer, daemon=True)
                    worker.start()
                    result = subprocess.run(
                        [str(HAILD), "reply", "tmux:test", "--host", "mac-main",
                         "--text", "ready", "--socket", path],
                        cwd=REPO, capture_output=True, text=True, timeout=15, check=False,
                    )
                    worker.join(timeout=2)
                    self.assertFalse(worker.is_alive())
                    self.assertFalse(errors, errors)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertEqual(result.stderr, f"haild: reply refused [{code}]: {reason}\n")


if __name__ == "__main__":
    unittest.main()
