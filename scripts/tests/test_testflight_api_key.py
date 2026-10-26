"""Offline TestFlight API-key/toolchain regression tests for #902; no Apple tools run."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FAKE_KEY_ID = "FAKE_KEY_ID_902"
FAKE_ISSUER = "FAKE_ISSUER_ID_902"

# All commands are shims, including plist tools, so this suite needs no Xcode.
SHIM = r'''
import json
import os
from pathlib import Path
import plistlib
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
root = Path(os.environ["FAKE_ROOT"])
def value(flag):
    return args[args.index(flag) + 1]
def record(data):
    with (root / "calls").open("a") as out:
        out.write(json.dumps(dict(tool=name, developer=os.environ.get("DEVELOPER_DIR"), **data)) + "\n")
if name == "xcode-select":
    record({})
    print(os.environ.get("FAKE_ACTIVE", "/Library/Developer/CommandLineTools"))
    sys.exit(int(os.environ.get("FAKE_SELECT_EXIT", "0")))
elif name == "plutil":
    Path(args[-1]).write_bytes(plistlib.dumps({}))
elif name == "PlistBuddy":
    path = Path(args[-1])
    options = plistlib.loads(path.read_bytes())
    _, key, kind, text = value("-c").split()
    options[key[1:]] = (text == "true") if kind == "bool" else text
    path.write_bytes(plistlib.dumps(options))
elif name == "xcodebuild":
    assert "archive" not in args, "a test attempted an archive"
    assert "-exportArchive" in args
    options = plistlib.loads(Path(value("-exportOptionsPlist")).read_bytes())
    api = "-authenticationKeyID" in args
    if api:
        assert value("-authenticationKeyID") == "FAKE_KEY_ID_902"
        assert value("-authenticationKeyIssuerID") == "FAKE_ISSUER_ID_902"
        assert Path(value("-authenticationKeyPath")).read_text() == "FAKE PRIVATE KEY - NOT SIGNING MATERIAL\n"
    record(dict(options=options, api=api, provisioning="-allowProvisioningUpdates" in args))
    # Deliberately noisy diagnostics exercise suppression, including error paths.
    if api:
        print("FAKE_KEY_ID_902 FAKE_ISSUER_ID_902 " + value("-authenticationKeyPath"), file=sys.stderr)
    if os.environ.get("FAKE_EXPORT_FAIL"):
        sys.exit(1)
    output = Path(value("-exportPath"))
    output.mkdir()
    count = int(os.environ.get("FAKE_IPA_COUNT", "1"))
    for i in range(count):
        (output / (str(i) + ".ipa")).touch()
elif name == "xcrun":
    assert args[:2] == ["altool", "--upload-app"]
    assert value("--apiKey") == "FAKE_KEY_ID_902"
    assert value("--apiIssuer") == "FAKE_ISSUER_ID_902"
    assert value("-t") == "ios" and Path(value("-f")).is_file()
    assert Path(os.environ["API_PRIVATE_KEYS_DIR"]).is_dir()
    record({})
    print("FAKE_KEY_ID_902 FAKE_ISSUER_ID_902 " + os.environ["API_PRIVATE_KEYS_DIR"])
    print(os.environ.get("FAKE_ALTOOL_OUTPUT", "UPLOAD SUCCEEDED FAKE_KEY_ID_902 FAKE_ISSUER_ID_902"))
    # Also cover stderr and a final line without a newline.
    print("FAKE_KEY_ID_902 FAKE_ISSUER_ID_902", file=sys.stderr, end="")
    sys.exit(int(os.environ.get("FAKE_ALTOOL_EXIT", "0")))
else:
    raise AssertionError("unexpected tool")
'''


class TestFlightAPIKeyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="hs-902-offline-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.repo = self.root / "repo"
        (self.repo / "scripts").mkdir(parents=True)
        (self.repo / "project.yml").write_text('  MARKETING_VERSION: "0.1.115"\n')
        self.xcode = self.root / "Applications/Xcode.app/Contents/Developer"
        self.xcode.mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # /usr/bin/python3 on macOS is an xcrun launcher; use the interpreter
        # already running these tests so a fake DEVELOPER_DIR cannot redirect it.
        (self.bin / "python3").symlink_to(sys.executable)
        for name in ["xcode-select", "xcodebuild", "xcrun", "plutil", "PlistBuddy"]:
            path = self.bin / name
            path.write_text(f"#!{sys.executable}\n" + SHIM)
            path.chmod(0o700)
        # Substitute only fixed platform paths in the copied fixture. Production
        # discovery has no test-only override and never touches /Applications here.
        source = (ROOT / "scripts/testflight.sh").read_text()
        self.assertIn("/Applications/Xcode.app/Contents/Developer", source)
        source = source.replace("/Applications/Xcode.app/Contents/Developer", str(self.xcode))
        source = source.replace("/usr/libexec/PlistBuddy", str(self.bin / "PlistBuddy"))
        self.script = self.repo / "scripts/testflight.sh"
        self.script.write_text(source)
        self.script.chmod(0o700)
        self.keys = self.root / ("private " + FAKE_KEY_ID)
        self.keys.mkdir(mode=0o700)
        for name, content in [("AuthKey_FAKE.p8", "FAKE PRIVATE KEY - NOT SIGNING MATERIAL"),
                              ("key_id", FAKE_KEY_ID), ("issuer_id", FAKE_ISSUER)]:
            path = self.keys / name
            path.write_text(content + "\n")
            path.chmod(0o600)
        self.archive = self.root / "fake.xcarchive"
        self.archive.mkdir()
        self.temp = self.root / "temporary exports"
        self.temp.mkdir()
        self.env = {key: value for key, value in os.environ.items()
                    if key not in {"DEVELOPER_DIR", "HAIL_ASC_KEY_DIR", "HAIL_DEVELOPMENT_TEAM",
                                   "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS"}}
        self.env.update(PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        FAKE_ROOT=str(self.root), TMPDIR=str(self.temp))

    def run_script(self, *args, ok=True, trace=False, env=None):
        command = ["bash"] + (["-x"] if trace else []) + [str(self.script), *map(str, args)]
        result = subprocess.run(command, env=dict(self.env, **(env or {})), cwd=self.repo,
                                capture_output=True, text=True, timeout=15)
        output = result.stdout + result.stderr
        # Assert redaction before reporting any diagnostic on failure.
        for secret in [FAKE_KEY_ID, FAKE_ISSUER, str(self.keys), "FAKE PRIVATE KEY"]:
            self.assertNotIn(secret, output, "credential escaped output filtering")
        self.assertEqual(result.returncode == 0, ok, output)
        self.assertEqual(list(self.temp.iterdir()), [], "temporary export directory leaked")
        return output

    def upload(self, *args, **kwargs):
        return self.run_script("upload", "--archive-path", self.archive, "--confirm-upload",
                               "--api-key-dir", self.keys, *args, **kwargs)

    def calls(self, tool):
        path = self.root / "calls"
        return [entry for entry in map(json.loads, path.read_text().splitlines()) if entry["tool"] == tool] if path.exists() else []

    def test_argument_handling(self):
        for args in [[], ["unknown"], ["upload", "--unknown"], ["upload", "--api-key-dir"],
                     ["upload", "--api-key-dir", ""], ["upload", "--api-key-dir", "--dry-run"],
                     ["upload", "--version"], ["upload", "--build"], ["upload", "--archive-path"],
                     ["upload", "--version", "no"], ["upload", "--build", "0"],
                     ["check-version", "--dry-run"]]:
            with self.subTest(args=args):
                self.run_script(*args, ok=False)
        self.assertEqual(self.calls("xcodebuild"), [])

    def test_help(self):
        for args in [["--help"], ["upload", "--help"]]:
            output = self.run_script(*args)
            for expected in ["--api-key-dir", "HAIL_ASC_KEY_DIR", "--dry-run", "DEVELOPER_DIR"]:
                self.assertIn(expected, output)

    def test_confirmation_precedes_tool_work(self):
        for command in ["upload", "release"]:
            self.assertIn("--confirm-upload", self.run_script(command, "--dry-run", ok=False))
        self.assertEqual(self.calls("xcode-select"), [])

    def test_clt_selects_xcode(self):
        self.upload()
        self.assertEqual(self.calls("xcodebuild")[0]["developer"], str(self.xcode))

    def test_active_xcode_is_kept(self):
        active = self.root / "Other.app/Contents/Developer"
        active.mkdir(parents=True)
        self.upload(env={"FAKE_ACTIVE": str(active)})
        self.assertEqual(self.calls("xcodebuild")[0]["developer"], str(active))

    def test_explicit_developer_dir_is_kept(self):
        self.upload(env={"DEVELOPER_DIR": "/FAKE/explicit-Xcode"})
        self.assertEqual(self.calls("xcode-select"), [])
        self.assertEqual(self.calls("xcodebuild")[0]["developer"], "/FAKE/explicit-Xcode")

    def test_explicit_empty_developer_dir_is_not_overridden(self):
        self.upload(env={"DEVELOPER_DIR": ""})
        self.assertEqual(self.calls("xcode-select"), [])
        self.assertEqual(self.calls("xcodebuild")[0]["developer"], "")

    def test_no_xcode_fails_early(self):
        shutil.rmtree(self.xcode)
        self.assertIn("Xcode not found", self.upload(ok=False))
        self.assertEqual(self.calls("xcodebuild"), [])

    def test_xcode_select_failure_uses_default(self):
        self.upload(env={"FAKE_SELECT_EXIT": "1"})
        self.assertEqual(self.calls("xcodebuild")[0]["developer"], str(self.xcode))

    def test_export_options_and_authentication(self):
        self.upload()
        call = self.calls("xcodebuild")[0]
        self.assertEqual(call["options"], dict(method="app-store-connect", destination="export",
                         signingStyle="automatic", manageAppVersionAndBuildNumber=False,
                         testFlightInternalTestingOnly=True, uploadSymbols=True))
        self.assertTrue(call["api"] and call["provisioning"])
        self.assertEqual(len(self.calls("xcrun")), 1)

    def test_environment_key_directory(self):
        self.run_script("upload", "--archive-path", self.archive, "--confirm-upload",
                        env={"HAIL_ASC_KEY_DIR": str(self.keys)})
        self.assertTrue(self.calls("xcodebuild")[0]["api"])

    def test_option_overrides_environment(self):
        self.upload(env={"HAIL_ASC_KEY_DIR": "/FAKE/missing"})

    def test_relative_key_directory(self):
        self.run_script("upload", "--archive-path", self.archive, "--confirm-upload",
                        "--api-key-dir", "../" + self.keys.name)

    def test_missing_directory(self):
        shutil.rmtree(self.keys)
        self.assertIn("missing or unreadable", self.upload(ok=False))

    def test_directory_permissions(self):
        self.keys.chmod(0o755)
        self.assertIn("owner-only", self.upload(ok=False))

    def test_key_count(self):
        key = self.keys / "AuthKey_FAKE.p8"
        key.unlink()
        self.assertIn("exactly one", self.upload(ok=False))
        key.write_text("FAKE")
        (self.keys / "AuthKey_EXTRA_FAKE.p8").write_text("FAKE")
        self.assertIn("exactly one", self.upload(ok=False))

    def test_required_files_missing_empty_or_shared(self):
        for name in ["key_id", "issuer_id", "AuthKey_FAKE.p8"]:
            path = self.keys / name
            content = path.read_text()
            for state in ["missing", "empty", "shared"]:
                with self.subTest(name=name, state=state):
                    if state == "missing":
                        path.unlink()
                    elif state == "empty":
                        path.write_text("")
                    else:
                        path.chmod(0o640)
                    self.upload(ok=False, trace=True)
                    path.write_text(content)
                    path.chmod(0o600)

    def test_identifiers_must_be_nonempty_single_lines(self):
        for name in ["key_id", "issuer_id"]:
            path = self.keys / name
            content = path.read_text()
            for value in [" \t\n", "FAKE\nSECOND_FAKE\n"]:
                with self.subTest(name=name, value=value):
                    path.write_text(value)
                    self.assertIn("single lines", self.upload(ok=False, trace=True))
            path.write_text(content)

    def test_symlinks_are_rejected(self):
        for name in ["key_id", "issuer_id", "AuthKey_FAKE.p8"]:
            path = self.keys / name
            moved = self.keys / "original"
            path.rename(moved)
            path.symlink_to(moved)
            self.upload(ok=False)
            path.unlink()
            moved.rename(path)
        link = self.root / "symlink"
        link.symlink_to(self.keys, target_is_directory=True)
        self.run_script("upload", "--confirm-upload", "--api-key-dir", link, ok=False)

    def test_repository_key_directory_rejected(self):
        self.assertIn("outside the repository", self.run_script(
            "upload", "--confirm-upload", "--api-key-dir", self.repo, ok=False))

    def test_success_and_xtrace_redaction(self):
        output = self.upload(trace=True)
        self.assertIn("UPLOAD SUCCEEDED (details redacted)", output)
        self.assertIn("Upload accepted", output)

    def test_timeout_with_zero_exit_fails(self):
        output = self.upload(ok=False, trace=True, env={
            "FAKE_ALTOOL_OUTPUT": "CREATE BUILD FAKE_KEY_ID_902 request timed out"})
        self.assertIn("CREATE BUILD request timed out", output)
        self.assertNotIn("Upload accepted", output)

    def test_timeout_overrides_success(self):
        self.upload(ok=False, env={"FAKE_ALTOOL_OUTPUT": "CREATE BUILD\nrequest timed out\nUPLOAD SUCCEEDED"})

    def test_missing_success_fails(self):
        self.upload(ok=False, trace=True, env={"FAKE_ALTOOL_OUTPUT": "request finished FAKE_ISSUER_ID_902"})

    def test_nonzero_exit_even_with_success_fails(self):
        self.upload(ok=False, env={"FAKE_ALTOOL_EXIT": "1"})

    def test_export_failure_redacts_and_cleans_up(self):
        self.assertIn("archive export failed", self.upload(ok=False, trace=True, env={"FAKE_EXPORT_FAIL": "1"}))
        self.assertEqual(self.calls("xcrun"), [])

    def test_missing_or_multiple_ipas_fail(self):
        for count in ["0", "2"]:
            with self.subTest(count=count):
                self.assertIn("exactly one IPA", self.upload(ok=False, env={"FAKE_IPA_COUNT": count}))
        self.assertEqual(self.calls("xcrun"), [])

    def test_xcode_account_fallback(self):
        self.run_script("upload", "--archive-path", self.archive, "--confirm-upload")
        call = self.calls("xcodebuild")[0]
        self.assertEqual(call["options"]["destination"], "upload")
        self.assertTrue(call["options"]["testFlightInternalTestingOnly"])
        self.assertFalse(call["api"])
        self.assertEqual(self.calls("xcrun"), [])

    def test_dry_run_validates_without_build_or_upload(self):
        for command in ["archive", "upload", "release"]:
            output = self.run_script(command, "--dry-run", "--confirm-upload", "--api-key-dir", self.keys,
                                     "--build", "902", trace=True)
            self.assertIn("Dry run:", output)
            self.assertIn("<redacted>", output)
            if command != "archive":
                self.assertIn("--apiKey <redacted> --apiIssuer <redacted>", output)
        self.assertEqual(self.calls("xcodebuild"), [])
        self.assertEqual(self.calls("xcrun"), [])
        (self.keys / "key_id").unlink()
        self.upload("--dry-run", ok=False)

    def test_dry_run_account_fallback(self):
        self.assertIn("Xcode account", self.run_script("release", "--confirm-upload", "--dry-run"))
        self.assertEqual(self.calls("xcodebuild"), [])

    def test_missing_archive_and_unknown_arguments_are_redacted(self):
        self.archive.rmdir()
        self.assertIn("archive not found", self.upload(ok=False, trace=True))
        self.run_script("upload", "--" + FAKE_KEY_ID, ok=False, trace=True)
        self.run_script(FAKE_ISSUER, ok=False, trace=True)


if __name__ == "__main__":
    unittest.main()
