"""Tests for scripts/check_schema.py's built-in validator (#28)."""
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import check_schema  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent.parent


class CheckSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.schema = json.loads(next((ROOT / "fixtures" / "schema").glob("frame-v*.schema.json")).read_text())
        cls.good = json.loads((ROOT / "fixtures" / "frames" / "text-final.json").read_text())

    def test_checked_in_fixture_validates(self):
        self.assertEqual(check_schema.validate(self.good, self.schema, self.schema), [])

    def test_wrong_payload_shape_for_type_is_reported(self):
        bad = dict(self.good, payload={"final": True})
        self.assertTrue(any("missing required text" in e for e in check_schema.validate(bad, self.schema, self.schema)))

    def test_out_of_range_audio_is_reported(self):
        audio = json.loads((ROOT / "fixtures" / "frames" / "audio-opus-segment.json").read_text())
        audio["payload"]["channels"] = 3
        self.assertTrue(any("above maximum" in e for e in check_schema.validate(audio, self.schema, self.schema)))

    def test_control_command_specific_fields_are_required(self):
        select = dict(self.good, type="control", payload={"command": "select"})
        self.assertTrue(any("missing required target" in e for e in check_schema.validate(select, self.schema, self.schema)))
        hello = dict(self.good, type="control", payload={"command": "hello", "hello": {"versions": [], "capabilities": [], "deviceName": "x"}})
        self.assertTrue(any("fewer than minItems" in e for e in check_schema.validate(hello, self.schema, self.schema)))

    def test_text_over_the_byte_cap_is_reported(self):
        long = dict(self.good, payload={"text": "t" * 9000, "final": True})
        self.assertTrue(any("longer than maxLength" in e for e in check_schema.validate(long, self.schema, self.schema)))

    def test_number_and_null_types_do_not_crash(self):
        self.assertEqual(check_schema.validate(1.5, {"type": "number"}, {}), [])
        self.assertEqual(check_schema.validate(None, {"type": "null"}, {}), [])
        self.assertEqual(check_schema.validate(2.0, {"type": "integer"}, {}), [])

    def test_unknown_keys_are_tolerated_by_decision(self):
        extra = dict(self.good, extra=1)
        self.assertEqual(check_schema.validate(extra, self.schema, self.schema), [])

    def test_float_typed_integer_is_range_checked(self):
        self.assertTrue(check_schema.validate(0.0, {"type": "integer", "minimum": 1}, {}))


if __name__ == "__main__":
    unittest.main()
