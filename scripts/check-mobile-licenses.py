#!/usr/bin/env python3
"""Inventory the third-party inputs to the iOS/iPadOS products (#1391).

Use the project's XcodeGen and SwiftPM tools for YAML and Swift manifests.
Read remote packages from the build's pinned checkouts. Never fetch a license
from a default branch, or infer membership from the mere presence of a pin.
"""
from __future__ import annotations

import hashlib
import json
import os
import plistlib
import re
import shlex
import subprocess
import sys
import tempfile
from functools import cached_property, lru_cache
from pathlib import Path


# SHA-256 of normalize(text/<id>.txt) from spdx/license-list-data. Compare
# complete terms so a modified license with an MIT preamble cannot pass as MIT.
LICENSE_TEXT = {
    "MIT": "56959050891f7b737ac4e803051170c7197f02df73d80bd9a78d968e305bf558",
    "BSD-2-Clause": "11cf92b65eda2f9cd73e18d3066283da5c37dd1f10edf0e3ac9889ac7634fe65",
    "BSD-3-Clause": "f7737e83d7d22d6fcf82026dec12bd6d8a182362b207e402117edff1f58bcad4",
    "Apache-2.0": "42067e2d9d3cba9f5e494d2ff4c7b44d4d30193620c98d21e2cb2810fd27e851",
    "ISC": "a2a686418bbdbf37f28aaf01ff3aef45cfe077a641470465923c8c23fcbe08f9",
    "Zlib": "01be54f63aa1c0fd545e6f02c680c2b685989f41cd0fd299fd7089005e211682",
}
COPYLEFT = re.compile(r"\b(?:A|L)?GPL(?:\b|v?\d)", re.I)
SPDX = re.compile(r"(?im)^[ \t]*(?:[/#*;!<-]+[ \t]*)?SPDX-License-Identifier:[ \t]*([^\r\n]*?)[ \t]*(?:\*/|-->|\r?$)")
GNU_TITLE = re.compile(r"\bGNU\s+(?:(Affero|Lesser|Library)\s+)?General\s+Public\s+License"
                       r"(?:[,\s]+(?:version\s*|v)?(\d+(?:\.\d+)?))?", re.I)
GNU_SHORT = re.compile(r"\b([AL]?GPL)(?:[- ]?(?:version\s*|v)?(\d+(?:\.\d+)?)(-only|-or-later|\+)?)?(?!\w)", re.I)
GRANT = re.compile(r"(?:licen[sc]es?|copying)(?:[._ -].*)?", re.I)
NOTICE = re.compile(r"(?:notices?|attributions?|credits?|open[ ._-]*source[ ._-]*notices?|"
                    r"third[ ._-]*part(?:y|ies).*|acknowledg(?:e)?ments?)(?:[._ -].*)?", re.I)
SOURCE = {".swift", ".h", ".hpp", ".c", ".cc", ".cpp", ".cxx", ".m", ".mm", ".s", ".metal", ".modulemap"}
HEADERS = {".h", ".hh", ".hpp", ".hxx", ".h++", ".hp", ".ipp", ".def", ".pch", ".inc", ".inl", ".modulemap"}
IMPLICIT = {".metal", ".nib", ".storyboard", ".xib", ".xcassets", ".xcstrings", ".strings", ".stringsdict",
            ".xcdatamodel", ".xcdatamodeld", ".xcmappingmodel", ".xcprivacy", ".mlmodel", ".mlmodelc",
            ".mlpackage", ".mlmodelgroup", ".model", ".onnx", ".tflite", ".gguf", ".ggml", ".safetensors",
            ".bin", ".lproj"}
TEXT = SOURCE | HEADERS | {".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".json", ".txt", ".md", ".markdown",
                           ".html", ".htm", ".css", ".svg", ".xml", ".yaml", ".yml", ".py", ".sh", ".bash",
                           ".zsh", ".rb", ".lua", ".toml", ".plist", ".strings", ".stringsdict", ".xcstrings",
                           ".storyboard", ".xib", ".xcprivacy", ".xcconfig", ".csv"}
VENDOR = {"native", "vendor", "vendors", "vendored", "thirdparty", "external", "externals"}


