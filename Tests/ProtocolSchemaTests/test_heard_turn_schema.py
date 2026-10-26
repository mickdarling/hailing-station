"""#923 PR A: schema parity for optional content-free heard-turn UUIDs."""
import copy
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "scripts"))
import check_schema  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent.parent
TURN = "00000000-0000-4000-8000-000000000923"


class HeardTurnSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.schema = json.loads((ROOT / "fixtures/schema/frame-v1.schema.json").read_text())
        cls.frame = json.loads((ROOT / "fixtures/frames/control-ambient-heard.json").read_text())

    def check(self, payload):
        frame = copy.deepcopy(self.frame)
        frame["payload"] = payload
        return check_schema.validate(frame, self.schema, self.schema)

    def payloads(self):
        return [
            {"command": "ambient_heard", "target": "tmux:a", "text": "synthetic request"},
            {"command": "error", "code": "voice_route_refused", "message": "synthetic refusal"},
        ]

    def test_both_frames_accept_old_shapes_and_uuid_strings(self):
        for payload in self.payloads():
            self.assertEqual(self.check(payload), [])
            for turn in [TURN, TURN.upper(), "abcdefab-cdef-4abc-8def-abcdefabcdef"]:
                with self.subTest(command=payload["command"], turn=turn):
                    self.assertEqual(self.check(dict(payload, turn=turn)), [])

    def test_both_frames_refuse_invalid_turns(self):
        for payload in self.payloads():
            for turn in [None, False, 123, [], {}, "", "not-a-uuid", TURN + "\n", TURN.replace("-", "")]:
                with self.subTest(command=payload["command"], turn=turn):
                    self.assertTrue(self.check(dict(payload, turn=turn)))

    def test_turn_frames_refuse_unknown_payload_fields(self):
        for payload in self.payloads():
            with self.subTest(command=payload["command"]):
                self.assertTrue(self.check(dict(payload, turn=TURN, unknown=True)))
        self.assertTrue(self.check(dict(self.payloads()[0], unknown=True)))

    def test_absent_turn_preserves_legacy_error_extensions(self):
        self.assertEqual(self.check(dict(self.payloads()[1], extension=True)), [])

    def test_turn_requires_voice_route_refused_error_code(self):
        for code in ["paste_refused", "not_allowed", "future_refusal"]:
            with self.subTest(code=code):
                self.assertTrue(self.check(dict(self.payloads()[1], code=code, turn=TURN)))

    def test_turn_is_refused_on_other_control_commands(self):
        count = 0
        for path in (ROOT / "fixtures/frames").glob("*.json"):
            frame = json.loads(path.read_text())
            if frame["type"] != "control" or frame["payload"]["command"] == "ambient_heard":
                continue
            with self.subTest(fixture=path.name):
                frame["payload"]["turn"] = TURN
                self.assertTrue(check_schema.validate(frame, self.schema, self.schema))
                count += 1
        self.assertGreater(count, 20)


if __name__ == "__main__":
    unittest.main()
