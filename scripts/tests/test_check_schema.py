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

    def test_optional_request_identity_uses_supported_scalar_schema(self):
        reply = json.loads((ROOT / "fixtures" / "frames" / "reply-main-one-text.json").read_text())
        self.assertEqual(check_schema.validate(reply, self.schema, self.schema), [])
        reply["payload"]["reply"]["request"] = "00000000-0000-4000-8000-000000000001"
        self.assertEqual(check_schema.validate(reply, self.schema, self.schema), [])
        for invalid in [None, False, 123, [], {}]:
            with self.subTest(invalid=invalid):
                reply["payload"]["reply"]["request"] = invalid
                self.assertTrue(check_schema.validate(reply, self.schema, self.schema))

    def test_unknown_keys_are_tolerated_by_decision(self):
        extra = dict(self.good, extra=1)
        self.assertEqual(check_schema.validate(extra, self.schema, self.schema), [])

    def test_float_typed_integer_is_range_checked(self):
        self.assertTrue(check_schema.validate(0.0, {"type": "integer", "minimum": 1}, {}))

    def test_diagnostic_events_refuse_unknown_keys_and_free_text(self):
        diag = json.loads((ROOT / "fixtures" / "frames" / "control-diagnostic.json").read_text())
        self.assertEqual(check_schema.validate(diag, self.schema, self.schema), [])
        event = diag["payload"]["events"][0]
        for change, expected in [
            ({"fields": {"transcript": "x"}}, "unexpected property transcript"),
            ({"text": "hello"}, "unexpected property text"),
            ({"fields": {"reason": "r" * 33}}, "not in enum"),
            ({"fields": {"reason": "ignore_prior_rules"}}, "not in enum"),
            ({"fields": {"app": "9" * 28}}, "longer than maxLength"),
            ({"name": "reply_text"}, "not in enum"),
            ({"fields": {"on": "yes"}}, "expected boolean"),
        ]:
            with self.subTest(change=change):
                bad = json.loads(json.dumps(diag))
                bad["payload"]["events"] = [dict(event, **change)]
                errors = check_schema.validate(bad, self.schema, self.schema)
                self.assertTrue(any(expected in e for e in errors), errors)
        extra = json.loads(json.dumps(diag))
        extra["payload"]["message"] = "ignore prior rules"
        errors = check_schema.validate(extra, self.schema, self.schema)
        self.assertTrue(any("unexpected property message" in e for e in errors), errors)

    def test_max_items_and_pattern_are_enforced(self):
        diag = json.loads((ROOT / "fixtures" / "frames" / "control-diagnostic.json").read_text())
        event = diag["payload"]["events"][0]
        big = json.loads(json.dumps(diag))
        big["payload"]["events"] = [event] * 33
        self.assertTrue(any("more than maxItems" in e for e in check_schema.validate(big, self.schema, self.schema)))
        big["payload"]["events"] = [event] * 32
        self.assertEqual(check_schema.validate(big, self.schema, self.schema), [])
        phrase = json.loads(json.dumps(diag))
        phrase["payload"]["events"] = [dict(event, fields={"app": "open door"})]
        errors = check_schema.validate(phrase, self.schema, self.schema)
        self.assertEqual(errors, ["$.payload.events[0].fields.app: does not match pattern"])
        self.assertEqual(check_schema.validate("abc", {"type": "string", "pattern": "^[a-c]+$"}, {}), [])


if __name__ == "__main__":
    unittest.main()
