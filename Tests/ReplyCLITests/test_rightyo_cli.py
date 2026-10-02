"""Exercise only RightyO JSONL dry run: no target discovery, capture or provider submission."""

import json
import os
import select
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HAILD = REPO / ".build" / "debug" / "haild"
FIXTURE = REPO / "fixtures" / "rightyo" / "tool-events.jsonl"
ENROLLED = REPO / "fixtures" / "rightyo" / "enrolled-speakers.jsonl"


class RightyoCLITests(unittest.TestCase):
    def invoke(self, content, session="tool-demo"):
        return subprocess.run(
            [str(HAILD), "rightyo", "--session", session, "--dry-run"],
            input=content, cwd=REPO, capture_output=True, text=True, timeout=15, check=False,
        )

    def test_shared_fixture_validates_one_request_without_transcript_logging(self):
        result = self.invoke(FIXTURE.read_text())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("request validated"), 1)
        self.assertNotIn("scheduled for Friday", result.stdout + result.stderr)
        self.assertNotIn("check our discussion", result.stdout + result.stderr)

    def test_attended_receipt_arrives_before_more_audio_or_stdin_eof(self):
        lines = FIXTURE.read_bytes().splitlines(keepends=True)
        prefix = b"".join(lines[:-1])
        self.assertLess(len(prefix), 4096)
        process = subprocess.Popen(
            [str(HAILD), "rightyo", "--session", "tool-demo", "--dry-run"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0,
        )
        try:
            process.stdin.write(prefix)
            process.stdin.flush()
            ready, _, _ = select.select([process.stdout], [], [], 3)
            self.assertTrue(ready, "request receipt waited for more input/EOF")
            receipt = os.read(process.stdout.fileno(), 1024)
            self.assertIn(b"request validated", receipt)
            process.stdin.write(lines[-1])
            process.stdin.close()
            self.assertEqual(process.wait(timeout=5), 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            for stream in [process.stdin, process.stdout, process.stderr]:
                if stream is not None:
                    stream.close()

    def test_incomplete_empty_malformed_and_foreign_session_refuse(self):
        for content in ["", "{not-json: invented-private-sentinel}\n", FIXTURE.read_text().splitlines()[0]]:
            with self.subTest(content=content[:20]):
                result = self.invoke(content)
                self.assertEqual(result.returncode, 8)
                self.assertNotIn("invented-private-sentinel", result.stdout + result.stderr)
        self.assertEqual(self.invoke(FIXTURE.read_text(), "wrong-session").returncode, 8)

    def test_producer_error_returns_failure_without_retracting_prior_receipt(self):
        events = [json.loads(line) for line in FIXTURE.read_text().splitlines()]
        events[-1]["phase"] = "error"
        result = self.invoke("\n".join(json.dumps(event) for event in events))
        self.assertEqual(result.returncode, 8)
        self.assertEqual(result.stdout.count("request validated"), 1)

    def test_oversized_record_is_refused(self):
        self.assertEqual(self.invoke(" " * 1_200_001).returncode, 8)

    def test_transcription_only_disabled_stream_is_accepted_without_request(self):
        events = [json.loads(line) for line in FIXTURE.read_text().splitlines()]
        events[0]["capabilities"]["activation"] = "disabled"
        selected = [events[0], events[1], events[-1]]
        result = self.invoke("\n".join(json.dumps(event) for event in selected))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_enrolled_speakers_past_fifteen_minutes_validate_one_request(self):
        result = self.invoke(ENROLLED.read_text(), "enrolled-demo")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("request validated"), 1)
        self.assertNotIn("check our discussion", result.stdout + result.stderr)
        events = [json.loads(line) for line in ENROLLED.read_text().splitlines()]
        events[0]["capabilities"]["speakers"] = "verified"
        self.assertEqual(self.invoke("\n".join(json.dumps(event) for event in events), "enrolled-demo").returncode, 8)
