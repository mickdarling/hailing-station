#!/usr/bin/env python3
"""Summarize #737 reply-timing log lines from stdin without echoing input."""
import json
import re
import statistics
import sys

# Match the complete, fixed-order record produced by ReplyStreamTiming.Summary.line.
RECORD = re.compile(
    r"(?<!\w)reply audio: frames=(\d+) audio_ms=(\d+) "
    r"first_audio_ms=(\d+|none) min_lead_ms=(-?\d+|none) "
    r"ack_max_ms=(\d+) ack_p95_ms=(\d+) resends=(\d+) wall_ms=(\d+) "
    r"outcome=(played_unmeasured|played|failed|cancelled|superseded)(?=\s|$)"
)
FIELDS = ("frames", "audio_ms", "first_audio_ms", "min_lead_ms", "ack_max_ms", "ack_p95_ms", "resends", "wall_ms")
OUTCOMES = ("played", "played_unmeasured", "failed", "cancelled", "superseded")


def summarize(lines):
    outcomes = dict.fromkeys(OUTCOMES, 0)
    values = {field: [] for field in FIELDS}
    matched = 0
    for line in lines:
        match = RECORD.search(line)
        if not match:
            continue
        *numbers, outcome = match.groups()
        matched += 1
        outcomes[outcome] += 1
        if outcome != "played":
            continue
        for field, value in zip(FIELDS, numbers):
            if value != "none":
                values[field].append(int(value))

    def stats(items):
        if not items:
            return {"n": 0, "min": None, "median": None, "p95": None, "max": None}
        items.sort()
        return {"n": len(items), "min": items[0], "median": statistics.median(items),
                "p95": items[(95 * len(items) + 99) // 100 - 1], "max": items[-1]}

    return {"matched": matched, "outcomes": outcomes,
            "played_metrics": {field: stats(items) for field, items in values.items()}}


def main():
    json.dump(summarize(sys.stdin), sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
