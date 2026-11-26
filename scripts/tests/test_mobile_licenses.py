"""Mobile license policy and graph selection (#1391). Only temporary inputs are audited."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "check-mobile-licenses.py"
spec = importlib.util.spec_from_file_location("mobile_licenses", SCRIPT)
licenses = importlib.util.module_from_spec(spec)
spec.loader.exec_module(licenses)


class MobileLicensesTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.app = {"type": "application", "platform": "iOS", "sources": ["Apps/Phone"]}
        self.targets = {"Phone": self.app}
        self.project = {"name": "Radio", "targets": self.targets}
        self.write("Apps/Phone/App.swift", "import Foundation")
        self.write("scripts/license-allowlist.txt", "# no exceptions\n")
        self.write("LICENSE", "AGPL-3.0-or-later")  # HS's own license
        # Invoke the same executable used by CI, relative to this project's manifests.
        self.write("scripts/check-mobile-licenses.py", SCRIPT.read_text())

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def run_cli(self, expected):
        self.write("project.yml", json.dumps(self.project))
        result = subprocess.run([sys.executable, self.root / "scripts/check-mobile-licenses.py"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout

    def test_copyleft_can_never_be_excepted(self):
        for spdx in ("GPL-2.0-only", "LGPL-2.1-or-later", "AGPL-3.0-or-later"):
            with self.subTest(spdx=spdx):
                self.write("Native/Radio/COPYING", spdx)
                self.write("Native/Radio/radio.mm", "// vendored")
                self.app["sources"] = ["Native/Radio"]
                self.write("scripts/license-allowlist.txt", f"Native/Radio\t{spdx}\tRequested exception\n")
                self.assertIn(f"Native/Radio\tNative/Radio/COPYING\t{spdx}\tFAIL", self.run_cli(1))

    def test_unknown_model_needs_its_own_reasoned_exception(self):
        self.write("Apps/Phone/weights.gguf", "synthetic weights")
        row = "Apps/Phone/weights.gguf\tApps/Phone/weights.gguf\tUNKNOWN\t"
        self.assertIn(row + "FAIL", self.run_cli(1))
        self.write("scripts/license-allowlist.txt", "Apps/Phone/weights.gguf\tUNKNOWN\tRedistribution grant on file\n")
        self.assertIn(row + "EXCEPTION: Redistribution grant on file", self.run_cli(0))
        self.write("Apps/Phone/weights.gguf.license", "SPDX-License-Identifier: LGPL-3.0-only")
        self.assertIn("LGPL-3.0-only\tFAIL", self.run_cli(1))

    def test_extension_transitive_framework_and_native_sources(self):
        self.targets.update({
            "Share": {"platform": "iOS", "type": "app-extension", "dependencies": [{"target": "Bridge"}]},
            "Bridge": {"platform": "iOS", "type": "framework", "sources": ["Native/DSP"],
                       "dependencies": [{"framework": "Vendor/Codec.framework"}]},
            "Desktop": {"platform": "macOS", "type": "application", "sources": ["DesktopOnly"]},
            "Checks": {"platform": "iOS", "type": "bundle.unit-test", "sources": ["DesktopOnly"]},
        })
        self.write("DesktopOnly/COPYING", "GPL-2.0-only")
        self.write("DesktopOnly/host.c", "unused")
        self.write("Native/DSP/dsp.c", "/* SPDX-License-Identifier: MIT */")
        self.write("Vendor/Codec.framework/Codec", "synthetic library")
        self.write("Vendor/Codec.framework/LICENSE.txt", "Apache-2.0")
        out = self.run_cli(0)
        self.assertIn("Phone, Share", out)
        self.assertIn("Native/DSP/dsp.c\tMIT\tPASS", out)
        self.assertIn("Codec.framework/LICENSE.txt\tApache-2.0\tPASS", out)
        self.assertNotIn("DesktopOnly", out)

    def test_xcodegen_templates_and_excluded_sources(self):
        self.project["targetTemplates"] = {"Share": {"type": "app-extension.intents-service", "platform": "iOS",
                                                     "sources": [{"path": "Native", "excludes": ["Desktop"]}]}}
        self.targets["Intents"] = {"templates": ["Share"]}
        for name, spdx in (("Shared", "ISC"), ("Desktop", "GPL-3.0-only")):
            self.write(f"Native/{name}/tool.c", f"// SPDX-License-Identifier: {spdx}")
        out = self.run_cli(0)
        self.assertIn("Intents, Phone", out)
        self.assertIn("Native/Shared/tool.c\tISC\tPASS", out)
        self.assertNotIn("Desktop", out)

    def test_xcframework_inventories_only_mobile_slices(self):
        library = "Vendor/Shapes.xcframework"
        self.app["dependencies"] = [{"framework": library}]
        slices = []
        for platform, spdx in (("ios", "BSD-2-Clause"), ("macos", "GPL-2.0-only")):
            slice_id = f"{platform}-arm64"
            slices.append({"LibraryIdentifier": slice_id, "LibraryPath": "libShapes.a",
                           "SupportedArchitectures": ["arm64"], "SupportedPlatform": platform})
            self.write(f"{library}/{slice_id}/libShapes.a", "synthetic archive")
            self.write(f"{library}/{slice_id}/LICENSE", spdx)
        self.write(f"{library}/LICENSE", "MIT")
        self.write(f"{library}/Info.plist", plistlib.dumps({"AvailableLibraries": slices}).decode())
        out = self.run_cli(0)
        self.assertIn("ios-arm64/LICENSE\tBSD-2-Clause\tPASS", out)
        self.assertNotIn("macos-arm64", out)

    def test_local_product_reaches_only_ios_dependencies_and_pinned_checkout(self):
        url = "https://example.invalid/codec.git"
        remote = ".build/mobile-packages/checkouts/codec"
        self.project["packages"] = {"AppKit": {"path": "."}}
        self.app["dependencies"] = [{"package": "AppKit", "products": ["Terminal"]}]
        self.write("project.yml", json.dumps(self.project))
        self.write("Sources/Frontend/main.swift", "import Codec")
        self.write(f"{remote}/LICENSE", "MIT")
        self.write(f"{remote}/Sources/Native/codec.c", "int codec(void);")
        self.write(f"{remote}/Sources/Native/model.bin", "fixture")
        self.write(f"{remote}/Sources/Native/model.bin.license", "LGPL-2.1-or-later")
        checkout = self.root / remote
        subprocess.run(["git", "init", "-q"], cwd=checkout, check=True)
        subprocess.run(["git", "add", "."], cwd=checkout, check=True)
        subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=test@example.invalid",
                        "-c", "commit.gpgSign=false", "commit", "-qm", "Fixture"], cwd=checkout, check=True)
        revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=checkout, text=True).strip()
        self.write("Package.resolved", json.dumps({"pins": [
            {"identity": "codec", "location": url, "state": {"revision": revision}},
            {"identity": "host", "location": "unused", "state": {"revision": "unused"}}]}))

        def target(name, dependencies=(), resources=()):
            return {"name": name, "type": "regular", "dependencies": dependencies, "resources": resources}

        # Actual dump-package / describe data shapes. Keep the fixture offline
        # while exercising selection, revision verification and file discovery.
        manifests = {
            self.root: {
                "name": "AppKit", "products": [{"name": "Terminal", "targets": ["Frontend"]}],
                "targets": [target("Frontend", [{"byName": ["Shared", None]}]),
                            target("Shared", [{"product": ["Mobile", "codec", None, {"platformNames": ["ios"]}]},
                                              {"product": ["Host", "host", None, {"platformNames": ["macos"]}]}])],
                "dependencies": [{"sourceControl": [
                    {"identity": "codec", "location": {"remote": [{"urlString": url}]}}]}]},
            self.root / remote: {
                "name": "Codec", "products": [{"name": "Mobile", "targets": ["Native"]}],
                "targets": [target("Native", resources=[{"path": "model.bin"}])], "dependencies": []},
        }
        files = {
            self.root: {"Frontend": {"path": "Sources/Frontend", "module_type": "SwiftTarget", "sources": ["main.swift"]},
                        "Shared": {"path": "Sources/Shared", "module_type": "SwiftTarget"}},
            self.root / remote: {"Native": {"path": "Sources/Native", "module_type": "ClangTarget",
                                           "sources": ["codec.c"], "resources": [{"path": "model.bin"}]}},
        }
        out = io.StringIO()
        with patch.object(licenses, "manifest", side_effect=manifests.__getitem__), \
                patch.object(licenses, "package_files", side_effect=files.__getitem__), contextlib.redirect_stdout(out):
            self.assertFalse(licenses.audit(self.root))
            lock = self.root / "Package.resolved"
            lock.write_text(lock.read_text().replace(revision, "0" * 40))
            with self.assertRaisesRegex(ValueError, "missing checkout of codec"):
                licenses.audit(self.root)
        self.assertIn("model.bin.license\tLGPL-2.1-or-later\tFAIL", out.getvalue())
        self.assertIn("/codec/LICENSE\tMIT\tPASS", out.getvalue())
        self.assertNotIn("host", out.getvalue())

    def test_license_text_is_not_a_keyword_search(self):
        self.assertEqual(licenses.license_ids("MIT License\nFor use at home only."), {"UNKNOWN"})
        self.assertFalse(licenses.permitted("MIT OR GPL-3.0-only"))
        self.assertTrue(licenses.permitted("(MIT OR Apache-2.0)"))


if __name__ == "__main__":
    unittest.main()
