#!/usr/bin/env python3
"""Spec-to-test traceability (#27).

Reads the spec issue a PR closes, extracts the names under "Test expectations", and checks that each
named Swift test suite exists in declared test sources with at least one test, each named script test file exists, and
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

try:
    import yaml
except ModuleNotFoundError:
    raise SystemExit("spec trace requires PyYAML 6.0.3: install scripts/spec-trace-requirements.txt in a venv; "
                     "set SPEC_TRACE_PYTHON to its Python executable for scripts/verify.sh")

if yaml.__version__ != "6.0.3":
    raise SystemExit("spec trace requires pinned PyYAML 6.0.3: install scripts/spec-trace-requirements.txt in a venv; "
                     "set SPEC_TRACE_PYTHON to its Python executable for scripts/verify.sh")


class ProjectLoader(yaml.SafeLoader):
    """Data only, with ambiguous duplicate keys and aliases rejected rather than interpreted."""

    def compose_node(self, parent, index):
        if self.check_event(yaml.AliasEvent):
            raise yaml.YAMLError("project aliases are unsupported")
        return super().compose_node(parent, index)

    def construct_mapping(self, node, deep=False):
        keys = set()
        for key, _ in node.value:
            if (not isinstance(key, yaml.ScalarNode) or key.tag != "tag:yaml.org,2002:str" or
                    key.value in keys or key.value.endswith(":REPLACE")):
                raise yaml.YAMLError("project keys must be unique strings without merge overrides")
            keys.add(key.value)
        return super().construct_mapping(node, deep=deep)

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


def contained_path(path: Path, tree: Path) -> bool:
    """Only real paths in this checkout, never symlinks (including ancestor directories)."""
    base = tree.resolve()
    try:
        relative = path.absolute().relative_to(tree.absolute())
        return path.resolve().is_relative_to(base) and not any(
            (tree / Path(*relative.parts[:index])).is_symlink() for index in range(1, len(relative.parts) + 1)
        )
    except (ValueError, OSError, RuntimeError):
        return False


def xcode_descendant_wrapper(root: Path, tree: Path) -> Path | None:
    """Fail closed instead of recursively interpreting resource/file wrappers as source groups.

    An explicit root group may have an extension, but its descendants are inferred by XcodeGen. The
    narrow supported schema does not model every wrapper extension, so any descendant directory with
    an extension needs a separate concrete source declaration instead of this recursive source root.
    """
    for directory, children, _ in os.walk(root, followlinks=False):
        children[:] = [name for name in sorted(children) if contained_path(Path(directory) / name, tree)]
        for name in children:
            if Path(name).suffix:
                return Path(directory) / name
    return None


def xcode_test_paths(tree: Path, problems: list[str] | None = None) -> list[Path]:
    """Read the root XcodeGen spec, not generated projects or arbitrary nested manifests.

    A deliberately narrow subset: concrete test targets with unfiltered compile-source paths. Unsupported
    selection/merging forms fail closed; this is presence evidence, not Xcode build or execution proof.
    """
    manifest = tree / "project.yml"
    def reject(reason):
        if problems is not None:
            problems.append(f"Xcode test discovery: {reason}; use concrete unfiltered compile sources in root project.yml")

    if not manifest.exists() and not manifest.is_symlink():
        return []
    if not manifest.is_file() or not contained_path(manifest, tree):
        reject("project.yml is not a regular in-tree file (symlinks are unsupported)")
        return []
    if manifest.stat().st_size > 1024 * 1024:
        reject("project.yml exceeds the 1 MiB metadata limit")
        return []
    try:
        project = yaml.load(manifest.read_text(errors="replace"), Loader=ProjectLoader)
    except (yaml.YAMLError, RecursionError):
        reject("project.yml is malformed or uses unsupported YAML tags, aliases, duplicate keys, or :REPLACE overrides")
        return []
    if not isinstance(project, dict):
        reject("project.yml must be a mapping")
        return []
    unsupported = set(project) & {"include", "configFiles"}
    if unsupported:
        reject("project.yml uses unsupported " + ", ".join(sorted(unsupported)))
        return []
    options = project.get("options", {})
    if (not isinstance(options, dict) or "fileTypes" in options or
            options.get("defaultSourceDirectoryType", "group") != "group"):
        reject("project.yml options are malformed, override fileTypes, or use a non-group defaultSourceDirectoryType")
        return []
    # Build settings can remove otherwise-declared Swift sources. Do not claim these paths without
    # interpreting their configuration-dependent patterns.
    def filtered_settings(settings):
        if not isinstance(settings, dict):
            return True
        return any(key == "groups" or re.match(r"^(?:EXCLUDED|INCLUDED)_SOURCE_FILE_NAMES(?:\[|$)", key) or
                   (isinstance(value, dict) and filtered_settings(value)) for key, value in settings.items())

    if filtered_settings(project.get("settings", {})):
        reject("project.yml settings are malformed, reference groups, or filter source file names")
        return []
    targets = project.get("targets", {})
    if not isinstance(targets, dict):
        reject("project.yml targets must be a mapping")
        return []
    roots = []
    for name, target in targets.items():
        if not isinstance(target, dict) or target.get("type") not in ("bundle.ui-testing", "bundle.unit-test"):
            continue
        unsupported = set(target) & {"templates", "template", "settingGroups", "configFiles"}
        if unsupported or filtered_settings(target.get("settings", {})):
            reject(f"target {name} uses unsupported " + (", ".join(sorted(unsupported)) if unsupported else "source-filtering settings"))
            continue
        sources = target.get("sources", [])
        if isinstance(sources, (str, dict)):
            sources = [sources]
        if not isinstance(sources, list):
            reject(f"target {name} sources must be a path or a list of paths")
            continue
        for source in sources:
            source_type = None
            if isinstance(source, dict):
                if (set(source) - {"path", "type", "buildPhase"} or
                        source.get("type", "group") not in ("group", "file") or
                        source.get("buildPhase", "sources") != "sources"):
                    reject(f"target {name} source mapping must use only path, group/file type, and sources buildPhase")
                    continue
                source_type = source.get("type")
                source = source.get("path")
            if not isinstance(source, str) or not source or "$" in source or Path(source).is_absolute():
                reject(f"target {name} source must be a nonempty literal relative path")
                continue
            root = tree / source
            if contained_path(root, tree):
                if root.is_dir() and (source_type == "file" or (source_type is None and root.suffix)):
                    reject(f"target {name} directory source must be a source group, not a file reference")
                elif root.is_dir() and (wrapper := xcode_descendant_wrapper(root, tree)):
                    reject(f"target {name} source contains unsupported descendant directory wrapper "
                           f"{wrapper.relative_to(tree)}; declare concrete compile-source groups/files separately")
                else:
                    roots.append(root)
            else:
                reject(f"target {name} source escapes the tree or traverses a symlink")
    return roots


def test_target_paths(tree: Path, problems: list[str] | None = None) -> list[Path]:
    """Union of SwiftPM and root XcodeGen test sources. Only a tree with neither manifest falls back
    to Tests/. Removing declared targets must not make leftover source files satisfy the gate."""
    manifest = tree / "Package.swift"
    xcode_manifest = tree / "project.yml"
    if not any(p.exists() or p.is_symlink() for p in (manifest, xcode_manifest)):
        return [tree / "Tests"]
    text = strip_code(manifest.read_text(errors="replace"), keep_strings=True) if manifest.is_file() and contained_path(manifest, tree) else ""
    names = re.findall(r'\.testTarget\(\s*name:\s*"([^"]+)"', text)
    explicit = dict(re.findall(r'\.testTarget\(\s*name:\s*"([^"]+)"[^)]*?path:\s*"([^"]+)"', text))
    roots = [(tree / explicit.get(name, f"Tests/{name}")) for name in names]
    return list(dict.fromkeys([root for root in roots if contained_path(root, tree)] + xcode_test_paths(tree, problems)))


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
        f for root in test_target_paths(tree, problems)
        for f in (root.rglob("*.swift") if root.is_dir() else [root] if root.is_file() and root.suffix == ".swift" else [])
        if contained_path(f, tree)
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
    blocking = [p for p in problems if p.startswith("Xcode test discovery:") or
                not any(f"`{name}`" in p for name in deferred)]
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
