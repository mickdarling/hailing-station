"""Mobile license policy and graph selection (#1391). Only temporary inputs are audited."""
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


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
        self.write(".gitignore", ".build/\n.swiftpm/\n*.xcodeproj/\n")
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
        return result.stdout + result.stderr

    def package(self, path="Packages/Codec", targets='.target(name: "Mobile")', dependencies="[]"):
        self.write(f"{path}/Package.swift", f'''// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Codec",
    products: [.library(name: "Terminal", targets: ["Mobile"])],
    dependencies: {dependencies},
    targets: [{targets}]
)
''')
        self.write(f"{path}/LICENSE", "MIT")
        self.write(f"{path}/Sources/Mobile/Codec.swift", "public struct Codec {}")
        self.project["packages"] = {"Codec": {"path": path}}
        self.app["dependencies"] = [{"package": "Codec", "product": "Terminal"}]

    def git(self, path, *args):
        return subprocess.check_output([
            "git", "-c", "user.name=Fixture", "-c", "user.email=test@example.invalid",
            "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null", *args,
        ], cwd=path, text=True).strip()

    def commit_packages(self):
        self.git(self.root, "init", "-q")
        self.git(self.root, "add", "Packages")
        self.git(self.root, "commit", "-qm", "Local packages at this app revision")

    def test_local_package_uses_committed_inputs(self):
        self.package()
        self.assertIn("require inputs committed", self.run_cli(1))
        self.commit_packages()
        self.assertIn("Packages/Codec/LICENSE\tMIT\tPASS", self.run_cli(0))
        self.write("Packages/Codec/Sources/Mobile/Late.metal", "// SPDX-License-Identifier: MIT")
        self.assertIn("uncommitted local mobile package input: Packages/Codec/Sources/Mobile/Late.metal", self.run_cli(1))
        self.commit_packages()
        (self.root / "Packages/Codec/Sources/Mobile/Late.metal").unlink()
        self.assertIn("uncommitted local mobile package input: Packages/Codec/Sources/Mobile/Late.metal", self.run_cli(1))

    def test_remote_requires_committed_xcode_resolution_and_matching_checkout(self):
        remote = ".build/mobile-packages/checkouts/codec"
        self.package(remote)
        url = "https://example.invalid/codec.git"
        self.project["packages"]["Codec"] = {"url": url, "from": "1.0.0"}
        self.write(f"{remote}/.gitignore", ".build/\n.swiftpm/\n")
        checkout = self.root / remote
        self.git(checkout, "init", "-q")
        self.git(checkout, "add", ".")
        self.git(checkout, "commit", "-qm", "Fixture")
        revision = self.git(checkout, "rev-parse", "HEAD")
        pins = json.dumps({"version": 2, "pins": [{"identity": "codec", "kind": "remoteSourceControl",
                          "location": url, "state": {"version": "1.0.0", "revision": revision}}]})
        lock = "Radio.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        self.git(self.root, "init", "-q")
        self.write("Package.resolved", pins)
        self.git(self.root, "add", "Package.resolved")
        self.git(self.root, "commit", "-qm", "Unrelated root lock")
        self.assertIn("require a current committed Xcode resolution", self.run_cli(1))
        self.write(lock, pins)
        self.git(self.root, "add", "-f", lock)
        self.assertIn("require a current committed Xcode resolution", self.run_cli(1))
        self.git(self.root, "commit", "-qm", "Mobile pins")
        subprocess.run(["xcodegen", "generate", "--quiet"], cwd=self.root, check=True)
        self.assertIn(f"{remote}/LICENSE\tMIT\tPASS", self.run_cli(0))
        self.write(lock, pins.replace(revision, "0" * 40))
        self.assertIn("require a current committed Xcode resolution", self.run_cli(1))
        self.git(self.root, "commit", "-qam", "Different pin")
        self.assertIn("missing checkout of codec", self.run_cli(1))
        # Both build entry points must refuse automatic re-resolution.
        for script, command in (("verify.sh", "xcodebuild build-for-testing"), ("testflight.sh", "xcodebuild -quiet archive")):
            lines = (SCRIPT.parent / script).read_text().replace("\\\n", " ").splitlines()
            invocation, = [line for line in lines if line.lstrip().startswith(command)]
            self.assertIn("-onlyUsePackageVersionsFromResolvedFile", invocation)

    def test_swiftpm_local_transitive_model_fails_lgpl_and_passes_apache(self):
        self.package(targets='''
            .target(name: "Mobile", dependencies: [
                .product(name: "Models", package: "Assets", condition: .when(platforms: [.iOS])),
                .target(name: "Host", condition: .when(platforms: [.macOS]))
            ]), .target(name: "Host")''', dependencies='[.package(path: "../Assets")]')
        self.write("Packages/Codec/Sources/Host/Host.swift", "// SPDX-License-Identifier: GPL-3.0-only")
        self.write("Packages/Assets/Package.swift", '''// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Assets", products: [.library(name: "Models", targets: ["Weights"])],
    targets: [.target(name: "Weights", resources: [.copy("model.blob")])]
)
''')
        self.write("Packages/Assets/LICENSE", "MIT")
        self.write("Packages/Assets/Sources/Weights/Model.swift", "public enum Model {}")
        model = "Packages/Assets/Sources/Weights/model.blob"
        self.write(model, "synthetic model")
        for spdx, status, code in (("LGPL-2.1-or-later", "FAIL", 1), ("Apache-2.0", "PASS", 0)):
            with self.subTest(spdx=spdx):
                self.write(model + ".license", f"SPDX-License-Identifier: {spdx}")
                self.commit_packages()
                out = self.run_cli(code)
                self.assertIn(f"{model}\t{model}.license\t{spdx}\t{status}", out)
                self.assertIn("Packages/Assets/LICENSE\tMIT\tPASS", out)
                self.assertNotIn("Host.swift", out)

    def test_swiftpm_implicit_resources_respect_target_excludes(self):
        self.package(targets='.target(name: "Mobile", exclude: ["Excluded"])')
        base = "Packages/Codec/Sources/Mobile"
        self.write(f"{base}/Excluded/Bad.metal", "// SPDX-License-Identifier: AGPL-3.0-only")
        self.write(f"{base}/Shader.metal", "// SPDX-License-Identifier: GPL-2.0-only\n#include <metal_stdlib>")
        cases = ("Images.xcassets/Contents.json", "View.storyboard", "View.xib",
                 "Data.xcdatamodeld/Model.xcdatamodel/contents", "Localizable.strings", "Model.mlpackage/Data/weights.blob")
        for item in cases:
            self.write(f"{base}/{item}", "fixture")
            self.write(f"{base}/{item}.license", "GPL-2.0-only")
        self.commit_packages()
        out = self.run_cli(1)
        for item in cases:
            self.assertIn(f"{base}/{item}\t{base}/{item}.license\tGPL-2.0-only\tFAIL", out)
        self.assertIn(f"{base}/Shader.metal\tGPL-2.0-only\tFAIL", out)
        self.assertNotIn("Excluded", out)

    def test_xcode_and_swiftpm_build_tool_plugins_fail_closed(self):
        self.package()
        self.project["targetTemplates"] = {"UsesTool": {"buildToolPlugins": [{"plugin": "Generator", "package": "Codec"}]}}
        self.app["templates"] = ["UsesTool"]
        self.assertIn("cannot inventory build-tool plugin outputs", self.run_cli(1))
        del self.app["templates"]
        self.package(targets='''.target(name: "Mobile", plugins: [.plugin(name: "Generator")]),
            .plugin(name: "Generator", capability: .buildTool())''')
        self.write("Packages/Codec/Plugins/Generator/plugin.swift", "import PackagePlugin")
        self.commit_packages()
        self.assertIn("cannot inventory plugin-generated inputs", self.run_cli(1))

    def test_forced_and_recursive_quoted_headers(self):
        self.project["settings"] = {"base": {"GCC_PREFIX_HEADER": "$(SRCROOT)/Headers/Prefix.pch"}}
        self.app["settings"] = {"base": {"SWIFT_OBJC_BRIDGING_HEADER[sdk=iphoneos*]": "${PROJECT_DIR}/Headers/Bridge.h"}}
        self.write("Headers/Prefix.pch", "/* SPDX-License-Identifier: LGPL-3.0-only */")
        self.write("Headers/Bridge.h", '#import "detail/inner.h"\n/* SPDX-License-Identifier: MIT */')
        self.write("Headers/detail/inner.h", '#include "../Bridge.h"\n/* SPDX-License-Identifier: GPL-2.0-only */')
        self.write("Apps/Phone/dsp.c", '#include "../../Vendor/include/inlines.h"\n/* SPDX-License-Identifier: ISC */')
        self.write("Vendor/include/inlines.h", "// Licensed under the AGPL.")
        out = self.run_cli(1)
        for row in ("Prefix.pch\tLGPL-3.0-only\tFAIL", "Bridge.h\tMIT\tPASS",
                    "detail/inner.h\tGPL-2.0-only\tFAIL", "inlines.h\tAGPL\tFAIL"):
            self.assertIn(row, out)
        (self.root / "Headers/detail/inner.h").unlink()
        self.assertIn("missing mobile header", self.run_cli(1))
        self.write("Headers/detail/inner.h", '#include "../../../outside.h"')
        self.assertIn("mobile input outside repository", self.run_cli(1))

    def test_shipped_textual_resources_override_permissive_wrapper(self):
        self.app["sources"] = [{"path": "Resources", "type": "folder"}]
        self.write("Resources/LICENSE", "MIT")
        for ext in ("js", "txt", "md", "html", "css", "py", "sh"):
            self.write(f"Resources/codec.{ext}", "// SPDX-License-Identifier: GPL-3.0-only")
        self.write("Resources/codec.json", json.dumps({"SPDX-License-Identifier": "MPL-2.0"}))
        self.write("Resources/codec", "#!/bin/sh\n# SPDX-License-Identifier: LicenseRef-Restricted")
        (self.root / "Resources/Localizable.strings").write_bytes(
            '/* GNU Lesser General Public License v2.1 */'.encode("utf-16"))
        out = self.run_cli(1)
        for ext in ("js", "txt", "md", "html", "css", "py", "sh"):
            self.assertIn(f"Resources/codec.{ext}\tGPL-3.0-only\tFAIL", out)
        self.assertIn("codec.json\tMPL-2.0\tFAIL", out)
        self.assertIn("codec\tLicenseRef-Restricted\tFAIL", out)
        self.assertIn("Localizable.strings\tLGPL-2.1\tFAIL", out)

    def test_versionless_gnu_precedes_first_party_source_exemption(self):
        for family in ("GPL", "LGPL", "AGPL"):
            self.write(f"Apps/Phone/{family}.swift", f"// Licensed under the {family}.")
        out = self.run_cli(1)
        for family in ("GPL", "LGPL", "AGPL"):
            self.assertIn(f"{family}.swift\t{family}\tFAIL", out)

    def test_component_notices_require_resolved_terms(self):
        library = "Vendor/Codec.framework"
        self.app["dependencies"] = [{"framework": library}]
        self.write(f"{library}/LICENSE", "MIT")
        self.write(f"{library}/Codec", "synthetic")
        self.write(f"{library}/NOTICE.txt", "Embedded decoder uses the GNU Lesser General Public License")
        self.write(f"{library}/THIRD-PARTY-NOTICES.txt", "Contains OtherCodec by Example Authors")
        self.write(f"{library}/ThirdPartyNotices", "SPDX-License-Identifier: MIT\nAlso embeds UnidentifiedDSP")
        out = self.run_cli(1)
        for row in ("NOTICE.txt\tLGPL\tFAIL", "THIRD-PARTY-NOTICES.txt\tUNKNOWN\tFAIL", "ThirdPartyNotices\tUNKNOWN\tFAIL"):
            self.assertIn(row, out)
        for name in ("NOTICE.txt", "THIRD-PARTY-NOTICES.txt", "ThirdPartyNotices"):
            self.write(f"{library}/{name}", "SPDX-License-Identifier: Apache-2.0")
        self.assertIn("ThirdPartyNotices\tApache-2.0\tPASS", self.run_cli(0))

    def test_metadata_gnu_titles_cannot_be_excepted(self):
        self.app["sources"] = ["Native/Radio"]
        self.write("Native/Radio/radio.c", "int codec;")
        for title, canonical in (("GNU General Public License v3.0", "GPL-3.0"),
                                 ("GNU Lesser General Public License", "LGPL"),
                                 ("GNU Affero General Public License Version 3", "AGPL-3.0")):
            with self.subTest(title=title):
                self.write("Native/Radio/package.json", json.dumps({"license": title}))
                self.write("scripts/license-allowlist.txt", f"Native/Radio\t{title}\tReview\nNative/Radio\t{canonical}\tReview\n")
                self.assertIn(f"package.json\t{canonical}\tFAIL", self.run_cli(1))

    def test_dangling_license_and_metadata_symlinks_fail_closed(self):
        self.package()
        self.commit_packages()
        for name in ("COPYING", "ThirdPartyNotices", "package.json"):
            with self.subTest(name=name):
                link = self.root / "Packages/Codec" / name
                link.symlink_to("absent")
                self.assertIn(f"symlink {link}", self.run_cli(1))
                link.unlink()

    def test_selected_binary_requires_workspace_artifact_and_mobile_library(self):
        url = "https://example.invalid/Mobile.zip"
        checksum = "a" * 64
        self.package(targets=f'.binaryTarget(name: "Mobile", url: "{url}", checksum: "{checksum}")')
        self.commit_packages()
        self.write("scripts/license-allowlist.txt", f"Packages/Codec/Mobile@{checksum}\tUNKNOWN\tsha256:{checksum}\tReviewed\n")
        build = ".build/mobile-packages"
        self.write(f"{build}/artifacts/codec/Mobile/LICENSE", "MIT")  # Old guessed path.
        self.assertIn("missing or unsupported selected binary artifact Mobile", self.run_cli(1))
        artifact = f"{build}/artifacts/codec/download/Audio.xcframework"
        record = {"packageRef": {"identity": "codec"}, "targetName": "Mobile",
                  "path": str(self.root / artifact), "source": {"type": "remote", "url": url, "checksum": checksum}}
        state = f"{build}/workspace-state.json"
        self.write(state, json.dumps({"object": {"artifacts": [record]}}))
        self.assertIn("missing or unsupported selected binary artifact Mobile", self.run_cli(1))
        info = {"AvailableLibraries": [{"LibraryIdentifier": "ios-arm64", "LibraryPath": "libAudio.a",
                                         "SupportedPlatform": "ios"}]}
        self.write(f"{artifact}/Info.plist", plistlib.dumps(info).decode())
        self.write(f"{artifact}/LICENSE", "MIT")
        self.assertIn("missing mobile binary", self.run_cli(1))
        self.write(f"{artifact}/ios-arm64/libAudio.a", "synthetic archive")
        self.assertIn(f"{artifact}/LICENSE\tMIT\tPASS", self.run_cli(0))
        record["source"]["checksum"] = "b" * 64
        self.write(state, json.dumps({"object": {"artifacts": [record]}}))
        self.assertIn("missing or unsupported selected binary artifact Mobile", self.run_cli(1))

    def test_spdx_and_copyright_do_not_hide_modified_terms(self):
        self.app["sources"] = ["Native/Radio"]
        self.write("Native/Radio/dsp.c", "int dsp;")
        mit = (Path(__file__).parent / "fixtures/mobile-licenses/MIT.txt").read_text()
        self.write("Native/Radio/LICENSE", "SPDX-License-Identifier: MIT\n" + mit)
        self.assertIn("LICENSE\tMIT\tPASS", self.run_cli(0))
        for terms in ("SPDX-License-Identifier: MIT\nCommercial use is prohibited.",
                      mit.replace("Example Authors", "Example Authors. Commercial use is prohibited."),
                      mit.replace("Example Authors", "Example Authors Noncommercial Use Only")):
            with self.subTest(terms=terms.splitlines()[0]):
                self.write("Native/Radio/LICENSE", terms)
                self.assertIn("LICENSE\tUNKNOWN\tFAIL", self.run_cli(1))
        self.write("Native/Radio/LICENSE", "MIT")
        self.write("Native/Radio/dsp.c", "/* SPDX-License-Identifier: MIT\n * Commercial use is prohibited. */\nint dsp;")
        self.assertIn("dsp.c\tUNKNOWN\tFAIL", self.run_cli(1))

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
        self.assertIn("requires a sha256 file digest", self.run_cli(1))
        digest = hashlib.sha256(b"synthetic weights").hexdigest()
        self.write("scripts/license-allowlist.txt",
                   f"Apps/Phone/weights.gguf\tUNKNOWN\tsha256:{digest}\tRedistribution grant on file\n")
        self.assertIn(row + "EXCEPTION: Redistribution grant on file", self.run_cli(0))
        self.write("Apps/Phone/weights.gguf", "replacement weights")
        self.assertIn(row + "FAIL", self.run_cli(1))
        self.write("Apps/Phone/weights.gguf", "synthetic weights")
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

    def test_license_text_is_not_a_keyword_search(self):
        self.assertEqual(licenses.license_ids("MIT License\nFor use at home only."), {"UNKNOWN"})
        self.assertFalse(licenses.permitted("MIT OR GPL-3.0-only"))
        self.assertTrue(licenses.permitted("(MIT OR Apache-2.0)"))


if __name__ == "__main__":
    unittest.main()
