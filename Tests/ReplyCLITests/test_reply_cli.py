"""Exercise the real haild CLI against a private local reply socket."""

import json
import os
import socket
import subprocess
import tempfile
import threading
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
        self.assertIn("vbsay exited with status", result.stderr)
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
