"""Offline synthetic tests for the #737 timing summary."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "reply-timing-summary.py"
spec = importlib.util.spec_from_file_location("reply_timing_summary", SCRIPT)
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)


def record(first, lead="100", outcome="played"):
    return (f"reply audio: frames=2 audio_ms=1250 first_audio_ms={first} min_lead_ms={lead} "
            f"ack_max_ms=12 ack_p95_ms=10 resends=0 wall_ms=2000 outcome={outcome}")


class ReplyTimingSummaryTests(unittest.TestCase):
    def test_played_percentiles_and_failure_exclusion(self):
        result = summary.summarize([record(n) for n in range(1, 21)] + [record(999, outcome="failed")])
        self.assertEqual(result["matched"], 21)
        self.assertEqual(result["outcomes"]["failed"], 1)
        self.assertEqual(result["played_metrics"]["first_audio_ms"],
                         {"n": 20, "min": 1, "median": 10.5, "p95": 19, "max": 20})

    def test_missing_values_negative_lead_and_empty(self):
        result = summary.summarize([record("none", "none"), record(12, -250)])
        self.assertEqual(result["played_metrics"]["first_audio_ms"]["n"], 1)
        self.assertEqual(result["played_metrics"]["min_lead_ms"]["min"], -250)
        self.assertEqual(summary.summarize([])["played_metrics"]["first_audio_ms"]["p95"], None)

    def test_only_complete_known_records_and_no_input_echo(self):
        private = "PRIVATE-TRANSCRIPT-DO-NOT-PRINT"
        text = "\n".join([private, record(15) + " " + private,
                          record(99, outcome="unknown"), record(88, outcome="played-new"),
                          record(10).replace("ack_max_ms=12", "ack_max_ms=bad")])
        run = subprocess.run([sys.executable, str(SCRIPT)], input=text, text=True, capture_output=True, check=True)
        self.assertNotIn(private, run.stdout + run.stderr)
        result = json.loads(run.stdout)
        self.assertEqual(result["matched"], 1)
        self.assertEqual(result["played_metrics"]["first_audio_ms"]["median"], 15)


if __name__ == "__main__":
    unittest.main()
