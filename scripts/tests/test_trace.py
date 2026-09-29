"""Tests for scripts/spec_trace.py (#27, #143). Install scripts/spec-trace-requirements.txt first."""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import spec_trace as tracer  # noqa: E402

SPEC = """## Intent
x
## Test expectations
`AlphaTests`, `BetaTests` (table-driven), manual runbook `docs/testing/alpha.md`, `scripts/tests/test_alpha.py`.
## Out of scope
`NotATestName`
"""


class TraceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.tree = Path(self.tmp.name)
        (self.tree / "Tests" / "AlphaTests").mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def xcode_project(self, sources="Tests/AlphaTests", target_type="bundle.ui-testing"):
        (self.tree / "project.yml").write_text(
            f"name: Fixture\ntargets:\n  UI:\n    type: {target_type}\n    platform: iOS\n    sources: {sources}\n"
        )

    def alpha_suite(self, content="class AlphaTests: XCTestCase { func testPresence() {} }\n"):
        (self.tree / "Tests/AlphaTests/A.swift").write_text(content)

    def test_xcode_ui_target_and_swiftpm_roots_are_unioned(self):
        self.xcode_project()
        self.alpha_suite()
        (self.tree / "Package.swift").write_text('.testTarget(name: "BetaTests", dependencies: [])')
        (self.tree / "Tests/BetaTests").mkdir()
        (self.tree / "Tests/BetaTests/B.swift").write_text("@Suite struct BetaTests { @Test func ok() {} }")
        self.assertEqual(tracer.check(["AlphaTests", "BetaTests"], self.tree), [])

    def test_xcode_unit_target_supports_explicit_file_mapping(self):
        self.xcode_project("[{path: Tests/AlphaTests/A.swift, type: file, buildPhase: sources}]", "bundle.unit-test")
        self.alpha_suite()
        self.assertEqual(tracer.test_target_paths(self.tree), [self.tree / "Tests/AlphaTests/A.swift"])
        self.assertEqual(tracer.check(["AlphaTests"], self.tree), [])

    def test_xcode_undeclared_and_non_test_targets_do_not_count(self):
        self.alpha_suite()
        for sources, target_type in (("OtherTests", "bundle.ui-testing"), ("Tests/AlphaTests", "application")):
            with self.subTest(sources=sources, target_type=target_type):
                self.xcode_project(sources, target_type)
                self.assertEqual(tracer.check(["AlphaTests"], self.tree), ["suite `AlphaTests` not found under Tests/"])

    def test_xcode_removed_target_does_not_trigger_fallback(self):
        self.xcode_project()
        self.alpha_suite()
        self.assertEqual(tracer.check(["AlphaTests"], self.tree), [])
        (self.tree / "project.yml").write_text("name: Fixture\ntargets: {}\n")
        self.assertEqual(tracer.check(["AlphaTests"], self.tree), ["suite `AlphaTests` not found under Tests/"])

    def test_xcode_yaml_comments_and_block_strings_are_not_declarations(self):
        self.alpha_suite()
        (self.tree / "project.yml").write_text(
            "name: Fixture\n# targets: {UI: {type: bundle.ui-testing, sources: Tests/AlphaTests}}\n"
            "note: |\n  targets:\n    UI:\n      type: bundle.ui-testing\n      sources: Tests/AlphaTests\n"
        )
        self.assertEqual(tracer.test_target_paths(self.tree), [])
        self.assertEqual(tracer.check(["AlphaTests"], self.tree), ["suite `AlphaTests` not found under Tests/"])

    def test_xcode_stub_comments_strings_and_disabled_tests_do_not_count(self):
        self.xcode_project()
        for content in (
            '// class AlphaTests: XCTestCase { func testFake() {} }\nlet x = "class AlphaTests { @Test }"',
            '#if false\nclass AlphaTests: XCTestCase { func testFake() {} }\n#endif',
            'class AlphaTests: XCTestCase { /* func testFake() {} */ let x = "@Test" }',
            'class AlphaTests: XCTestCase {}',
        ):
            with self.subTest(content=content):
                self.alpha_suite(content)
                self.assertTrue(tracer.check(["AlphaTests"], self.tree))

    def test_xcode_escape_and_absolute_paths_are_rejected(self):
        with tempfile.TemporaryDirectory() as outside:
            (Path(outside) / "A.swift").write_text("class AlphaTests { func testFake() {} }")
            for source in (outside, f"../{Path(outside).name}"):
                with self.subTest(source=source):
                    self.xcode_project(source)
                    self.assertEqual(tracer.test_target_paths(self.tree), [])
                    problems = tracer.check(["AlphaTests"], self.tree)
                    self.assertTrue(any(p.startswith("Xcode test discovery:") for p in problems))
                    self.assertIn("suite `AlphaTests` not found under Tests/", problems)

    def test_xcode_symlink_roots_files_and_manifest_are_rejected(self):
        self.alpha_suite()
        (self.tree / "LinkedTests").symlink_to(self.tree / "Tests/AlphaTests", target_is_directory=True)
        self.xcode_project("LinkedTests")
        self.assertEqual(tracer.test_target_paths(self.tree), [])
        self.xcode_project()
        (self.tree / "Tests/AlphaTests/A.swift").unlink()
        (self.tree / "Real.swift").write_text("class AlphaTests { func testPresence() {} }")
        (self.tree / "Tests/AlphaTests/A.swift").symlink_to(self.tree / "Real.swift")
        self.assertIn("suite `AlphaTests` not found under Tests/", tracer.check(["AlphaTests"], self.tree))
        (self.tree / "project.yml").rename(self.tree / "real.yml")
        (self.tree / "project.yml").symlink_to(self.tree / "real.yml")
        self.assertEqual(tracer.test_target_paths(self.tree), [])

    def test_symlink_ancestor_and_swiftpm_root_are_rejected(self):
        self.alpha_suite()
        (self.tree / "Linked").symlink_to(self.tree / "Tests", target_is_directory=True)
        self.xcode_project("Linked/AlphaTests")
        self.assertEqual(tracer.test_target_paths(self.tree), [])
        (self.tree / "project.yml").unlink()
        (self.tree / "Package.swift").write_text('.testTarget(name: "AlphaTests", path: "Linked/AlphaTests")')
        self.assertEqual(tracer.test_target_paths(self.tree), [])
        self.assertIn("suite `AlphaTests` not found under Tests/", tracer.check(["AlphaTests"], self.tree))

    def test_nested_xcode_manifest_does_not_declare_root_targets(self):
        (self.tree / "Package.swift").write_text('.target(name: "Alpha")')
        (self.tree / "Tests/AlphaTests/project.yml").write_text(
            "targets: {UI: {type: bundle.ui-testing, sources: .}}"
        )
        self.alpha_suite()
        self.assertEqual(tracer.check(["AlphaTests"], self.tree), ["suite `AlphaTests` not found under Tests/"])

    def test_xcode_unsupported_selection_forms_fail_with_diagnostics(self):
        self.alpha_suite()
        for source in (
            "[{path: Tests/AlphaTests, excludes: ['A.swift']}]",
            "[{path: Tests/AlphaTests, includes: ['Other.swift']}]",
            "[{path: Tests/AlphaTests, buildPhase: resources}]",
            "[{path: Tests/AlphaTests, type: folder}]",
            "[{path: Tests/AlphaTests, type: file}]",
            "'${TEST_PATH}'",
        ):
            with self.subTest(source=source):
                self.xcode_project(source)
                problems = tracer.check(["AlphaTests"], self.tree)
                self.assertTrue(any(p.startswith("Xcode test discovery:") for p in problems))
                self.assertIn("suite `AlphaTests` not found under Tests/", problems)

    def test_xcode_unsupported_merging_and_settings_fail_closed(self):
        self.alpha_suite()
        for extra in (
            "include: base.yml\n", "configFiles: {Debug: build.xcconfig}\n",
            "options: {fileTypes: {swift: {buildPhase: resources}}}\n",
            "options: {defaultSourceDirectoryType: folder}\n",
            "settings: {groups: [excluded]}\n",
            "settings: {base: {'EXCLUDED_SOURCE_FILE_NAMES[sdk=iphoneos*]': '*.swift'}}\n",
        ):
            with self.subTest(extra=extra):
                self.xcode_project()
                manifest = self.tree / "project.yml"
                manifest.write_text(manifest.read_text() + extra)
                self.assertEqual(tracer.test_target_paths(self.tree), [])
                self.assertTrue(any(p.startswith("Xcode test discovery:") for p in tracer.check(["AlphaTests"], self.tree)))
        for extra in ("templates: [hidden]", "settings: {groups: [hidden]}"):
            with self.subTest(extra=extra):
                self.xcode_project()
                manifest = self.tree / "project.yml"
                manifest.write_text(manifest.read_text() + f"    {extra}\n")
                self.assertEqual(tracer.test_target_paths(self.tree), [])

    def test_xcode_ambiguous_or_invalid_yaml_fails_closed(self):
        self.alpha_suite()
        for text in (
            "targets: [", "targets: {}\ntargets: {UI: {type: bundle.ui-testing, sources: Tests/AlphaTests}}",
            "x: &ui {type: bundle.ui-testing, sources: Tests/AlphaTests}\ntargets: {UI: *ui}",
            "!!python/object/apply:os.system ['echo unsafe']", "[]",
        ):
            with self.subTest(text=text):
                (self.tree / "project.yml").write_text(text)
                self.assertEqual(tracer.test_target_paths(self.tree), [])
                self.assertTrue(any(p.startswith("Xcode test discovery:") for p in tracer.check(["AlphaTests"], self.tree)))

    def test_xcode_replace_overrides_are_rejected_at_every_level(self):
        self.alpha_suite()
        for text in (
            "targets: {}\ntargets:REPLACE: {UI: {type: bundle.ui-testing, sources: Tests/AlphaTests}}",
            "include:REPLACE: base.yml\ntargets: {UI: {type: bundle.ui-testing, sources: Tests/AlphaTests}}",
            "targets: {UI: {type: bundle.ui-testing, sources: Tests/AlphaTests, 'sources:REPLACE': []}}",
            "targets: {UI: {type: bundle.ui-testing, sources: Tests/AlphaTests, 'settings:REPLACE': {EXCLUDED_SOURCE_FILE_NAMES: '*.swift'}}}",
        ):
            with self.subTest(text=text):
                (self.tree / "project.yml").write_text(text)
                self.assertEqual(tracer.test_target_paths(self.tree), [])
                problems = tracer.check(["AlphaTests"], self.tree)
                self.assertTrue(any(":REPLACE" in p for p in problems))
                self.assertIn("suite `AlphaTests` not found under Tests/", problems)

    def test_xcode_extension_bearing_directory_defaults_to_file_reference(self):
        bundle = self.tree / "Tests/Fixtures.bundle"
        bundle.mkdir()
        (bundle / "A.swift").write_text("class AlphaTests { func testPresence() {} }")
        self.xcode_project("Tests/Fixtures.bundle")
        self.assertEqual(tracer.test_target_paths(self.tree), [])
        self.assertIn("suite `AlphaTests` not found under Tests/", tracer.check(["AlphaTests"], self.tree))
        self.xcode_project("[{path: Tests/Fixtures.bundle, type: group}]")
        self.assertEqual(tracer.check(["AlphaTests"], self.tree), [])

    def test_xcode_nested_wrapper_cannot_satisfy_declared_suite_presence(self):
        wrapper = self.tree / "Tests/AlphaTests/Fixtures.bundle"
        wrapper.mkdir()
        (wrapper / "A.swift").write_text("class AlphaTests { func testPresence() {} }")
        self.xcode_project()
        self.assertEqual(tracer.test_target_paths(self.tree), [])
        problems = tracer.check(["AlphaTests"], self.tree)
        self.assertIn("suite `AlphaTests` not found under Tests/", problems)
        self.assertTrue(any("unsupported descendant directory wrapper Tests/AlphaTests/Fixtures.bundle" in p
                            for p in problems))
        self.assertEqual(tracer.run("## Test expectations\n`AlphaTests`", self.tree, True, {"AlphaTests"})[1], 1)

    def test_xcode_independent_wrapper_group_and_file_declarations_are_supported(self):
        wrapper = self.tree / "Tests/AlphaTests/Fixtures.bundle"
        wrapper.mkdir()
        (wrapper / "A.swift").write_text("class AlphaTests { func testPresence() {} }")
        for source in (
            "[{path: Tests/AlphaTests/Fixtures.bundle, type: group}]",
            "[{path: Tests/AlphaTests/Fixtures.bundle/A.swift, type: file}]",
        ):
            with self.subTest(source=source):
                self.xcode_project(source)
                self.assertEqual(tracer.check(["AlphaTests"], self.tree), [])

    def test_swiftpm_wrapper_descendant_behavior_is_not_reinterpreted_as_xcode(self):
        wrapper = self.tree / "Tests/AlphaTests/Fixtures.bundle"
        wrapper.mkdir()
        (wrapper / "A.swift").write_text("@Suite struct AlphaTests { @Test func ok() {} }")
        (self.tree / "Package.swift").write_text('.testTarget(name: "AlphaTests")')
        self.assertEqual(tracer.check(["AlphaTests"], self.tree), [])

    def test_xcode_diagnostics_cannot_be_hidden_by_named_partial_trace(self):
        self.xcode_project("[{path: Tests/AlphaTests, excludes: ['A.swift']}]")
        problems, code = tracer.run("## Test expectations\n`AlphaTests`", self.tree, True, {"AlphaTests"})
        self.assertEqual(code, 1)
        self.assertTrue(any(p.startswith("Xcode test discovery:") for p in problems))
        # Even an untrusted target name containing a deferred token cannot downgrade a metadata error.
        manifest = self.tree / "project.yml"
        manifest.write_text(manifest.read_text().replace("  UI:", "  '`AlphaTests`':"))
        self.assertEqual(tracer.run("## Test expectations\n`AlphaTests`", self.tree, True, {"AlphaTests"})[1], 1)

    def test_real_repo_declares_xcode_ui_sources(self):
        repo = Path(__file__).resolve().parent.parent.parent
        self.assertIn(repo / "Tests/Hail-iOSUITests", tracer.test_target_paths(repo))

    def test_extracts_only_from_test_expectations_section(self):
        self.assertEqual(tracer.expectations(SPEC), ["AlphaTests", "BetaTests", "docs/testing/alpha.md", "scripts/tests/test_alpha.py"])

    def test_missing_suite_and_files_are_reported(self):
        problems = tracer.check(tracer.expectations(SPEC), self.tree)
        self.assertIn("suite `AlphaTests` not found under Tests/", problems)
        self.assertIn("suite `BetaTests` not found under Tests/", problems)
        self.assertIn("file `docs/testing/alpha.md` not found", problems)
        self.assertIn("file `scripts/tests/test_alpha.py` not found", problems)

    def test_empty_suite_is_reported(self):
        (self.tree / "Tests" / "AlphaTests" / "A.swift").write_text("@Suite struct AlphaTests {}\n")
        problems = tracer.check(["AlphaTests"], self.tree)
        self.assertEqual(problems, ["suite `AlphaTests` exists but contains no tests"])

    def test_populated_suite_passes(self):
        (self.tree / "Tests" / "AlphaTests" / "A.swift").write_text("@Suite struct AlphaTests { @Test func ok() {} }\n")
        self.assertEqual(tracer.check(["AlphaTests"], self.tree), [])

    def test_spec_without_section_names_nothing(self):
        self.assertEqual(tracer.expectations("## Intent\nno tests here\n"), [])

    def test_heading_variants_from_the_issue_form_are_recognised(self):
        for heading in ("### Test expectations", "## Test Expectations", "## Test expectations (named)"):
            self.assertEqual(tracer.expectations(f"{heading}\n`ZTests`\n## Out of scope\n`QTests`"), ["ZTests"])

    def test_emptiness_is_judged_per_suite_not_per_file(self):
        (self.tree / "Tests" / "AlphaTests" / "Both.swift").write_text(
            "@Suite struct AlphaTests {}\n@Suite struct BetaTests { @Test func ok() {} }\n"
        )
        self.assertEqual(tracer.check(["AlphaTests", "BetaTests"], self.tree),
                         ["suite `AlphaTests` exists but contains no tests"])

    def test_tests_in_an_extension_count(self):
        (self.tree / "Tests" / "AlphaTests" / "A.swift").write_text("@Suite struct AlphaTests {}\n")
        (self.tree / "Tests" / "AlphaTests" / "B.swift").write_text("extension AlphaTests { @Test func ok() {} }\n")
        self.assertEqual(tracer.check(["AlphaTests"], self.tree), [])

    def test_extension_only_is_not_a_declared_suite(self):
        self.alpha_suite("extension AlphaTests { @Test func ok() {} }")
        for manifest in ("fallback", "swiftpm", "xcode"):
            with self.subTest(manifest=manifest):
                if manifest == "swiftpm":
                    (self.tree / "Package.swift").write_text('.testTarget(name: "AlphaTests")')
                elif manifest == "xcode":
                    (self.tree / "Package.swift").unlink()
                    self.xcode_project()
                self.assertEqual(tracer.check(["AlphaTests"], self.tree),
                                 ["suite `AlphaTests` not found under Tests/"])

    def test_swiftpm_cross_target_extension_cannot_complete_suite(self):
        self.alpha_suite("struct AlphaTests {}")
        (self.tree / "Tests/BetaTests").mkdir()
        (self.tree / "Tests/BetaTests/B.swift").write_text("extension AlphaTests { @Test func ok() {} }")
        (self.tree / "Package.swift").write_text(
            '.testTarget(name: "AlphaTests")\n.testTarget(name: "BetaTests")'
        )
        self.assertEqual(tracer.check(["AlphaTests"], self.tree),
                         ["suite `AlphaTests` exists but contains no tests"])

    def test_xcode_cross_target_extension_cannot_complete_suite(self):
        self.alpha_suite("class AlphaTests: XCTestCase {}")
        (self.tree / "Tests/BetaTests").mkdir()
        (self.tree / "Tests/BetaTests/B.swift").write_text("extension AlphaTests { func testPresence() {} }")
        (self.tree / "project.yml").write_text(
            "targets:\n  First:\n    type: bundle.unit-test\n    sources: Tests/AlphaTests\n"
            "  Second:\n    type: bundle.unit-test\n    sources: Tests/BetaTests\n"
        )
        self.assertEqual(tracer.check(["AlphaTests"], self.tree),
                         ["suite `AlphaTests` exists but contains no tests"])

    def test_mixed_same_named_targets_cannot_complete_each_others_suite(self):
        (self.tree / "Tests/BetaTests").mkdir()
        (self.tree / "Package.swift").write_text('.testTarget(name: "UI", path: "Tests/AlphaTests")')
        self.xcode_project("Tests/BetaTests")  # Both manifest target names are UI, not AlphaTests.
        for declaration_in in ("AlphaTests", "BetaTests"):
            with self.subTest(declaration_in=declaration_in):
                for name in ("AlphaTests", "BetaTests"):
                    (self.tree / f"Tests/{name}/A.swift").write_text(
                        "struct AlphaTests {}" if name == declaration_in else
                        "extension AlphaTests { @Test func ok() {} }"
                    )
                self.assertEqual(tracer.check(["AlphaTests"], self.tree),
                                 ["suite `AlphaTests` exists but contains no tests"])

    def test_swiftpm_same_target_split_extension_is_supported_with_mixed_manifest(self):
        self.alpha_suite("struct AlphaTests {}")
        (self.tree / "Tests/AlphaTests/B.swift").write_text("extension AlphaTests { @Test func ok() {} }")
        (self.tree / "Package.swift").write_text('.testTarget(name: "Unrelated", path: "Tests/AlphaTests")')
        self.xcode_project("OtherTests")
        self.assertEqual(tracer.check(["AlphaTests"], self.tree), [])

    def test_xcode_same_target_multiple_roots_support_split_extension(self):
        self.alpha_suite("struct AlphaTests {}")
        (self.tree / "Checks").mkdir()
        (self.tree / "Checks/B.swift").write_text("extension AlphaTests { @Test func ok() {} }")
        self.xcode_project("[Tests/AlphaTests, {path: Checks/B.swift, type: file}]")
        (self.tree / "Package.swift").write_text('.testTarget(name: "UI", path: "OtherTests")')
        self.assertEqual(tracer.check(["AlphaTests"], self.tree), [])

    def test_partial_defers_only_named_expectations(self):
        problems, code = tracer.run(SPEC, self.tree, partial=True)
        self.assertTrue(problems)
        self.assertEqual(code, 1, "partial with nothing named must still fail")
        everything = {"AlphaTests", "BetaTests", "docs/testing/alpha.md", "scripts/tests/test_alpha.py"}
        self.assertEqual(tracer.run(SPEC, self.tree, partial=True, deferred=everything)[1], 0)
        self.assertEqual(tracer.run(SPEC, self.tree, partial=True, deferred={"AlphaTests"})[1], 1)
        self.assertEqual(tracer.run(SPEC, self.tree, partial=False)[1], 1)
        self.assertEqual(tracer.run("## Intent\n", self.tree, partial=False), ([], 0))

    def test_text_in_comments_and_strings_does_not_count(self):
        (self.tree / "Tests" / "AlphaTests" / "A.swift").write_text(
            '// @Suite struct AlphaTests { @Test func fake() {} }\nlet s = "struct AlphaTests { @Test }"\n'
            '/* struct AlphaTests { @Test func x() {} } */\n'
        )
        self.assertEqual(tracer.check(["AlphaTests"], self.tree), ["suite `AlphaTests` not found under Tests/"])
        (self.tree / "Tests" / "AlphaTests" / "B.swift").write_text(
            '@Suite struct AlphaTests {\n  // @Test func commented() {}\n  let note = "@Test"\n}\n'
        )
        self.assertEqual(tracer.check(["AlphaTests"], self.tree), ["suite `AlphaTests` exists but contains no tests"])

    def test_raw_strings_nested_comments_and_if_false_do_not_count(self):
        samples = [
            "/* /* */ @Suite struct AlphaTests { @Test func fake() {} } */",
            'let s = #"a" @Suite struct AlphaTests { @Test func fake() {} } "b"#',
            'let t = #"""\n """ @Suite struct AlphaTests { @Test func fake() {} }\n"""#',
            "#if false\n@Suite struct AlphaTests { @Test func fake() {} }\n#endif",
        ]
        for sample in samples:
            (self.tree / "Tests" / "AlphaTests" / "A.swift").write_text(sample + "\n")
            self.assertEqual(tracer.check(["AlphaTests"], self.tree), ["suite `AlphaTests` not found under Tests/"], sample)

    def test_nested_if_inside_if_false_is_skipped_entirely(self):
        (self.tree / "Tests" / "AlphaTests" / "A.swift").write_text(
            "#if false\n#if DEBUG\n#endif\n@Suite struct AlphaTests { @Test func fake() {} }\n#endif\n"
        )
        self.assertEqual(tracer.check(["AlphaTests"], self.tree), ["suite `AlphaTests` not found under Tests/"])

    def test_declared_target_is_found_and_explicit_path_is_honoured(self):
        (self.tree / "Package.swift").write_text(
            '.testTarget(name: "AlphaTests", dependencies: ["Alpha"])\n'
            '.testTarget(name: "BetaTests", dependencies: [], path: "Checks/Beta")\n'
        )
        (self.tree / "Tests" / "AlphaTests" / "A.swift").write_text("@Suite struct AlphaTests { @Test func ok() {} }\n")
        (self.tree / "Checks" / "Beta").mkdir(parents=True)
        (self.tree / "Checks" / "Beta" / "B.swift").write_text("@Suite struct BetaTests { @Test func ok() {} }\n")
        self.assertEqual(tracer.test_target_paths(self.tree), [self.tree / "Tests/AlphaTests", self.tree / "Checks/Beta"])
        self.assertEqual(tracer.check(["AlphaTests", "BetaTests"], self.tree), [])

    def test_real_repo_manifest_declares_its_suites(self):
        repo = Path(__file__).resolve().parent.parent.parent
        if not (repo / "Package.swift").exists():
            self.skipTest("no repo manifest")
        names = [p.name for p in tracer.test_target_paths(repo)]
        self.assertIn("HailProtocolTests", names)

    def test_commented_test_target_in_manifest_does_not_count(self):
        (self.tree / "Package.swift").write_text('// .testTarget(name: "AlphaTests")\n/* .testTarget(name: "AlphaTests") */\n')
        self.assertEqual(tracer.test_target_paths(self.tree), [])

    def test_manifest_with_no_test_targets_searches_nothing(self):
        (self.tree / "Package.swift").write_text('.target(name: "Alpha")\n')
        (self.tree / "Tests" / "AlphaTests" / "A.swift").write_text("@Suite struct AlphaTests { @Test func ok() {} }\n")
        self.assertEqual(tracer.check(["AlphaTests"], self.tree), ["suite `AlphaTests` not found under Tests/"])

    def test_manifest_path_escape_is_ignored(self):
        (self.tree / "Package.swift").write_text('.testTarget(name: "AlphaTests", dependencies: [], path: "../elsewhere")\n')
        self.assertEqual(tracer.test_target_paths(self.tree), [])

    def test_only_declared_test_targets_are_searched(self):
        (self.tree / "Package.swift").write_text('.testTarget(name: "AlphaTests", dependencies: [])\n')
        (self.tree / "Tests" / "Orphan").mkdir()
        (self.tree / "Tests" / "Orphan" / "O.swift").write_text("@Suite struct BetaTests { @Test func ok() {} }\n")
        self.assertEqual(tracer.check(["BetaTests"], self.tree), ["suite `BetaTests` not found under Tests/"])

    def test_non_utf8_file_does_not_crash(self):
        (self.tree / "Tests" / "AlphaTests" / "Bin.swift").write_bytes(b"\xff\xfe@Suite struct AlphaTests { @Test func ok() {} }")
        self.assertEqual(tracer.check(["AlphaTests"], self.tree), [])


if __name__ == "__main__":
    unittest.main()
