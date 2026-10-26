"""#932 P1: reply segment wire shapes and strictness match the Swift decoder."""
import copy
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "scripts"))
import check_schema  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent.parent
REPLY = "00000000-0000-4000-8000-000000000932"


class ReplySegmentsSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.schema = json.loads((ROOT / "fixtures/schema/frame-v1.schema.json").read_text())
        cls.frame = json.loads((ROOT / "fixtures/frames/control-ambient-heard.json").read_text())

    def check(self, payload, kind="control"):
        frame = copy.deepcopy(self.frame)
        frame.update(type=kind, payload=payload)
        return check_schema.validate(frame, self.schema, self.schema)

    def audio(self):
        return dict(codec="pcm16", sampleRate=16000, channels=1, sequence=0, bytes="",
                    streamId=REPLY, final=False, segment_end=True,
                    reply=dict(id=REPLY, host="host", target="target", audioStream=REPLY,
                               priority="normal", interruption="enqueue"))

    def control(self):
        return dict(command="reply_yield", reply=REPLY, segment=1)

    def test_segment_end_and_legacy_audio_are_valid(self):
        audio = self.audio()
        self.assertEqual(self.check(audio, "audio"), [])
        del audio["segment_end"]
        self.assertEqual(self.check(audio, "audio"), [])
        del audio["reply"]
        del audio["streamId"]
        audio["final"] = True
        self.assertEqual(self.check(audio, "audio"), [])

    def test_segment_end_refuses_invalid_values(self):
        for value in [False, None, 0, 1, "true", [], {}]:
            with self.subTest(value=value):
                self.assertTrue(self.check(dict(self.audio(), segment_end=value), "audio"))

    def test_segment_end_requires_nonfinal_reply_stream_and_no_resume(self):
        for field in ["reply", "streamId", "final"]:
            audio = self.audio()
            del audio[field]
            self.assertTrue(self.check(audio, "audio"), field)
        self.assertTrue(self.check(dict(self.audio(), final=True), "audio"))
        for resume in [True, False, None]:
            self.assertTrue(self.check(dict(self.audio(), resume=resume), "audio"))
        audio = self.audio()
        del audio["reply"]["audioStream"]
        self.assertTrue(self.check(audio, "audio"))

    def test_reply_yield_accepts_bounded_integer_and_uuid(self):
        for segment in [1, 10000]:
            self.assertEqual(self.check(dict(self.control(), segment=segment)), [])
        self.assertEqual(self.check(dict(self.control(), reply=REPLY.upper())), [])

    def test_reply_yield_refuses_invalid_counts_and_identifiers(self):
        for segment in [0, -1, 10001, 1.5, "1", None, True, [], {}]:
            with self.subTest(segment=segment):
                self.assertTrue(self.check(dict(self.control(), segment=segment)))
        for reply in [None, False, 1, "not-a-uuid", "", REPLY + "\n", [], {}]:
            with self.subTest(reply=reply):
                self.assertTrue(self.check(dict(self.control(), reply=reply)))

    def test_reply_yield_refuses_missing_fields_and_extras(self):
        for field in ["reply", "segment"]:
            payload = self.control()
            del payload[field]
            self.assertTrue(self.check(payload))
        for key in ["extra", "text", "turn"]:
            self.assertTrue(self.check(dict(self.control(), **{key: None})))


if __name__ == "__main__":
    unittest.main()
