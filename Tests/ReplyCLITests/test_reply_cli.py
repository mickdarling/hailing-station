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
