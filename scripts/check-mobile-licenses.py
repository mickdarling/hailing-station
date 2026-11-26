#!/usr/bin/env python3
"""Inventory the third-party inputs to the iOS/iPadOS products (#1391).

Use the project's XcodeGen and SwiftPM tools for YAML and Swift manifests.
Read remote packages from the build's pinned checkouts. Never fetch a license
from a default branch, or infer membership from the mere presence of a pin.
"""
from __future__ import annotations

import hashlib
import json
import plistlib
import re
import shlex
import subprocess
import sys
import tempfile
from functools import lru_cache
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
SPDX = re.compile(r"(?im)^\s*(?:[/#*;!<-]+\s*)?SPDX-License-Identifier:\s*([^\r\n]+)")
NOTICE = re.compile(r"(?:licen[sc]e|copying)(?:[._-].*)?$", re.I)
SOURCE = {".swift", ".h", ".hpp", ".c", ".cc", ".cpp", ".cxx", ".m", ".mm", ".s", ".metal", ".modulemap"}
HEADERS = {".h", ".hh", ".hpp", ".hxx", ".inc", ".inl", ".modulemap"}
VENDOR = {"native", "vendor", "vendors", "vendored", "thirdparty", "external", "externals"}


def normalize(text):
    text = re.sub(r"(?i)\A(?:\s*(?:copyright\s+(?:\(c\)\s*)?(?:<year>|\d{4})[^\n]*|all rights reserved\.|"
                  r"(?:the )?(?:mit|isc|zlib|bsd[ -][23][ -]clause) license\.?)\s*\n)+", "", text)
    text = re.sub(r"(?m)^\s*(?:\d+\.|\*)\s+", "", text)
    text = " ".join(text.lower().split()).replace("https://www.apache.org/", "http://www.apache.org/")
    # BSD-3-Clause allows the author's name in its endorsement clause.
    return re.sub(r"neither the name of [\w .,'&-]{1,100} nor the names of its contributors may be used",
                  "neither the name of the copyright holder nor the names of its contributors may be used", text)