def normalize(text):
    # Only remove whole, recognizable attribution lines. Unrecognized holder
    # formats get manual review, as does any prose appended to an attribution.
    year = r"(?:<year>|\d{4}(?:[-–, ]+\d{4})*)"
    holder = (r"(?!(?i:.*\b(?:no|only|use|commercial|noncommercial|prohibited|restricted|license)\b))"
              r"(?:<(?i:owner|copyright holders?)>|[A-Z][\w'’-]*(?: [A-Z][\w'’-]*)?"
              r"(?:,? (?:Inc|LLC|Corp|Ltd|Foundation))?)\.?")
    copyright_line = rf"(?i:copyright\s+(?:\(c\)\s*)?){year}(?:,? +{holder})?(?: All rights reserved\.)?"
    heading = r"(?i:all rights reserved\.|(?:the )?(?:mit|isc|zlib|bsd[ -][23][ -]clause) license\.?)"
    text = re.sub(rf"\A(?:\s*(?:{copyright_line}|{heading})[ \t]*(?:\n|$))+", "", text)
    text = re.sub(r"(?m)^\s*(?:\d+\.|\*)\s+", "", text)
    return " ".join(text.lower().split()).replace("https://www.apache.org/", "http://www.apache.org/")


def gnu_ids(text):
    ids = set()
    for family, version in GNU_TITLE.findall(text):
        prefix = {"affero": "AGPL", "lesser": "LGPL", "library": "LGPL"}.get(family.lower(), "GPL")
        if version and "." not in version:
            version += ".0"
        ids.add(f"{prefix}-{version}" if version else prefix)
    for family, version, suffix in GNU_SHORT.findall(text):
        if version and "." not in version:
            version += ".0"
        ids.add(f"{family.upper()}-{version}{suffix.lower()}" if version else family.upper())
    return ids


def declarations(text):
    ids = {s.strip() or "UNKNOWN" for s in SPDX.findall(text)}
    ids.update(s.strip() or "UNKNOWN" for s in re.findall(r'(?i)"SPDX-License-Identifier"\s*:\s*"([^"]*)"', text))
    return ids | gnu_ids(text)


def license_ids(text):
    ids = declarations(text)
    rest = SPDX.sub("", text).strip()
    if not rest:
        return ids or {"UNKNOWN"}
    if re.fullmatch(r"[\w.+-]+", rest):
        return ids | {rest}
    if any(COPYLEFT.search(value) for value in ids):
        # A GNU declaration is already an unconditional failure.
        return ids
    for name in LICENSE_TEXT:
        if rest.lower() == f"{name.lower()} license":
            return ids | {name}
    terms = normalize(rest)
    if ids and not terms:
        return ids
    digest = hashlib.sha256(terms.encode()).hexdigest()
    return ids | {next((name for name, expected in LICENSE_TEXT.items() if digest == expected), "UNKNOWN")}


def file_declarations(text, suffix):
    ids = declarations(text)
    if "spdx-license-identifier:" not in text.lower():
        return ids
    if suffix in {".txt", ".md", ".markdown"}:
        return license_ids(text)
    # Validate the prose in an SPDX-bearing comment separately from executable
    # statements. Extra restrictions in a multiline source notice need review.
    blocks = re.finditer(r"/\*.*?\*/|<!--.*?-->|(?:^[ \t]*//[^\n]*(?:\n|$))+|"
                         r"(?:^[ \t]*\#(?![!])[^\n]*(?:\n|$))+", text, re.M | re.S)
    for block in blocks:
        notice = block.group()
        if SPDX.search(notice):
            notice = notice.removeprefix("/*").removesuffix("*/").removeprefix("<!--").removesuffix("-->")
            notice = re.sub(r"(?m)^[ \t]*(?://|\#|\*)[ \t]?", "", notice)
            ids.update(license_ids(notice))
    return ids


def permitted(expression):
    # AND/OR can only combine grants from the six permitted licenses. WITH
    # exceptions or any additional terms need review.
    allowed = "(?:" + "|".join(map(re.escape, LICENSE_TEXT)) + ")"
    series = allowed + r"(?:\s+(?:AND|OR)\s+" + allowed + ")*"
    while re.search(r"\(\s*" + series + r"\s*\)", expression):
        expression = re.sub(r"\(\s*" + series + r"\s*\)", "MIT", expression)
    return re.fullmatch(series, expression) is not None


