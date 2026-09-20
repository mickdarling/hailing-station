#!/usr/bin/env python3
"""Spec-to-test traceability (#27).

Reads the spec issue a PR closes, extracts the names under "Test expectations", and checks that each
named Swift test suite exists in Tests/ with at least one test, each named script test file exists, and
each manual runbook path exists. `trace: partial` in the PR body downgrades failures to warnings.

Usable offline: `trace.py --spec-body FILE --tree DIR [--partial]`.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

SECTION = re.compile(r"^#{2,3}\s*test expectations\b[^\n]*$(.*?)(?=^#{2,3}\s|\Z)", re.M | re.S | re.I)
TOKEN = re.compile(r"`([^`\n]+)`")
HAS_TEST = re.compile(r"@Test\b|\bfunc\s+test[A-Z_]")


def strip_code(source: str, keep_strings: bool = False) -> str:
    """Remove comments, string literals (plain, multi-line, raw), and `#if false` blocks so text inside
    them cannot satisfy a check. A small scanner rather than one regex: block comments nest in Swift and
    raw strings carry their own hash-delimited quotes. Residual: `#if <expr>` with a false expression other
    than the literal `false`; the test lane is the execution proof."""
    out: list[str] = []
    i, n = 0, len(source)
    while i < n:
        ch = source[i]
        if source.startswith("//", i):
            while i < n and source[i] != "\n":
                i += 1
        elif source.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if source.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif source.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
            out.append(" ")
        elif keep_strings and ch == '"':
            # Manifest mode: keep string literals verbatim (target names live in them), still skip escapes.
            start = i
            i += 1
            while i < n and source[i] != '"':
                i += 2 if source[i] == "\\" else 1
            i += 1
            out.append(source[start:i])
        elif ch == "#" and (m := re.match(r"#+", source[i:])) and source.startswith('"', i + len(m.group())):
            hashes = m.group()
            i += len(hashes)
            quote = '"""' if source.startswith('"""', i) else '"'
            close = quote + hashes
            i += len(quote)
            end = source.find(close, i)
            i = n if end < 0 else end + len(close)
            out.append('""')
        elif source.startswith('"""', i):
            end = source.find('"""', i + 3)
            i = n if end < 0 else end + 3
            out.append('""')
        elif ch == '"':
            i += 1
            while i < n and source[i] != '"':
                i += 2 if source[i] == "\\" else 1
            i += 1
            out.append('""')
        elif re.match(r"#if\s+false\b", source[i:]):
            depth, i = 1, i + 3
            while i < n and depth:
                if re.match(r"#if\b", source[i:]):
                    depth, i = depth + 1, i + 3
                elif source.startswith("#endif", i):
                    depth, i = depth - 1, i + len("#endif")
                else:
                    i += 1
            out.append(" ")
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def test_target_paths(tree: Path) -> list[Path]:
    """Directories of the test targets Package.swift declares. No manifest: Tests/. A manifest that declares
    no test target yields nothing, so a PR that drops the targets cannot pass by leaving files behind.
    Roots outside the tree (a `path: "../x"` escape) are ignored."""
    manifest = tree / "Package.swift"
    if not manifest.exists():
        return [tree / "Tests"]
    text = strip_code(manifest.read_text(errors="replace"), keep_strings=True)
    names = re.findall(r'\.testTarget\(\s*name:\s*"([^"]+)"', text)
    explicit = dict(re.findall(r'\.testTarget\(\s*name:\s*"([^"]+)"[^)]*?path:\s*"([^"]+)"', text))
    base = tree.resolve()
    roots = [(tree / explicit.get(name, f"Tests/{name}")) for name in names]
    return [root for root in roots if root.resolve().is_relative_to(base)]


def suite_bodies(name: str, source: str) -> list[str]:
    """Bodies of every `struct|class|enum|actor|extension <name> { ... }` in `source`, brace-matched."""
    bodies: list[str] = []
    pattern = r"\b(?:struct|class|enum|actor|extension)\s+" + re.escape(name) + r"\b[^{]*\{"
    for match in re.finditer(pattern, source):
        depth, start = 1, match.end()
        for index in range(start, len(source)):
            if source[index] == "{":
                depth += 1
            elif source[index] == "}":
                depth -= 1
                if depth == 0:
                    bodies.append(source[start:index])
                    break
    return bodies