def license_ids(text):
    ids = {s.strip().removesuffix("*/").removesuffix("-->").strip() for s in SPDX.findall(text)}
    # Bare SPDX identifiers in LICENSE/COPYING and the GNU family titles in full license texts.
    if re.fullmatch(r"[\w.+-]+", text.strip()):
        ids.add(text.strip())
    # Preserve the family even in a short notice with no formal SPDX header.
    for family, version in re.findall(r"GNU (AFFERO |LESSER |LIBRARY )?GENERAL PUBLIC LICENSE"
                                      r"(?:[,\s]+Version (\d+(?:\.\d+)?))?", text, re.I):
        prefix = {"affero": "AGPL", "lesser": "LGPL", "library": "LGPL"}.get(family.lower().strip(), "GPL")
        if version and "." not in version:
            version += ".0"
        ids.add(f"{prefix}-{version}" if version else prefix)
    if not any(COPYLEFT.search(value) for value in ids):
        ids.update(re.findall(r"\b(?:A|L)?GPL\b(?:[- v]?\d+(?:\.\d+)?(?:-only|-or-later|\+)?)?"
                              r"|\b(?:A|L)?GPLv?\d+(?:\.\d+)?", text, re.I))
    if ids:
        return ids
    for name in LICENSE_TEXT:
        if text.strip().lower() == f"{name.lower()} license":
            return {name}
    digest = hashlib.sha256(normalize(text).encode()).hexdigest()
    return {next((name for name, expected in LICENSE_TEXT.items() if digest == expected), "UNKNOWN")}


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
        if NOTICE.fullmatch(file.name) and file.is_file():
            if file.is_symlink():
                raise ValueError(f"unresolved license symlink {file}")
            evidence[file] = license_ids(file.read_text(errors="replace"))
    metadata = directory / "package.json"
    if metadata.is_file():
        if metadata.is_symlink():
            raise ValueError(f"unresolved metadata symlink {metadata}")
        value = json.loads(metadata.read_text()).get("license")
        if value is not None:
            evidence[metadata] = {value if isinstance(value, str) and value.strip() else "UNKNOWN"}
    return evidence


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
        self.build = root / ".build/mobile-packages"
        xcode_lock = root / (spec["name"] + ".xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        lock = xcode_lock if xcode_lock.exists() else root / "Package.resolved"
        pins = json.loads(lock.read_text()) if lock.exists() else {}
        self.pins = {identity(p.get("identity") or p["repositoryURL"]): p
                     for p in pins.get("object", pins).get("pins", [])}

    def path(self, path):
        path = path.resolve()
        path.relative_to(self.root)  # All license evidence must come from this tree.
        return path

    def row(self, component, origin, licenses):
        for license_id in licenses:
            self.rows.add((str(component), str(origin), license_id))

    def scan_file(self, path, package):
        rel = path.relative_to(self.root)
        scope = path.relative_to(package)
        boundary = package
        for i, part in enumerate(scope.parts[:-1]):
            marker = re.sub(r"[-_ ]", "", part.lower())
            if marker in VENDOR and (marker != "native" or package == self.root):
                boundary = package.joinpath(*scope.parts[:min(i + 2, len(scope.parts) - 1)])
        header = ""
        if path.suffix.lower() in SOURCE | HEADERS:
            header = path.read_text(errors="replace")
        sidecar = Path(str(path) + ".license")
        if sidecar.is_symlink():
            raise ValueError(f"unresolved license symlink for {rel}")
        evidence = {}
        directory = path.parent
        while directory != self.root and directory.is_relative_to(boundary):
            evidence = directory_licenses(directory)
            if evidence or directory == boundary:
                break
            directory = directory.parent
        if evidence:
            component = directory.relative_to(self.root)
        elif boundary != self.root:
            component = boundary.relative_to(self.root)
        else:
            component = rel
        # List each bundled model/binary even when several share one LICENSE.
        bundles = {".xcframework", ".framework", ".mlmodelc", ".mlpackage", ".bundle", ".artifactbundle"}
        bundle = next((p for p in reversed(rel.parents) if p.suffix in bundles), None)
        if bundle or path.suffix.lower() not in SOURCE | HEADERS:
            component = bundle or rel
        if sidecar.is_file():
            self.row(rel, sidecar.relative_to(self.root), license_ids(sidecar.read_text()))
            # The sidecar licenses the file. Attribute the enclosing terms to
            # the containing dependency.
            component = directory.relative_to(self.root)
        for notice, licenses in evidence.items():
            self.row(component, notice.relative_to(self.root), licenses)
        claims = re.findall(r"(?im)^\s*[/ *]+(?:copyright\b|SPDX-FileCopyrightText:)(.*)$", header)
        owned = boundary == self.root and rel.parts[0] in {"Apps", "Sources", "Tests"}
        hs_copyright = claims and all(re.fullmatch(
            r"\s*(?:\(c\)|©)?[\d ,–-]*(?:Mick Darling|Hailing Station)[. */]*", c, re.I) for c in claims)
        declared = SPDX.search(header) or re.search(
            r"(?im)^\s*[/ *]+.*(?:GNU (?:Affero |Lesser |Library )?General Public License|\b[AL]?GPL[- v]?\d)", header)
        if declared and not (package == self.root and hs_copyright):
            self.row(component, rel, license_ids(header))
        if sidecar.is_file() or evidence or declared:
            return
        if package == self.root and hs_copyright:
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
        self.row(component, rel, {"UNKNOWN"})

    def scan(self, path, package, excludes=(), headers_only=False):
        path = self.path(path)
        if not path.exists():
            raise ValueError(f"missing mobile input {path.relative_to(self.root)}")
        excluded = {path / item for item in excludes}
        pending = [path]
        while pending:
            file = pending.pop()
            if file in excluded:
                continue
            if file.is_symlink():
                raise ValueError(f"unresolved ownership of symlink {file.relative_to(self.root)}")
            if file.is_dir():
                if file.suffix == ".xcframework":
                    with (file / "Info.plist").open("rb") as info:
                        slices = plistlib.load(info)["AvailableLibraries"]
                    excluded.update(file / s["LibraryIdentifier"] for s in slices if s["SupportedPlatform"] != "ios"
                                    or s.get("SupportedPlatformVariant") not in (None, "simulator"))
                pending.extend(file.iterdir())
                continue
            if NOTICE.fullmatch(file.name) or file.name.endswith(".license"):
                continue
            if not headers_only or file.suffix.lower() in HEADERS:
                self.scan_file(file, package)

    def checkout(self, url):
        name = identity(url)
        pin = self.pins.get(name, {})
        revision = pin.get("state", {}).get("revision")
        location = pin.get("location") or pin.get("repositoryURL") or ""
        if not revision or location.rstrip("/").removesuffix(".git") != url.rstrip("/").removesuffix(".git"):
            raise ValueError(f"missing matching Package.resolved pin for {url}")
        for base in (self.build, self.root / ".build"):
            for candidate in (base / "checkouts").glob("*"):
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

    def product(self, package, name):
        package = self.path(package)
        if package != self.root:
            for notice, licenses in directory_licenses(package).items():
                self.row(package.relative_to(self.root), notice.relative_to(self.root), licenses)
        data = manifest(package)
        product = next((p for p in data["products"] if p["name"] == name), None)
        if not product:
            raise ValueError(f"unknown product {name} in {data['name']}")
        for target in product["targets"]:
            self.package_target(package, target)

    def package_target(self, package, name):
        if (package, name) in self.package_targets:
            return
        self.package_targets.add((package, name))
        data = manifest(package)
        targets = {t["name"]: t for t in data["targets"]}
        target = targets[name]
        if target["type"] == "binary":
            if "path" in target:
                self.scan(package / target["path"], package)
            else:
                artifact = self.build / "artifacts" / package.name.lower() / name
                if not artifact.is_dir():
                    self.row(f"{package.relative_to(self.root)}/{name}@{target['checksum']}", target["url"], {"UNKNOWN"})
                else:
                    self.scan(artifact, artifact)
            return
        if target["type"] not in {"regular", "executable"}:
            raise ValueError(f"unsupported mobile package target {name} ({target['type']})")
        if target.get("pluginUsages"):
            raise ValueError(f"{name}: cannot inventory plugin-generated inputs")
        files = package_files(package)[name]
        base = self.path(package / files["path"])
        for setting in target.get("settings", []):
            platforms = (setting.get("condition") or {}).get("platformNames")
            if platforms and not mobile(platforms):
                continue
            kind = setting["kind"]
            if "unsafeFlags" in kind:
                check_flags(kind["unsafeFlags"]["_0"], f"{name} unsafe flags")
            if "headerSearchPath" in kind:
                self.scan(base / kind["headerSearchPath"]["_0"], package, headers_only=True)
        for source in files.get("sources", []):
            self.scan(base / source, package)
        # SwiftPM's sources list omits C/C++ headers. A vendored header can
        # contribute compiled code even if the translation unit is first-party.
        if files["module_type"] == "ClangTarget":
            self.scan(base, package, target.get("exclude", []), headers_only=True)
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
            self.product(source, item)

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
        self.product(package, product["productName"])

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
                self.scan(source_path(key), self.root)
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
            if target.get("buildRules") or target.get("fileSystemSynchronizedGroups"):
                raise ValueError(f"{name}: custom build rules or synchronized groups require input inspection")
            for owner in (project, target):
                configs = objects[owner["buildConfigurationList"]]["buildConfigurations"]
                for config in map(objects.__getitem__, configs):
                    if config.get("baseConfigurationReference"):
                        raise ValueError(f"{name}: cannot inventory inputs from xcconfig")
                    for key, value in config["buildSettings"].items():
                        if key.split("[")[0] in {"OTHER_LDFLAGS", "LIBRARY_SEARCH_PATHS", "OTHER_CFLAGS",
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


def audit(root):
    spec = command_json("xcodegen", "dump", "--type", "json", cwd=root)
    inventory = Inventory(root, spec)
    roots = inventory.collect()
    exceptions = {}
    for line in (root / "scripts/license-allowlist.txt").read_text().splitlines():
        if line.strip() and not line.lstrip().startswith("#"):
            component, license_id, reason = (value.strip() for value in line.split("\t"))
            if not all((component, license_id, reason)):
                raise ValueError(f"invalid license exception: {line!r}")
            exceptions[component, license_id] = reason
    print("Mobile targets: " + ", ".join(roots))
    print("Dependency\tOrigin\tSPDX\tStatus")
    passed = True
    for component, origin, license_id in sorted(inventory.rows):
        if permitted(license_id):
            status = "PASS"
        elif (component, license_id) in exceptions and not COPYLEFT.search(license_id):
            status = "EXCEPTION: " + exceptions[component, license_id]
        else:
            status = "FAIL"
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