@lru_cache(maxsize=None)
def directory_licenses(directory):
    evidence = {}
    for file in sorted(directory.iterdir()):
        if GRANT.fullmatch(file.name) or NOTICE.fullmatch(file.name):
            if file.is_symlink():
                raise ValueError(f"unresolved license symlink {file}")
            if file.is_file():
                evidence[file] = license_ids(read_text(file))
    metadata = directory / "package.json"
    if metadata.is_symlink():
        raise ValueError(f"unresolved metadata symlink {metadata}")
    if metadata.is_file():
        value = json.loads(metadata.read_text()).get("license")
        if value is not None:
            value = value.strip() if isinstance(value, str) else ""
            evidence[metadata] = gnu_ids(value) or {value or "UNKNOWN"}
    return evidence


def read_text(path, sniff=False):
    with path.open("rb") as stream:
        prefix = stream.peek(4096)[:4096]
        if prefix.startswith((b"\xff\xfe\x00\x00", b"\x00\x00\xfe\xff")):
            encoding = "utf-32"
        elif prefix.startswith((b"\xff\xfe", b"\xfe\xff")):
            encoding = "utf-16"
        elif sniff and re.search(rb"[\x00-\x08\x0e-\x1f\x7f]", prefix):
            return ""
        else:
            encoding = "utf-8-sig"
        return stream.read().decode(encoding, errors="replace").replace("\r\n", "\n").replace("\r", "\n")


def command_json(*args, cwd):
    output = subprocess.check_output(args, cwd=cwd, text=True)
    # SwiftPM describe can print these diagnostics on stdout before its JSON,
    # including for unrelated test resources.
    return json.loads(re.sub(r"\A(?:Found unhandled resource at [^\n]*\n)+", "", output))


@lru_cache(maxsize=None)
def manifest(package):
    return command_json("swift", "package", "dump-package", cwd=package)


@lru_cache(maxsize=None)
def package_files(package):
    description = command_json("swift", "package", "describe", "--type", "json", cwd=package)
    return {target["name"]: target for target in description["targets"]}


def mobile(values):
    if isinstance(values, str):
        values = [values]
    return bool({"ios", "ipados"} & {value.lower() for value in values})


def identity(location):
    return location.rstrip("/").rsplit("/", 1)[-1].removesuffix(".git").lower()


def check_flags(value, setting):
    tokens = shlex.split(value) if isinstance(value, str) else value
    harmless = {"$(inherited)", "-ObjC", "-all_load", "-dead_strip", "-fobjc-arc", "-fno-objc-arc"}
    if any(flag not in harmless and not re.fullmatch(r"-D\w+(?:=\w+)?", flag) for flag in tokens):
        raise ValueError(f"cannot determine linked inputs from {setting}: {value}")


