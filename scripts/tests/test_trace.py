"""Tests for scripts/spec_trace.py (#27). Run: python3 -m unittest scripts/tests/test_trace.py"""
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
