#!/usr/bin/env python3
"""PR shape check (#25, #48): size limit, spec link, open spec issue, review records.

Runs in CI with GH_TOKEN and PR_NUMBER set; exits 1 with a plain-language reason on failure.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys

MAX_SOURCE_FILES = 4
# The four-file limit counts production source. Tests are the proof of the change, not its burden, and
# repo dotfiles are one-line housekeeping; both still appear in the diff and the review.
EXCLUDED_PREFIXES = ("docs/", "fixtures/", ".github/ISSUE_TEMPLATE/", "Tests/", "scripts/tests/")
EXCLUDED_SUFFIXES = (".md", ".json", ".resolved", ".txt", ".gitignore", ".gitattributes")
SPEC_LABELS = {"type:feature", "type:spike", "type:chore", "type:epic"}
# Keep in step with CODEOWNERS and .github/labeler.yml. The enforcement surface (scripts, workflows, labeler
# config, package and build manifests) is itself security-critical (#48, second-key review of #55).
SECURITY_PATHS = (
    "Sources/HailProtocol/Sealed/", "Sources/HailCore/Identity/", "Sources/HailCore/Security/",
    "Sources/HailDaemonKit/Identity/", "Sources/HailDaemonKit/Listener/", "Sources/HailDaemonKit/Policy/",
    "Sources/HailDaemonKit/Sanitize/", "Sources/HailDaemonKit/Audit/", "Sources/HailDaemonKit/Lockdown/",
    "Sources/HailDaemonKit/PushEndpoint/", "bin/hail-install", ".github/", "CODEOWNERS", "scripts/",
    "Package.swift", "Package.resolved", "Brewfile", "project.yml", "docs/security/", ".gitattributes",
)
VERDICT = r"\b(APPROVE WITH FIXES|APPROVE|REQUEST CHANGES)\b"
SECOND_KEY_HEADING = "## Review record (independent second key"


def gh(*args: str) -> str:
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def main() -> int:
    repo = os.environ["GITHUB_REPOSITORY"]
    number = os.environ["PR_NUMBER"]
    pr = json.loads(gh("pr", "view", number, "-R", repo, "--json", "body,labels,headRefOid"))
    body = pr["body"] or ""
    labels = {label["name"] for label in pr["labels"]}
    head = pr["headRefOid"]
    # Paged REST listing, oldest first, so the newest second-key comment is found past 100 comments.
    comment_pages = json.loads(gh("api", "--paginate", "--slurp", f"repos/{repo}/issues/{number}/comments"))
    comments = [entry.get("body") or "" for page in comment_pages for entry in page]
    # Paged REST listing: `gh pr view --json files` stops at 100 entries. Renames count under both names.
    pages = json.loads(gh("api", "--paginate", "--slurp", f"repos/{repo}/pulls/{number}/files"))
    files = [name for page in pages for entry in page
             for name in (entry["filename"], entry.get("previous_filename")) if name]
    problems: list[str] = []

    source = [
        f for f in files
        if not f.startswith(EXCLUDED_PREFIXES) and not f.endswith(EXCLUDED_SUFFIXES)
    ]
    if len(source) > MAX_SOURCE_FILES and "bootstrap" not in labels:
        problems.append(
            f"{len(source)} source files changed; the limit is {MAX_SOURCE_FILES}. Split the PR. "
            f"Files: {', '.join(source)}"
        )

    match = re.search(r"(?i)\b(closes|part of)\s+#(\d+)", body)
    if not match:
        problems.append("PR body needs a 'Closes #N' or 'Part of #N' line pointing at the spec issue.")
    else:
        number_ref = match.group(2)
        try:
            issue = json.loads(gh("issue", "view", number_ref, "-R", repo, "--json", "state,labels"))
        except subprocess.CalledProcessError:
            issue = None
            problems.append(f"Spec reference #{number_ref} is not an issue in this repo (a PR number, or deleted).")
        if issue:
            issue_labels = {label["name"] for label in issue["labels"]}
            if issue["state"] != "OPEN":
                problems.append(f"Spec issue #{number_ref} is not open.")
            if not issue_labels & SPEC_LABELS:
                problems.append(f"Spec issue #{number_ref} is not labelled as a spec ({', '.join(sorted(SPEC_LABELS))}).")

    # A record is a "Round N:" body line carrying a verdict; the LAST verdict must approve.
    rounds = {
        int(m.group(1)): m.group(2).upper()
        for m in re.finditer(r"(?im)^round\s+(\d+)\s*:.*?" + VERDICT, body)
    }
    if not rounds:
        problems.append("Review record needs at least one 'Round N: <verdict> ...' line with a verdict.")
    elif rounds[max(rounds)] == "REQUEST CHANGES":
        problems.append("The latest review round says REQUEST CHANGES; fix and record the next round.")

    touches_security = any(f.startswith(SECURITY_PATHS) or f in SECURITY_PATHS for f in files)
    if touches_security and "security:critical" not in labels:
        problems.append("PR touches a security-critical path but lacks the security:critical label.")
    if touches_security or "security:critical" in labels:
        # The second key is the NEWEST PR comment with the heading; its first verdict must be an APPROVE and it
        # must name the head commit it reviewed (`head: <sha>`), so later pushes need a fresh approval.
        second = [c for c in comments if c.startswith(SECOND_KEY_HEADING)]
        if not second:
            problems.append("security:critical needs an independent second-key review posted as a PR comment "
                            f"headed '{SECOND_KEY_HEADING}, round N)'.")
        else:
            newest = second[-1]
            verdict = re.search(VERDICT, newest)
            reviewed = re.search(r"\bhead:\s*([0-9a-f]{40})\b", newest)
            if not verdict or not verdict.group(1).upper().startswith("APPROVE"):
                problems.append("The newest second-key comment does not approve; fix and request a re-review.")
            if not reviewed or reviewed.group(1) != head:
                problems.append("The newest second-key comment must state `head: <full 40-hex sha>` equal to the current head "
                                f"({head[:12]}); a push after approval needs a fresh second key.")

    if problems:
        print("pr-shape: FAIL")
        for problem in problems:
            print(f"  - {problem}")
        return 1
    print("pr-shape: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
