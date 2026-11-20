#!/usr/bin/env python3
"""Check every commit's added lines and full message for host-specific paths (#1270).

Offline, Python 3 stdlib only. Exit 0 when clean, 1 for offences, 2 for invalid input
or a check that could not be completed. Local patterns are never printed.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

# After normalization, only a slash or LF ends the complete home component.
HOME_PATH = re.compile(r"/(Users|home)/([^/\n]+)", re.IGNORECASE)
PLACEHOLDERS = {"<you>", "me"}
NON_PERSONAL_HOMES = {("users", "shared"), ("home", "linuxbrew"), ("home", "runner")}
GH_API_USER = re.compile(
    r"(?<![\w./:+@-])(?:https://api\.github\.com/|api\.github\.com/|gh[ \t]+api[ \t]+/?)"
    r"(?P<endpoint>users/(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?|<login>))"
    r"(?=[/\s\"'`?#;|&<>()]|\Z)"
)
HUNK = re.compile(rb"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")
OBJECT_ID = re.compile(r"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\Z")


def git(*args: str) -> bytes:
    return subprocess.run(
        ["git", "--no-pager", "-c", "diff.relative=false", *args],
        check=True, capture_output=True,
    ).stdout


def commit_id(ref: str) -> str:
    return git("rev-parse", "--verify", "--end-of-options", ref + "^{commit}").decode().strip()


def local_patterns() -> list[re.Pattern]:
    common = Path(os.fsdecode(git("rev-parse", "--git-common-dir").rstrip(b"\n")))
    path = common / "info" / "host-path-patterns"
    if not path.exists():
        return []
    patterns = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        try:
            patterns.append(re.compile(line))
        except re.error:
            raise ValueError(f"invalid regex on line {number} of info/host-path-patterns") from None
    return patterns


def new_branch_base(head: str, remote: str) -> str:
    # Use local refs only: a hook must not fetch or make another network call.
    candidates = []
    try:
        candidates.append(git("symbolic-ref", "--quiet", f"refs/remotes/{remote}/HEAD").decode().strip())
    except subprocess.CalledProcessError:
        pass
    candidates.extend((f"refs/remotes/{remote}/main", "refs/remotes/origin/main"))
    for ref in dict.fromkeys(candidates):
        try:
            base = commit_id(ref)
        except subprocess.CalledProcessError:
            continue
        return git("merge-base", base, head).decode().strip()
    raise ValueError("new branch needs a local remote default-branch ref or origin/main; fetch it before retrying")


def push_ranges(remote: str) -> list[tuple[str, str]]:
    ranges = []
    for number, line in enumerate(sys.stdin, 1):
        fields = line.split()
        if len(fields) != 4 or not all(OBJECT_ID.fullmatch(fields[i]) for i in (1, 3)):
            raise ValueError(f"invalid pre-push input on line {number}")
        _, local, _, previous = fields
        if set(local) == {"0"}:
            continue  # Deleting a ref sends no new commits.
        head = commit_id(local)
        base = new_branch_base(head, remote) if set(previous) == {"0"} else commit_id(previous)
        ranges.append((base, head))
    return ranges


def added_lines(commit: str):
    """Yield (destination path, new line number, bytes), including roots and merges.

    NUL-delimited raw records keep unusual filenames out of the patch parser. Blob
    diffs preserve rename context and cannot invoke file-specific diff drivers.
    """
    parents = git("rev-list", "--parents", "-n", "1", commit).decode().split()[1:]
    revisions = [parents[0], commit] if parents else ["--root", commit]
    records = git(
        "diff-tree", "--no-commit-id", "-r", "--raw", "-z", "--no-abbrev",
        "--no-ext-diff", "--no-textconv", "--find-renames", "--diff-filter=AMRT", *revisions,
    ).split(b"\0")
    index = 0
    while index < len(records) - 1:
        old_mode, new_mode, old_blob, new_blob, status = records[index].split()
        path = records[index + 1]
        index += 2
        if status.startswith(b"R"):
            path = records[index]
            index += 1
        if new_mode == b"160000":
            continue  # A submodule pointer has no file content in this repository.
        name = os.fsdecode(path)
        if status == b"A" or old_mode == b":160000":
            content = git("cat-file", "blob", new_blob.decode())
            if b"\0" not in content[:8000]:
                lines = content.split(b"\n")
                if not lines[-1]:
                    lines.pop()  # A final newline (or empty file) adds no extra line.
                for number, line in enumerate(lines, 1):
                    ending = b"\n" if number < len(lines) or content.endswith(b"\n") else b""
                    yield name, number, line + ending
            continue
        patch = git("diff", "--no-ext-diff", "--no-textconv", "--no-color", "--unified=0",
                    old_blob.decode(), new_blob.decode())
        number = None
        lines = patch.split(b"\n")
        for patch_index, line in enumerate(lines):
            hunk = HUNK.match(line)
            if hunk:
                number = int(hunk.group(1))
            elif number is not None and line.startswith(b"+"):
                ending = b"" if lines[patch_index + 1] == b"\\ No newline at end of file" else b"\n"
                yield name, number, line[1:] + ending
                number += 1
            elif number is not None and line.startswith(b" "):
                number += 1


def normalize(text: str) -> str:
    """Canonicalize for detection only; preserve interior and unterminated CRs."""
    return re.sub(r"/+", "/", text.replace("\r\n", "\n").replace(r"\/", "/"))


def climbs_above_home(text: str, start: int) -> bool:
    """Track normalized components below the home, ignoring dot components."""
    depth = 0
    for component in text[start:].split("\n", 1)[0].split("/")[1:]:
        if component == "..":
            depth -= 1
            if depth < 0:
                return True
        elif component not in ("", "."):
            depth += 1
    return False


def has_host_path(text: str, patterns: list[re.Pattern]) -> bool:
    normalized = normalize(text)
    # Exempt only one GitHub API user endpoint, before slash normalization erases
    # exact scheme/host boundaries. Every following character remains detectable.
    detection = text.replace("\r\n", "\n").replace(r"\/", "/")
    def mask_endpoint(match):
        start = match.start("endpoint") - match.start()
        return match.group()[:start] + " " * len(match.group("endpoint"))
    detection = GH_API_USER.sub(mask_endpoint, detection)
    # Escapes and CRLF were decoded once above; do not decode a second layer.
    detection = re.sub(r"/+", "/", detection)
    return (any((match.group(2) not in PLACEHOLDERS
                 and (match.group(1).lower(), match.group(2).lower()) not in NON_PERSONAL_HOMES)
                or climbs_above_home(detection, match.end())
                for match in HOME_PATH.finditer(detection))
            or any(pattern.search(form) for pattern in patterns for form in (text, normalized)))


def check(ranges: list[tuple[str, str]], patterns: list[re.Pattern]) -> int:
    seen = set()
    offences = 0
    for base, head in ranges:
        for commit in git("rev-list", "--reverse", f"{base}..{head}").decode().splitlines():
            if commit in seen:
                continue
            seen.add(commit)
            message = git("show", "-s", "--format=format:%B", commit).decode("utf-8", errors="replace")
            if has_host_path(message, patterns):
                offences += 1
                print(f"{commit[:12]}: commit message: host-specific path")
            for path, number, raw in added_lines(commit):
                line = raw.decode("utf-8", errors="replace")
                if has_host_path(line, patterns):
                    offences += 1
                    # Name the location without echoing private paths or local regexes.
                    display = repr(path) if any(ord(char) < 32 for char in path) else path
                    print(f"{commit[:12]}: {display}:{number}: host-specific path")
    if offences:
        print("Rewrite the branch so no pushed commit contains the path. Clean the tree, then, for example,")
        print("squash to one commit with git commit-tree HEAD^{tree} -p <base> and move the branch to it.")
        print("A squash merge does not remove intermediate commits from the PR's commit list.")
        return 1
    print(f"check-host-paths: OK ({len(seen)} commits)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("range", nargs="?", help="<base>..<head> (both endpoints must resolve to commits)")
    parser.add_argument("--stdin-pre-push", action="store_true", help="read Git pre-push ref updates from stdin")
    parser.add_argument("--remote", default="origin", help="push remote for default-branch lookup (default: origin)")
    args = parser.parse_args()
    if args.stdin_pre_push == bool(args.range):
        parser.error("supply either <base>..<head> or --stdin-pre-push")
    try:
        os.chdir(os.fsdecode(git("rev-parse", "--show-toplevel").rstrip(b"\n")))
        if args.stdin_pre_push:
            ranges = push_ranges(args.remote)
        else:
            if args.range.count("..") != 1 or "..." in args.range:
                raise ValueError("expected <base>..<head>")
            base, head = args.range.split("..")
            if not base or not head:
                raise ValueError("both range endpoints are required")
            ranges = [(commit_id(base), commit_id(head))]
        return check(ranges, local_patterns())
    except subprocess.CalledProcessError:
        print("check-host-paths: cannot read Git commits/refs; ensure the range and local history are available",
              file=sys.stderr)
    except (ValueError, OSError, UnicodeError) as error:
        print(f"check-host-paths: {error}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