def expectations(spec_body: str) -> list[str]:
    match = SECTION.search(spec_body)
    if not match:
        return []
    return sorted({token.strip() for token in TOKEN.findall(match.group(1))})


def check(tokens: list[str], tree: Path) -> list[str]:
    problems: list[str] = []
    swift_files = [
        f for root in test_target_paths(tree) if root.is_dir()
        for f in root.rglob("*.swift") if not f.is_symlink() and f.resolve().is_relative_to(tree.resolve())
    ]
    sources = {f: strip_code(f.read_text(errors="replace")) for f in swift_files}
    for token in tokens:
        if token.endswith("Tests"):
            bodies = [body for source in sources.values() for body in suite_bodies(token, source)]
            if not bodies:
                problems.append(f"suite `{token}` not found under Tests/")
            elif not any(HAS_TEST.search(body) for body in bodies):
                problems.append(f"suite `{token}` exists but contains no tests")
        elif token.endswith((".py", ".sh")) or token.startswith(("scripts/tests/", "docs/testing/", "docs/")):
            if not (tree / token).exists():
                problems.append(f"file `{token}` not found")
        # other tokens (prose, commands) are not checked
    return problems


def pr_context(repo: str, number: str) -> tuple[str, bool, set[str]]:
    body = json.loads(subprocess.run(
        ["gh", "pr", "view", number, "-R", repo, "--json", "body"], check=True, capture_output=True, text=True
    ).stdout)["body"] or ""
    partial = re.search(r"(?im)^trace:\s*partial\b", body)
    deferred = set()
    if partial:
        listed = re.search(r"(?im)^trace:\s*partial\s*:\s*(.+)$", body)
        deferred = {name.strip().strip("`") for name in (listed.group(1).split(",") if listed else []) if name.strip()}
    partial = partial is not None
    match = re.search(r"(?i)\b(?:closes|part of)\s+#(\d+)", body)
    if not match:
        print("traceability: no spec link in PR body; nothing to trace")
        sys.exit(0)
    spec = json.loads(subprocess.run(
        ["gh", "issue", "view", match.group(1), "-R", repo, "--json", "body"], check=True, capture_output=True, text=True
    ).stdout)["body"] or ""
    return spec, partial, deferred


def run(spec: str, tree: Path, partial: bool, deferred: set[str] | None = None) -> tuple[list[str], int]:
    """Problems found and the exit code. `trace: partial: A, B` defers only the named tokens; any other
    missing expectation still fails, so partial cannot silently hide an unlisted gap."""
    deferred = deferred or set()
    problems = check(expectations(spec), tree)
    blocking = [p for p in problems if not any(f"`{name}`" in p for name in deferred)]
    return problems, (1 if blocking else 0)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--spec-body", type=Path)
    parser.add_argument("--tree", type=Path, default=Path("."))
    parser.add_argument("--partial", action="store_true")
    parser.add_argument("--defer", default="", help="comma-separated expectation names deferred by trace: partial")
    args = parser.parse_args()

    if args.spec_body:
        spec, partial = args.spec_body.read_text(), args.partial
        deferred = {name.strip() for name in args.defer.split(",") if name.strip()}
    else:
        spec, partial, deferred = pr_context(os.environ["GITHUB_REPOSITORY"], os.environ["PR_NUMBER"])

    problems, code = run(spec, args.tree, partial, deferred)
    print(f"traceability: {len(expectations(spec))} expectation(s) named, {len(problems)} problem(s)")
    for problem in problems:
        print(f"  - {problem}")
    print("traceability: " + ("OK" if not problems else "WARN (deferred by trace: partial)" if code == 0 else "FAIL"))
    return code


if __name__ == "__main__":
    sys.exit(main())
