"""#1120 proposed held controls: schema bounds and strict fields match the Swift wire types."""
import copy
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "scripts"))
import check_schema  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent.parent
HELD = "00000000-0000-4000-8000-000000001120"


class HeldRequestsSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.schema = json.loads((ROOT / "fixtures/schema/frame-v1.schema.json").read_text())
        cls.frame = json.loads((ROOT / "fixtures/frames/control-ambient-heard.json").read_text())

    def check(self, payload):
        frame = copy.deepcopy(self.frame)
        frame["payload"] = payload
        return check_schema.validate(frame, self.schema, self.schema)

    def notice(self):
        return dict(command="request_held", held=HELD, reasons=["rule_match", "guard_timeout"],
                    rules=["sudo", "custom"], expires_in=60)

    def payloads(self):
        return [self.notice(), dict(command="held_decision", held=HELD, action="send"),
                dict(command="held_resolution", held=HELD, outcome="refused", reason="policy_changed")]

    def test_all_payloads_and_optional_heard_turn(self):
        for payload in self.payloads() + [dict(self.notice(), turn=HELD)]:
            self.assertEqual(self.check(payload), [])
        for action in ["send", "discard"]:
            self.assertEqual(self.check(dict(self.payloads()[1], action=action)), [])
        for outcome in ["sent", "discarded", "expired", "stale"]:
            self.assertEqual(self.check(dict(command="held_resolution", held=HELD, outcome=outcome)), [])

    def test_missing_required_fields_and_extra_fields(self):
        for payload in self.payloads():
            for key in payload:
                missing = dict(payload)
                del missing[key]
                self.assertTrue(self.check(missing), key)
            for key in ["text", "pattern", "target", "binding", "unknown"]:
                self.assertTrue(self.check(dict(payload, **{key: "synthetic"})), key)
        for payload in self.payloads()[1:]:
            self.assertTrue(self.check(dict(payload, turn=HELD)))

    def test_invalid_uuids_and_null_turn(self):
        for raw in [None, False, 1, [], {}, "", "not-a-uuid", HELD + "\n", HELD.replace("-", "")]:
            for payload in self.payloads():
                self.assertTrue(self.check(dict(payload, held=raw)), repr(raw))
            self.assertTrue(self.check(dict(self.notice(), turn=raw)), repr(raw))

    def test_closed_enums_and_lists(self):
        for reason in ["unknown", "RULE_MATCH", "rule_match "]:
            self.assertTrue(self.check(dict(self.notice(), reasons=[reason])))
        for reasons in [[], ["rule_match"] * 5, "rule_match", None, [1]]:
            self.assertTrue(self.check(dict(self.notice(), reasons=reasons)))
        for action in ["unknown", "SEND", None, False]:
            self.assertTrue(self.check(dict(self.payloads()[1], action=action)))
        for outcome in ["unknown", "SENT", None, False]:
            self.assertTrue(self.check(dict(self.payloads()[2], outcome=outcome)))
        # The lightweight validator does not implement uniqueItems; retain that constraint in the full schema.
        control_rules = self.schema["$defs"]["control"]["allOf"]
        notice_rule = next(rule for rule in control_rules if
                           rule.get("then", {}).get("properties", {}).get("reasons", {}).get("uniqueItems"))
        self.assertTrue(notice_rule["then"]["properties"]["reasons"]["uniqueItems"])

    def test_rule_tokens_and_count_bounds(self):
        for rules in [["custom"] * 17, ["a" * 33], ["custom name"], ["sudo.*"], ["SUDO"],
                      ["rm -rf"], [""], [1], "sudo", None]:
            self.assertTrue(self.check(dict(self.notice(), rules=rules)), repr(rules))
        for rules in [[], ["custom"] * 16]:
            self.assertEqual(self.check(dict(self.notice(), rules=rules)), [])

    def test_expiry_bounds_and_whole_seconds(self):
        for expiry in [-1, 0, 3601, 1.5, "60", None, True]:
            self.assertTrue(self.check(dict(self.notice(), expires_in=expiry)), repr(expiry))
        for expiry in [1, 3600]:
            self.assertEqual(self.check(dict(self.notice(), expires_in=expiry)), [])

    def test_refusal_requires_bounded_token_only_for_refused(self):
        refused = self.payloads()[2]
        for reason in [None, False, "", "a" * 33, "not prose", "pattern=.*", "UPPER", "é", "line\n"]:
            self.assertTrue(self.check(dict(refused, reason=reason)), repr(reason))
        for outcome in ["sent", "discarded", "expired", "stale"]:
            self.assertTrue(self.check(dict(refused, outcome=outcome)))
        self.assertEqual(self.check(dict(refused, reason="a" * 32)), [])


if __name__ == "__main__":
    unittest.main()