class Inventory:
    def __init__(self, root, spec):
        self.root = root
        self.spec = spec
        self.rows = set()
        self.targets = set()
        self.package_targets = set()
        self.local_packages = set()
        self.scanned = set()
        self.build = root / ".build/mobile-packages"

    @cached_property
    def pins(self):
        # Local path dependencies ship from the app tree. A source-control
        # edge must use the same committed workspace lock in CI and archive.
        name = self.spec["name"]
        lock = Path(f"{name}.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        committed = subprocess.run(["git", "show", f"HEAD:{lock}"], cwd=self.root, capture_output=True)
        current = self.path(self.root / lock)
        if committed.returncode or not current.is_file() or current.read_bytes() != committed.stdout:
            raise ValueError(f"remote mobile packages require a current committed Xcode resolution: {lock}")
        data = json.loads(committed.stdout)
        return {identity(p.get("identity") or p["repositoryURL"]): p
                for p in data.get("object", data)["pins"]}

    def path(self, path):
        resolved = self.root
        for part in path.relative_to(self.root).parts:
            if part == "..":
                if resolved == self.root:
                    raise ValueError(f"mobile input outside repository: {path}")
                resolved = resolved.parent
            else:
                resolved /= part
                if resolved.is_symlink():
                    raise ValueError(f"unresolved ownership of symlink {resolved}")
        return resolved

    def git_paths(self, *args):
        result = subprocess.run(["git", "--no-optional-locks", *args], cwd=self.root, capture_output=True)
        if result.returncode:
            raise ValueError("local mobile packages require inputs committed in the app repository")
        return {self.root / p for p in os.fsdecode(result.stdout).split("\0") if p}

    @cached_property
    def changed_files(self):
        return self.git_paths("diff", "--no-renames", "--name-only", "-z", "HEAD")

    @cached_property
    def committed_files(self):
        return self.git_paths("ls-tree", "-rz", "--name-only", "HEAD") - self.changed_files

    def check_local_input(self, package, path):
        if package in self.local_packages and path not in self.committed_files:
            raise ValueError(f"uncommitted local mobile package input: {path.relative_to(self.root)}")

    def notices(self, package, directory):
        # A removed grant would otherwise disappear along with its evidence.
        if package in self.local_packages:
            for path in self.changed_files:
                if path.parent == directory and (GRANT.fullmatch(path.name) or NOTICE.fullmatch(path.name)
                                                 or path.name == "package.json"):
                    self.check_local_input(package, path)
        return directory_licenses(directory)

    def row(self, component, origin, licenses):
        for license_id in licenses:
            self.rows.add((str(component), str(origin), license_id))

    def header(self, path, package):
        path = self.path(path)
        if not path.is_file():
            raise ValueError(f"missing mobile header {path}")
        self.scan_file(path, package, as_header=True)

    def scan_file(self, path, package, as_header=False):
        self.check_local_input(package, path)
        if (path, package, as_header) in self.scanned:
            return
        self.scanned.add((path, package, as_header))
        rel = path.relative_to(self.root)
        # Xcode inputs have no SwiftPM package. Quoted includes may also
        # leave a local package for another header committed in the app tree.
        base = package if package and path.is_relative_to(package) else self.root
        scope = path.relative_to(base)
        boundary = base
        for i, part in enumerate(scope.parts[:-1]):
            marker = re.sub(r"[-_ ]", "", part.lower())
            if marker in VENDOR and (marker != "native" or base == self.root):
                boundary = base.joinpath(*scope.parts[:min(i + 2, len(scope.parts) - 1)])
        header = read_text(path, sniff=not as_header and path.suffix.lower() not in TEXT)
        if as_header or path.suffix.lower() in SOURCE | HEADERS:
            # Preprocessing splices lines and removes comments before includes.
            directives = re.sub(r"\\\r?\n", "", header)
            directives = re.sub(r'/\*.*?\*/|("(?:\\.|[^"\\\n])*")|(//[^\n]*)',
                                lambda m: m[1] or " ", directives, flags=re.S)
            for include in re.findall(r'(?m)^[ \t]*#[ \t]*(?:include|import)[ \t]*"([^"\n]+)"', directives):
                self.header(path.parent / include, package)
        sidecar = Path(str(path) + ".license")
        if package in self.local_packages and sidecar in self.changed_files:
            self.check_local_input(package, sidecar)
        if sidecar.is_symlink():
            raise ValueError(f"unresolved license symlink for {rel}")
        evidence = {}
        component = boundary.relative_to(self.root) if boundary != self.root else rel
        directory = path.parent
        while directory != self.root and directory.is_relative_to(boundary):
            notices = self.notices(package, directory)
            for notice, ids in notices.items():
                self.check_local_input(package, notice)
                if NOTICE.fullmatch(notice.name):
                    self.row(directory.relative_to(self.root), notice.relative_to(self.root), ids)
            if not evidence:
                evidence = {p: ids for p, ids in notices.items() if not NOTICE.fullmatch(p.name)}
                if evidence:
                    component = directory.relative_to(self.root)
            directory = directory.parent
        # List each bundled model/binary even when several share one LICENSE.
        bundles = {".xcframework", ".framework", ".mlmodelc", ".mlpackage", ".bundle", ".artifactbundle"}
        bundle = next((p for p in reversed(rel.parents) if p.suffix in bundles), None)
        if sidecar.is_file():
            self.check_local_input(package, sidecar)
            self.row(rel, sidecar.relative_to(self.root), license_ids(read_text(sidecar)))
        elif bundle or path.suffix.lower() not in SOURCE | HEADERS:
            component = bundle or rel
        for notice, licenses in evidence.items():
            self.row(component, notice.relative_to(self.root), licenses)
        claims = re.findall(r"(?im)^\s*[/ *]+(?:copyright\b|SPDX-FileCopyrightText:)(.*)$", header)
        owned = boundary == self.root and rel.parts[0] in {"Apps", "Sources", "Tests"}
        hs_copyright = claims and all(re.fullmatch(
            r"\s*(?:\(c\)|©)?[\d ,–-]*(?:Mick Darling|Hailing Station)[. */]*", c, re.I) for c in claims)
        declared = file_declarations(header, path.suffix.lower())
        if declared and not (owned and hs_copyright and declared == {"AGPL-3.0-or-later"}):
            self.row(component, rel, declared)
        if sidecar.is_file() or evidence or declared:
            return
        if base == self.root and hs_copyright:
            return
        # HS owns ordinary Swift sources, plists and asset-catalog artwork in
        # Apps/, Sources/ and Tests/. A vendor subtree, separate license/header,
        # native input, binary or model requires its own evidence even there.
        if owned:
            if path.suffix in {".swift", ".plist", ".entitlements"} and not claims:
                return
            if any(p.endswith(".xcassets") for p in rel.parts) and (path.name == "Contents.json" or
                    (path.suffix == ".png" and path.parent.suffix in {".imageset", ".appiconset"})):
                return
        self.row(rel, rel, {"UNKNOWN"})

    def scan(self, path, package, excludes=(), suffixes=None):
        path = self.path(path)
        if not path.exists():
            raise ValueError(f"missing mobile input {path.relative_to(self.root)}")
        excluded = {path / item for item in excludes}
        pending = [(path, suffixes)]
        while pending:
            file, selected = pending.pop()
            if file in excluded:
                continue
            if file.is_symlink():
                raise ValueError(f"unresolved ownership of symlink {file.relative_to(self.root)}")
            if file.is_dir():
                if file.suffix == ".xcframework":
                    with self.path(file / "Info.plist").open("rb") as info:
                        slices = plistlib.load(info)["AvailableLibraries"]
                    mobile_slices = [s for s in slices if s["SupportedPlatform"] == "ios"
                                     and s.get("SupportedPlatformVariant") in (None, "simulator")]
                    if not mobile_slices:
                        raise ValueError(f"missing mobile binary slice in {file}")
                    for item in mobile_slices:
                        library = self.path(file / item["LibraryIdentifier"] / item["LibraryPath"])
                        library.relative_to(file)
                        if library.suffix == ".framework":
                            library = self.path(library / library.stem)
                        if not library.is_file():
                            raise ValueError(f"missing mobile binary {library}")
                    excluded.update(file / s["LibraryIdentifier"] for s in slices if s not in mobile_slices)
                if selected is not None and file.suffix.lower() in selected:
                    selected = None  # Resource directories ship their contents as a unit.
                pending.extend((p, selected) for p in file.iterdir() if selected is None or not p.name.startswith("."))
                continue
            if selected is not None and file.suffix.lower() not in selected:
                continue
            if GRANT.fullmatch(file.name) or NOTICE.fullmatch(file.name):
                self.check_local_input(package, file)
                self.row(file.parent.relative_to(self.root), file.relative_to(self.root), license_ids(read_text(file)))
            elif not file.name.endswith(".license"):
                self.scan_file(file, package)

    def checkout(self, url):
        name = identity(url)
        pin = self.pins.get(name, {})
        revision = pin.get("state", {}).get("revision")
        location = pin.get("location") or pin.get("repositoryURL") or ""
        if not revision or location.rstrip("/").removesuffix(".git") != url.rstrip("/").removesuffix(".git"):
            raise ValueError(f"missing matching Package.resolved pin for {url}")
        for candidate in (self.build / "checkouts").glob("*"):
            if identity(candidate.name) == name:
                candidate = self.path(candidate)
                repo, head = subprocess.check_output(["git", "rev-parse", "--show-toplevel", "HEAD"],
                                                     cwd=candidate, text=True).splitlines()
                if Path(repo).resolve() == candidate and head == revision:
                    changes = subprocess.check_output(["git", "--no-optional-locks", "status", "--porcelain"],
                                                      cwd=candidate)
                    if changes:
                        raise ValueError(f"modified checkout of {name} at {revision}")
                    return candidate
        raise ValueError(f"missing checkout of {name} at {revision} in the build's checkouts")

    def product(self, package, name, *, local):
        package = self.path(package)
        if local and package not in self.local_packages:
            self.local_packages.add(package)
            for file in [package / "Package.swift", *package.glob("Package@swift-*.swift")]:
                self.check_local_input(package, self.path(file))
        for notice, licenses in self.notices(package, package).items():
            if package != self.root or NOTICE.fullmatch(notice.name):
                self.check_local_input(package, notice)
                self.row(package.relative_to(self.root), notice.relative_to(self.root), licenses)
        data = manifest(package)
        product = next((p for p in data["products"] if p["name"] == name), None)
        if not product:
            raise ValueError(f"unknown product {name} in {data['name']}")
        for target in product["targets"]:
            self.package_target(package, target)

    def binary_artifact(self, package, target):
        name = target["name"]
        state = self.path(self.build / "workspace-state.json")
        if state.is_file():
            matches = [entry for entry in json.loads(state.read_text())["object"]["artifacts"]
                       if entry["packageRef"]["identity"] == identity(package.name) and entry["targetName"] == name
                       and entry["source"]["type"] == "remote" and entry["source"]["url"] == target["url"]
                       and entry["source"]["checksum"] == target["checksum"]]
            if len(matches) == 1:
                artifact = self.path(Path(matches[0]["path"]))
                artifact.relative_to(self.build / "artifacts")
                if artifact.is_dir() and artifact.suffix.lower() == ".xcframework":
                    return artifact
        raise ValueError(f"missing or unsupported selected binary artifact {name} in the Xcode workspace state")

    def package_target(self, package, name):
        if (package, name) in self.package_targets:
            return
        self.package_targets.add((package, name))
        data = manifest(package)
        targets = {t["name"]: t for t in data["targets"]}
        target = targets[name]
        if target["type"] == "binary":
            if "path" in target:
                artifact = self.path(package / target["path"])
                if not artifact.is_dir() or artifact.suffix.lower() != ".xcframework":
                    raise ValueError(f"missing or unsupported selected binary artifact {name}: {artifact}")
                self.scan(artifact, package)
            else:
                artifact = self.binary_artifact(package, target)
                self.scan(artifact, artifact)
            return
        if target.get("pluginUsages") or target["type"] == "plugin":
            raise ValueError(f"{name}: cannot inventory plugin-generated inputs")
        if target["type"] not in {"regular", "executable"}:
            raise ValueError(f"unsupported mobile package target {name} ({target['type']})")
        files = package_files(package)[name]
        base = self.path(package / files["path"])
        if package in self.local_packages:
            excludes = [base / item for item in target.get("exclude", [])]
            for path in self.changed_files:
                if path.is_relative_to(base) and not any(path.is_relative_to(p) for p in excludes):
                    self.check_local_input(package, path)
        for setting in target.get("settings", []):
            platforms = (setting.get("condition") or {}).get("platformNames")
            if platforms and not mobile(platforms):
                continue
            kind = setting["kind"]
            if "unsafeFlags" in kind:
                check_flags(kind["unsafeFlags"]["_0"], f"{name} unsafe flags")
            if "headerSearchPath" in kind:
                self.scan(base / kind["headerSearchPath"]["_0"], package, suffixes=HEADERS)
        for source in files.get("sources", []):
            self.scan(base / source, package)
        # Native SwiftPM describe omits Xcode's implicit resource rules and
        # Clang headers. Restrict the extra walk to this selected target.
        implicit = IMPLICIT | HEADERS if files["module_type"] == "ClangTarget" else IMPLICIT
        self.scan(base, package, target.get("exclude", []), suffixes=implicit)
        for resource in files.get("resources", []):
            self.scan(base / resource["path"], package)
        declarations = {}
        for dependency in data["dependencies"]:
            kind, (ref,) = next(iter(dependency.items()))
            declarations[(ref.get("nameForTargetDependencyResolutionOnly") or ref["identity"]).lower()] = kind, ref
        for dependency in target["dependencies"]:
            kind, args = next(iter(dependency.items()))
            item = args[0]
            condition = args[-1] or {}
            if condition.get("platformNames") and not mobile(condition["platformNames"]):
                continue
            if kind in {"byName", "target"} and item in targets:
                self.package_target(package, item)
                continue
            if kind not in {"product", "byName"}:
                raise ValueError(f"unsupported SwiftPM dependency {dependency}")
            kind, ref = declarations[(args[1] if kind == "product" else item).lower()]
            if kind == "fileSystem":
                source = Path(ref["path"])
            elif kind == "sourceControl":
                source = self.checkout(ref["location"]["remote"][0]["urlString"])
            else:
                raise ValueError(f"unsupported SwiftPM package {ref['identity']} ({kind})")
            self.product(source, item, local=kind == "fileSystem")

    def collect(self):
        # parsed-json resolves platforms and templates, but omits the product
        # names on package edges. The actual XcodeGen build phases retain them
        # and implement source globs, exclusions, linking and embedding.
        expanded = command_json("xcodegen", "dump", "--type", "parsed-json", cwd=self.root)
        targets = expanded["targets"]
        roots = sorted(name for name, t in targets.items()
                       if mobile(t.get("supportedDestinations") or t.get("platform", []))
                       and t["type"].split(".")[0] in {"application", "app-extension", "extensionkit-extension"})
        if not roots:
            raise ValueError("no mobile application or app-extension targets in project.yml")
        # SOURCE_ROOT in framework references is the directory containing the
        # xcodeproj. Put a uniquely named temporary project beside project.yml.
        with tempfile.TemporaryDirectory(prefix=".license-audit-", suffix=".xcodeproj", dir=self.root) as tmp:
            graph = self.build_phases(Path(tmp))
            self.inspect_phases(graph, targets, roots)
        return roots

    def build_phases(self, directory):
        # Generate only a disposable pbxproj. Info and entitlement declarations
        # normally write plists into the checkout. Neither defines a dependency.
        spec = self.spec.copy()
        spec["name"] = directory.stem
        spec.pop("include", None)  # dump already resolved included specs
        if any(spec.get("options", {}).get(key) for key in ("preGenCommand", "postGenCommand")):
            raise ValueError("custom project generation commands require an inventory of their outputs")
        for key in ("targets", "targetTemplates"):
            spec[key] = {name: {k: v for k, v in t.items() if k.split(":")[0] not in {"info", "entitlements"}}
                         for name, t in spec.get(key, {}).items()}
        spec_file = directory / "audit.json"
        spec_file.write_text(json.dumps(spec))
        subprocess.run(["xcodegen", "generate", "--quiet", "--spec", spec_file, "--project-root", self.root,
                        "--project", self.root], check=True)
        return command_json("plutil", "-convert", "json", "-o", "-", directory / "project.pbxproj", cwd=self.root)

    def xcode_product(self, product, packages, objects):
        if "package" in product:
            package = self.checkout(objects[product["package"]]["repositoryURL"])
        else:
            # XcodeGen omits the package reference for local products. Only
            # inspect local packages declared by this target.
            candidates = {self.path(self.root / p["path"]) for p in packages if "path" in p}
            matches = [p for p in candidates if any(v["name"] == product["productName"] for v in manifest(p)["products"])]
            if len(matches) != 1:
                raise ValueError(f"cannot resolve local product {product['productName']}")
            package = matches[0]
        self.product(package, product["productName"], local="package" not in product)

    def inspect_phases(self, graph, targets, roots):
        objects = graph["objects"]
        project = objects[graph["rootObject"]]
        by_name = {objects[i]["name"]: objects[i] for i in project["targets"]}
        built = {t["productReference"]: n for n, t in by_name.items() if "productReference" in t}
        parents = {child: key for key, obj in objects.items() for child in obj.get("children", [])}

        def source_path(key):
            ref = objects[key]
            tree = ref["sourceTree"]
            if tree == "<group>" and key in parents:
                return source_path(parents[key]) / ref.get("path", "")
            if tree in {"SOURCE_ROOT", "<group>", "<absolute>"}:
                return self.root / ref.get("path", "")
            raise ValueError(f"unsupported Xcode source tree {tree}")

        def visit_file(key):
            ref = objects[key]
            if ref["isa"] == "PBXVariantGroup":
                for child in ref["children"]:
                    visit_file(child)
            elif ref["isa"] == "PBXFileReference" and ref["sourceTree"] != "SDKROOT":
                self.scan(source_path(key), None)
            elif ref["sourceTree"] != "SDKROOT":
                raise ValueError(f"unsupported Xcode file reference {ref}")

        pending = list(roots)
        while pending:
            name = pending.pop()
            if name in self.targets:
                continue
            self.targets.add(name)
            target = by_name[name]
            packages = [self.spec["packages"][d["package"]] for d in targets[name]["dependencies"] if d.get("package")]
            if targets[name].get("buildToolPlugins") or any("productRef" in objects[dep]
                                                           for dep in target.get("dependencies", [])):
                raise ValueError(f"{name}: cannot inventory build-tool plugin outputs")
            if target.get("buildRules") or target.get("fileSystemSynchronizedGroups"):
                raise ValueError(f"{name}: custom build rules or synchronized groups require input inspection")
            for owner in (project, target):
                configs = objects[owner["buildConfigurationList"]]["buildConfigurations"]
                for config in map(objects.__getitem__, configs):
                    if config.get("baseConfigurationReference"):
                        raise ValueError(f"{name}: cannot inventory inputs from xcconfig")
                    for key, value in config["buildSettings"].items():
                        setting = key.split("[")[0]
                        if setting in {"SWIFT_OBJC_BRIDGING_HEADER", "GCC_PREFIX_HEADER"} and value:
                            if value in ("$(inherited)", "${inherited}"):
                                continue  # The project settings are also visited.
                            value = re.sub(r"\$\((?:SRCROOT|SOURCE_ROOT|PROJECT_DIR)\)|"
                                           r"\$\{(?:SRCROOT|SOURCE_ROOT|PROJECT_DIR)\}", str(self.root), value)
                            if "$" in value:
                                raise ValueError(f"{name}: unresolved {key}: {value}")
                            self.header(self.root / value, None)
                        if setting in {"OTHER_LDFLAGS", "LIBRARY_SEARCH_PATHS", "OTHER_CFLAGS",
                                       "OTHER_CPLUSPLUSFLAGS", "OTHER_SWIFT_FLAGS", "HEADER_SEARCH_PATHS",
                                       "USER_HEADER_SEARCH_PATHS", "SWIFT_INCLUDE_PATHS"}:
                            check_flags(value, f"{name} {key}")
            for phase_id in target["buildPhases"]:
                phase = objects[phase_id]
                if phase["isa"] == "PBXShellScriptBuildPhase":
                    raise ValueError(f"{name}: cannot inventory outputs of {phase.get('name', 'script phase')}")
                for build_id in phase["files"]:
                    item = objects[build_id]
                    filters = item.get("platformFilters") or item.get("platformFilter")
                    if filters and not mobile(filters):
                        continue
                    if item.get("settings", {}).get("COMPILER_FLAGS"):
                        check_flags(item["settings"]["COMPILER_FLAGS"], f"{name} per-file compiler flags")
                    if "productRef" in item:
                        self.xcode_product(objects[item["productRef"]], packages, objects)
                    elif item["fileRef"] in built:
                        pending.append(built[item["fileRef"]])
                    else:
                        visit_file(item["fileRef"])


def read_exceptions(path):
    exceptions = {}
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = [value.strip() for value in line.split("\t")]
        if len(fields) < 3 or not all(fields):
            raise ValueError(f"invalid license exception: {line!r}")
        component, license_id, *binding, reason = fields
        if license_id == "UNKNOWN":
            if len(binding) != 1 or not re.fullmatch(r"sha256:[a-f0-9]{64}", binding[0]):
                raise ValueError(f"UNKNOWN exception for {component} requires a sha256 file digest")
        elif binding:
            raise ValueError(f"unexpected digest for {component}: {license_id}")
        exceptions[component, license_id] = (binding[0] if binding else None, reason)
    return exceptions


def license_status(inventory, component, origin, license_id, exceptions):
    if permitted(license_id):
        return "PASS"
    exception = exceptions.get((component, license_id))
    if not exception or gnu_ids(license_id):
        return "FAIL"
    binding, reason = exception
    if binding:
        # Only a concrete input with no grant qualifies. Ambiguous component
        # notices need resolved terms for the files they cover.
        if component != origin:
            return "FAIL"
        digest = hashlib.sha256()
        with inventory.path(inventory.root / origin).open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        if binding != "sha256:" + digest.hexdigest():
            return "FAIL"
    return "EXCEPTION: " + reason


def audit(root):
    spec = command_json("xcodegen", "dump", "--type", "json", cwd=root)
    inventory = Inventory(root, spec)
    roots = inventory.collect()
    exceptions = read_exceptions(root / "scripts/license-allowlist.txt")
    print("Mobile targets: " + ", ".join(roots))
    print("Dependency\tOrigin\tSPDX\tStatus")
    passed = True
    for component, origin, license_id in sorted(inventory.rows):
        status = license_status(inventory, component, origin, license_id, exceptions)
        if status == "FAIL":
            passed = False
        print(component, origin, license_id, status, sep="\t")
    if not inventory.rows:
        print("(no third-party dependencies)")
    return passed


if __name__ == "__main__":
    try:
        sys.exit(0 if audit(Path(__file__).resolve().parents[1]) else 1)
    except (ValueError, KeyError, OSError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        sys.exit(f"Mobile license inventory failed: {error}")
