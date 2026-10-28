"""Additional #847 CLI coverage; the existing RightyO CLI expectations stay unchanged."""

import unittest

import test_rightyo_cli as original


class RightyoRequestRefusalCLITests(unittest.TestCase):
    CONNECTION = original.RightyoReplyToCLITests.CONNECTION
    dispatch = original.RightyoReplyToCLITests.dispatch
    run_rightyo = original.RightyoReplyToCLITests.run_rightyo

    def test_capacity_refusal_exits_eight(self):
        result, requests = self.dispatch([{
            "delivered": 0, "request": None, "code": "publicationFailed",
            "error": "dispatch refused [capacityExceeded]: connection holds too many live requests",
        }])
        self.assertEqual(result.returncode, 8, result.stderr)
        self.assertEqual(len(requests), 1)
        self.assertIn("RightyO input refused", result.stderr)
        self.assertEqual(result.stdout, "")
