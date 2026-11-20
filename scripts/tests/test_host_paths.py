"""Synthetic Git repositories for the host-path guard and opt-in hook (#1270)."""
from itertools import product
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "scripts/check-host-paths.py"
ZERO = "0" * 40
# Assemble synthetic home paths so these fixtures themselves pass the guard.
BAD = "/" + "Users/" + "someone/x"
LINUX_BAD = "/" + "home/" + "example/x"


def separator_forms(root, name, suffix="/work"):
    parts = ("/" + root + "/" + name + suffix).split("/")
    for separators in product(("/", r"\/", "//"), repeat=len(parts) - 1):
        yield parts[0] + "".join(separator + part for separator, part in zip(separators, parts[1:]))


class HostPathsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="hailing-host-paths-")
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name) / "repo"
        self.repo.mkdir()
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_AUTHOR_NAME="Example", GIT_AUTHOR_EMAIL="example@example.invalid",
                        GIT_COMMITTER_NAME="Example", GIT_COMMITTER_EMAIL="example@example.invalid")
        self.git("init", "-q", "-b", "main")
        self.git("config", "commit.gpgsign", "false")
        self.write("notes.md", "safe\n")
        self.base = self.commit("base")

    def run_command(self, command, *, cwd=None, stdin=None):
        return subprocess.run(command, cwd=cwd or self.repo, env=self.env, input=stdin,
                              capture_output=True, text=True, timeout=15)

    def git(self, *args):
        result = self.run_command(["git", *args])
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def write(self, name, content):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def commit(self, subject):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", subject)
        return self.git("rev-parse", "HEAD")

    def check(self, base=None, head="HEAD", *, code=0, stdin=None, remote="origin", cwd=None):
        args = ["--stdin-pre-push", "--remote", remote] if stdin is not None else [f"{base or self.base}..{head}"]
        result = self.run_command([sys.executable, str(CHECKER), *args], cwd=cwd, stdin=stdin)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def push_line(self, head, previous=ZERO):
        return f"refs/heads/topic {head} refs/heads/topic {previous}\n"

    def patterns(self, content):
        path = self.repo / ".git/info/host-path-patterns"
        path.write_text(content, encoding="utf-8")

    def test_intermediate_commit_is_reported_after_cleanup(self):
        self.write("notes.md", "safe\n" + BAD + "\n")
        bad = self.commit("intermediate path")
        self.write("notes.md", "safe\nclean\n")
        self.commit("clean final tree")
        output = self.check(code=1)
        self.assertIn(f"{bad[:12]}: notes.md:2:", output)
        self.assertIn("git commit-tree", output)
        self.assertIn("squash merge does not remove intermediate commits", output)
        self.assertNotIn(BAD, output)

    def test_placeholders_and_standard_system_paths_pass(self):
        self.write("paths.md", "\n".join([
            "/Users/<you>/work", "/Users/me/work", "/home/<you>/work", "/home/me/work",
            "/Applications/Xcode.app/Contents/Developer", "/usr/bin/python3", "/opt/homebrew/bin/tool",
            "/System/Library/Frameworks", "/Library/Application Support/example",
        ]))
        self.commit("document placeholders")
        self.check()

    def test_linux_home_and_multiple_matches_on_a_line(self):
        self.write("paths.md", LINUX_BAD + "\n/Users/me/work " + BAD + "\n")
        bad = self.commit("home paths")
        output = self.check(code=1)
        self.assertIn(f"{bad[:12]}: paths.md:1:", output)
        self.assertIn("paths.md:2:", output)

    def test_allowlist_is_exact(self):
        self.write("paths.md", "/" + "Users/me-other/work\n/" + "home/<someone>/work\n")
        self.commit("lookalikes")
        output = self.check(code=1)
        self.assertIn("paths.md:1:", output)
        self.assertIn("paths.md:2:", output)

    def test_non_personal_home_components_pass_case_insensitively(self):
        paths = [path for root, name in [("Users", "Shared"), ("home", "linuxbrew"), ("home", "runner")]
                 for root, name in [(root, name), (root.upper(), name.upper())]
                 for suffix in ["/work", ""] for path in separator_forms(root, name, suffix)]
        self.write("paths.md", "\n".join(paths))
        self.commit("non-personal homes\n\n" + "\n".join(paths))
        self.check()

    def test_non_personal_home_allowances_require_complete_components_and_root(self):
        names = [("Users", "SharedX"), ("home", "linuxbrew2"), ("home", "runner-x"),
                 ("home", "Shared"), ("Users", "linuxbrew"), ("Users", "runner"),
                 ("Users", "Shared "), ("home", "linuxbrew\r")]
        for root, name in names:
            with self.subTest(root=root, name=name):
                base = self.git("rev-parse", "HEAD")
                path = "/" + root + "/" + name + "/work"
                self.write("paths.md", path + "\n")
                self.commit("home component boundary\n\n" + path)
                output = self.check(base=base, code=1)
                self.assertIn("paths.md:1:", output)
                self.assertIn(": commit message:", output)

    def test_only_explicit_github_api_user_endpoints_pass(self):
        paths = [prefix + "users/" + login + suffix
                 for prefix in ["https://api.github.com/", "api.github.com/", "gh api ", "gh api /"]
                 for login in ["example", "example-user", "<login>"]
                 for suffix in ["", "/repos", ";echo safe", ")", " safe", "?per_page=10", "`"]]
        paths += [path.replace("/", r"\/") for path in paths]
        self.write("urls.md", "\n".join(paths))
        self.commit("explicit GitHub API endpoints\n\n" + "\n".join(paths))
        self.check()

    def test_url_masking_bypasses_are_reported(self):
        home = "/" + "Users/" + "someone"
        paths = ["x://y" + home + "/work",
                 "vscode://file" + home + "/project/File.swift:12",
                 "ssh://host.local" + home + "/repo.git",
                 "smb://nas" + home,
                 "http://localhost:8000" + home + "/x",
                 "echo https://host/safe;" + home + "/work",
                 "file:///x://y" + home + "/work",
                 "[link](https://example.com)" + home + "/x"]
        paths += [path.replace("/", r"\/") for path in paths]
        self.write("bypasses.md", "\n".join(paths))
        self.commit("URL bypass regressions\n\n" + "\n".join(paths))
        output = self.check(code=1)
        for number in range(1, len(paths) + 1):
            self.assertIn(f"bypasses.md:{number}:", output)
        self.assertIn(": commit message:", output)

    def test_all_other_urls_and_separate_home_paths_are_reported(self):
        paths = [scheme + "://" + host + path
                 for scheme in ["file", "FILE", "http", "https", "HTTPS", "ssh", "smb", "vscode", "x"]
                 for host in ["", "localhost", "host.local", "example.com", "api.github.com"]
                 for home in [BAD, LINUX_BAD, BAD.replace("Users", "users")]
                 for path in [home, "/v1" + home]
                 if not (scheme == "https" and host == "api.github.com"
                         and home == BAD.replace("Users", "users") and path == home)]
        paths += [path.replace("/", r"\/") for path in paths]
        paths += ["https://host/" + "users/example " + BAD, "gh api /users/example " + LINUX_BAD,
                  "https://host/safe?path=" + BAD, "https://host/safe#" + LINUX_BAD,
                  "https:/host" + BAD, "https://" + BAD, "other-gh api " + BAD,
                  "gh api --verbose " + BAD, "gh api /users/example;cat<" + BAD]
        paths += [prefix + BAD.replace("Users", "users")
                  for prefix in ["http://api.github.com", "HTTPS://api.github.com", "https://API.GITHUB.COM",
                                 "https://api.github.com:443", "https://api.github.com.evil",
                                 "https://host/api.github.com", "file:///https://api.github.com", "other-gh api "]]
        self.write("urls.md", "\n".join(paths))
        self.commit("checked URL forms\n\n" + "\n".join(paths))
        output = self.check(code=1)
        for number in range(1, len(paths) + 1):
            self.assertIn(f"urls.md:{number}:", output)
        self.assertIn(": commit message:", output)

    def test_github_api_exception_preserves_all_following_text(self):
        paths = [prefix + "users/example" + separator + home
                 for prefix in ["https://api.github.com/", "api.github.com/", "gh api ", "gh api /"]
                 for separator in ["", "/repos", ";", ")", " ", "\t", "?path=", "#"]
                 for home in [BAD, LINUX_BAD, BAD.replace("Users", "users")]]
        paths += ["gh api " + BAD, "gh api " + BAD.replace("Users", "USERS")]
        paths += [path.replace("/", r"\/") for path in paths]
        for path in paths:
            with self.subTest(path=path):
                base = self.git("rev-parse", "HEAD")
                self.write("paths.md", path + "\n")
                self.commit("API endpoint followed by a home\n\n" + path)
                output = self.check(base=base, code=1)
                self.assertIn("paths.md:1:", output)
                self.assertIn(": commit message:", output)

    def test_parent_component_after_allowed_home_is_rejected(self):
        paths = [path for root, name in [("Users", "me"), ("home", "<you>"), ("Users", "Shared"),
                                        ("home", "linuxbrew"), ("home", "runner")]
                 for suffix in ["/../someone/work", "/.."]
                 for path in separator_forms(root, name, suffix)]
        self.write("parents.md", "\n".join(paths))
        self.commit("parent components\n\n" + "\n".join(paths))
        output = self.check(code=1)
        for number in range(1, len(paths) + 1):
            self.assertIn(f"parents.md:{number}:", output)
        self.assertIn(": commit message:", output)
        base = self.git("rev-parse", "HEAD")
        self.write("safe.md", "/Users/me/..safe/work\n/Users/me/subdir/../work\n")
        self.commit("ordinary components")
        self.check(base=base)

    def test_later_parent_components_cannot_climb_above_allowed_home(self):
        paths = [path for root, name in [("Users", "me"), ("home", "<you>"), ("Users", "Shared"),
                                        ("home", "linuxbrew"), ("home", "runner")]
                 for suffix in ["/./../someone/", "/x/../../someone/", "/x/../.."]
                 for path in separator_forms(root, name, suffix)]
        self.write("parents.md", "\n".join(paths))
        self.commit("later parent traversal\n\n" + "\n".join(paths))
        output = self.check(code=1)
        for number in range(1, len(paths) + 1):
            self.assertIn(f"parents.md:{number}:", output)
        self.assertIn(": commit message:", output)
        base = self.git("rev-parse", "HEAD")
        paths = [path for suffix in ["/./work", "/x/../work", "/x/y/../../work", "/x/..", "/x/..safe/../work"]
                 for path in separator_forms("Users", "me", suffix)]
        self.write("safe.md", "\n".join(paths))
        self.commit("traversal stays inside home\n\n" + "\n".join(paths))
        self.check(base=base)

    def test_local_patterns_override_non_personal_and_github_api_exemption(self):
        paths = ["/" + root + "/" + name + "/work"
                 for root, name in [("Users", "Shared"), ("home", "linuxbrew"), ("home", "runner")]]
        paths += ["https://host" + BAD, "http://host" + LINUX_BAD,
                  "gh api /users/example", "gh api users/example"]
        paths += [prefix + "users/example" for prefix in ["https://api.github.com/", "api.github.com/"]]
        for path in paths:
            with self.subTest(path=path):
                self.patterns("work|example|someone\n")
                base = self.git("rev-parse", "HEAD")
                escaped = path.replace("/", r"\/")
                self.write("local.md", escaped + "\n")
                self.commit("local rule\n\n" + escaped)
                output = self.check(base=base, code=1)
                self.assertIn("local.md:1:", output)
                self.assertIn(": commit message:", output)

    def test_complete_home_component_boundaries_and_json_escapes(self):
        paths = []
        for root in ["Users", "home"]:
            for name in ["me real", r"me\real", "me\\", 'me"x', "me-real", "<you>x"]:
                for suffix in ["/work", ""]:
                    # A single backslash before / is now an escaped separator.
                    # Double it here to retain a literal backslash in the component.
                    component = name + ("\\" if suffix and name.endswith("\\") else "")
                    path = "/" + root + "/" + component + suffix
                    paths.extend([path, path.replace("/", r"\/")])
        self.write("boundaries.md", "\n".join(paths))
        self.commit("complete directory components")
        output = self.check(code=1)
        for number in range(1, len(paths) + 1):
            self.assertIn(f"boundaries.md:{number}:", output)

    def test_exact_placeholders_at_path_end_and_json_escapes_pass(self):
        paths = []
        for root in ["Users", "home"]:
            for name in ["me", "<you>"]:
                for suffix in ["/work", ""]:
                    path = "/" + root + "/" + name + suffix
                    paths.extend([path, path.replace("/", r"\/")])
        self.write("placeholders.md", "\n".join(paths))
        self.commit("exact placeholders")
        self.check()

    def test_json_escaped_home_paths_are_rejected(self):
        self.write("paths.json", "\n".join(path.replace("/", r"\/") for path in [BAD, LINUX_BAD]))
        self.commit("escaped home directories")
        output = self.check(code=1)
        self.assertIn("paths.json:1:", output)
        self.assertIn("paths.json:2:", output)

    def test_normalized_home_paths_in_content_and_commit_messages_are_rejected(self):
        paths = [path for root in ["Users", "home", "users", "HOME"]
                 for path in separator_forms(root, "someone")]
        # JSON quotes also exercise the reported mixed-escape bypass.
        self.write("paths.json", "\n".join('"' + path + '"' for path in paths))
        self.commit("normalized content")
        output = self.check(code=1)
        for number in range(1, len(paths) + 1):
            self.assertIn(f"paths.json:{number}:", output)
        base = self.git("rev-parse", "HEAD")
        for path in paths:
            with self.subTest(path=path):
                self.git("commit", "--allow-empty", "-qm", "safe subject\n\n\"" + path + '"')
                output = self.check(base=base, code=1)
                self.assertIn(": commit message:", output)
                self.assertNotIn(path, output)
                base = self.git("rev-parse", "HEAD")

    def test_normalized_placeholders_and_system_paths_pass(self):
        paths = [path for root in ["Users", "home", "users", "HOME"]
                 for name in ["me", "<you>"] for suffix in ["/work", ""]
                 for path in separator_forms(root, name, suffix)]
        for path in ["/Applications/Xcode.app/Contents/Developer", "/usr/bin/python3",
                     "/opt/homebrew/bin/tool", "/System/Library/Frameworks",
                     "/Library/Application Support/example"]:
            paths.extend([path, path.replace("/", r"\/"), path.replace("/", "//"),
                          path.replace("/", r"\//")])
        self.write("placeholders.md", "\n".join(paths))
        self.commit("normalized placeholders and system paths\n\n" + "\n".join(paths))
        self.check()

    def test_complete_components_preserve_interior_cr_and_other_characters(self):
        names = ["me\rreal", "<you>\rreal", "me\r", "me\r\r", "me\t", "me\v", "me\f",
                 "me\u0085", "me\u2028", 'me"', "<you>'", "ME", "<YOU>"]
        paths = ["/" + root + "/" + name + "/work" for root in ["Users", "home"] for name in names]
        self.write("components.md", "\n".join(paths) + "\n")
        self.commit("complete components")
        output = self.check(code=1)
        for number in range(1, len(paths) + 1):
            self.assertIn(f"components.md:{number}:", output)
        base = self.git("rev-parse", "HEAD")
        for path in paths:
            self.git("commit", "--allow-empty", "--cleanup=verbatim", "-qm", "safe subject\n\n" + path)
            self.assertIn(": commit message:", self.check(base=base, code=1))
            base = self.git("rev-parse", "HEAD")

    def test_crlf_is_allowed_but_unterminated_or_extra_cr_is_not(self):
        paths = [path for root in ["Users", "home"] for name in ["me", "<you>"]
                 for path in separator_forms(root, name, "")]
        content = "\r\n".join(paths) + "\r\n"
        self.write("endings.md", content)
        self.commit("CRLF placeholders")
        self.git("commit", "--allow-empty", "--cleanup=verbatim", "-qm", "safe subject\n\n" + content)
        self.check()
        base = self.git("rev-parse", "HEAD")
        # Exercise the modified-blob patch parser as well as newly added blobs.
        self.write("endings.md", content + "/" + "Users/" + "me\r\n")
        self.commit("modified CRLF placeholder")
        self.check(base=base)
        for ending in ["\r", "\r\r\n"]:
            base = self.git("rev-parse", "HEAD")
            self.write("unterminated.md", "/" + "Users/" + "me" + ending)
            self.write("endings.md", content + "/" + "home/" + "<you>" + ending)
            self.commit("non-CRLF carriage return")
            output = self.check(base=base, code=1)
            self.assertIn("unterminated.md:1:", output)
            self.assertIn(f"endings.md:{len(paths) + 1}:", output)
            base = self.git("rev-parse", "HEAD")
            self.git("commit", "--allow-empty", "-qm", "safe subject")
            # Even --cleanup=verbatim with -m adds LF; write the exact message.
            header = self.git("cat-file", "commit", "HEAD").split("\n\n", 1)[0]
            result = self.run_command(["git", "hash-object", "-t", "commit", "-w", "--stdin"],
                                      stdin=header + "\n\nsafe subject\n\n/" + "Users/" + "me" + ending)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.git("update-ref", "HEAD", result.stdout.strip())
            self.assertIn(": commit message:", self.check(base=base, code=1))

    def test_quoted_placeholders_need_a_trailing_separator(self):
        paths = ['"' + path + '"' for name in ["me", "<you>"]
                 for path in separator_forms("Users", name, "")]
        self.write("quoted.md", "\n".join(paths))
        self.commit("quoted placeholders")
        output = self.check(code=1)
        for number in range(1, len(paths) + 1):
            self.assertIn(f"quoted.md:{number}:", output)

    def test_offending_subject_is_never_printed(self):
        self.write("notes.md", BAD + "\n")
        subject = "private subject " + BAD
        head = self.commit(subject)
        result = self.run_command([sys.executable, str(CHECKER), f"{self.base}..HEAD"])
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"{head[:12]}: notes.md:1:", result.stdout)
        self.assertIn(f"{head[:12]}: commit message:", result.stdout)
        for stream in [result.stdout, result.stderr]:
            self.assertNotIn(subject, stream)
            self.assertNotIn(BAD, stream)

    def test_full_commit_message_including_cleaned_intermediate_is_checked(self):
        self.write("notes.md", "safe change\n")
        message = "safe subject\n\nprivate body " + LINUX_BAD + "\nlast paragraph"
        bad = self.commit(message)
        self.git("commit", "--allow-empty", "-qm", "clean subsequent message")
        output = self.check(code=1)
        self.assertIn(f"{bad[:12]}: commit message: host-specific path", output)
        self.assertNotIn(LINUX_BAD, output)
        self.assertNotIn("private body", output)
        self.assertNotIn("notes.md:", output)

    def test_commit_messages_use_local_patterns_over_full_message(self):
        self.patterns(r"private start\nprivate finish" + "\n")
        self.write("notes.md", "safe change\n")
        self.commit("safe subject\n\nprivate start\nprivate finish")
        output = self.check(code=1)
        self.assertIn(": commit message:", output)
        self.assertNotIn("private start", output)
        self.assertNotIn("notes.md:", output)

    def test_commit_messages_apply_local_patterns_to_placeholders(self):
        self.patterns("/Users/me/\n")
        self.git("commit", "--allow-empty", "-qm", "safe subject\n\n/Users/me/work")
        self.assertIn(": commit message:", self.check(code=1))

    def test_commit_messages_share_home_boundaries_and_json_rules(self):
        base = self.base
        for root in ["Users", "home"]:
            for name in ["me real", r"me\real", "me\\", 'me"x', "me-real", "<you>x", "someone"]:
                component = name + ("\\" if name.endswith("\\") else "")
                path = ("/" + root + "/" + component + "/work").replace("/", r"\/")
                self.git("commit", "--allow-empty", "-qm", "safe subject\n\n" + path)
                self.assertIn(": commit message:", self.check(base=base, code=1))
                base = self.git("rev-parse", "HEAD")
        self.git("commit", "--allow-empty", "-qm", "safe subject\n\n/Users/me/work\n/home/<you>/work")
        self.check(base=base)

    def test_local_patterns_ignore_comments_and_blanks(self):
        self.patterns("\n  # comment\n/srv/example-private/\\w+\n")
        self.write("paths.md", "/srv/example-private/work\n")
        self.commit("local pattern")
        output = self.check(code=1)
        self.assertIn("paths.md:1:", output)
        self.assertNotIn("example-private", output)
        self.assertNotIn("host-path-patterns", self.git("ls-files"))

    def test_local_patterns_also_apply_to_placeholders(self):
        self.patterns("/Users/me/\n")
        self.write("paths.md", "/Users/me/work\n")
        self.commit("locally blocked placeholder")
        self.check(code=1)

    def test_local_patterns_see_raw_and_normalized_content_and_messages(self):
        raw = r"\/srv//example-private\/work"
        for pattern in [r"\\/srv//example-private\\/work", "/srv/example-private/work"]:
            with self.subTest(pattern=pattern):
                self.patterns(pattern + "\n")
                base = self.git("rev-parse", "HEAD")
                self.write("local.md", "safe\n" + raw + "\n")
                self.commit("safe subject\n\n" + raw)
                output = self.check(base=base, code=1)
                self.assertIn("local.md:2:", output)
                self.assertIn(": commit message:", output)
                self.assertNotIn(raw, output)
                self.assertNotIn("example-private", output)
                # Ensure the next iteration also adds the line.
                self.write("local.md", "safe\n")
                self.commit("remove synthetic local path")

    def test_local_patterns_see_normalized_full_message(self):
        self.patterns(r"private start\n/srv/example-private/work" + "\n")
        self.git("commit", "--allow-empty", "-qm",
                 "safe subject\n\nprivate start\n" + r"\/srv//example-private\/work")
        self.assertIn(": commit message:", self.check(code=1))

    def test_local_patterns_only_see_real_added_lines(self):
        self.patterns("^$\n")
        self.write("empty.md", "")
        self.write("terminated.md", "safe\n")
        self.commit("no added blank lines")
        self.check()
        self.write("terminated.md", "safe\n\n")
        self.commit("one added blank line")
        self.assertIn("terminated.md:2:", self.check(code=1))

    def test_invalid_local_regex_fails_without_disclosing_pattern(self):
        self.patterns("# comment\n[example-private\n")
        output = self.check(code=2)
        self.assertIn("invalid regex on line 2", output)
        self.assertNotIn("example-private", output)

    def test_preexisting_content_is_not_flagged_in_changed_file(self):
        self.write("notes.md", BAD + "\nsafe\n")
        base = self.commit("preexisting content")
        self.write("notes.md", BAD + "\nchanged\n")
        self.commit("change another line")
        self.check(base=base)

    def test_deleted_files_and_binary_additions_and_changes_are_skipped(self):
        self.write("old.md", BAD)
        (self.repo / "old.bin").write_bytes(b"\0" + BAD.encode())
        base = self.commit("preexisting files")
        (self.repo / "old.md").unlink()
        (self.repo / "old.bin").write_bytes(b"\0changed " + BAD.encode())
        (self.repo / "new.bin").write_bytes(b"\0" + BAD.encode())
        self.commit("delete and binary files")
        self.check(base=base)

    def test_rename_preserves_unchanged_lines(self):
        self.write("old.md", BAD + "\nsafe\n" * 10)
        base = self.commit("preexisting path")
        self.git("mv", "old.md", "new.md")
        self.commit("rename only")
        self.check(base=base)
        self.git("mv", "new.md", "renamed.md")
        self.write("renamed.md", BAD + "\nsafe\n" * 10 + "changed\n")
        self.commit("rename and edit")
        self.check(base=base)
        self.git("mv", "renamed.md", "new.md")
        self.write("new.md", BAD + "\nsafe\n" * 10 + LINUX_BAD + "\n")
        self.commit("change renamed file")
        self.assertIn("new.md:21:", self.check(base=base, code=1))

    def test_line_numbers_across_hunks_and_unusual_filename(self):
        name = "odd\tname\nfile.md"
        self.write(name, "\n".join("safe" for _ in range(12)) + "\n")
        base = self.commit("safe lines")
        lines = ["safe"] * 12
        lines[1], lines[10] = BAD, LINUX_BAD
        self.write(name, "\n".join(lines))
        self.commit("two hunks without final newline")
        output = self.check(base=base, code=1)
        self.assertIn(f"{name!r}:2:", output)
        self.assertIn(f"{name!r}:11:", output)

    def test_root_commit_is_scanned(self):
        self.git("checkout", "--orphan", "unrelated")
        self.write("notes.md", BAD + "\n")
        self.commit("root path")
        self.assertIn("notes.md:1:", self.check(code=1))

    def test_all_side_branch_commits_are_scanned(self):
        self.git("checkout", "-b", "side")
        self.write("side.md", BAD + "\n")
        bad = self.commit("side intermediate")
        (self.repo / "side.md").unlink()
        self.commit("side cleanup")
        self.git("checkout", "main")
        self.git("merge", "--no-ff", "side", "-m", "merge clean side")
        self.assertIn(f"{bad[:12]}:", self.check(code=1))

    def test_merge_commit_is_diffed_against_first_parent(self):
        self.git("checkout", "-b", "side")
        self.write("side.md", "safe\n")
        self.commit("safe side")
        self.git("checkout", "main")
        self.git("merge", "--no-ff", "--no-commit", "side")
        self.write("merge.md", BAD + "\n")
        merge = self.commit("merge adds path")
        self.assertIn(f"{merge[:12]}: merge.md:1:", self.check(code=1))

    def test_pre_push_new_branch_uses_origin_main_and_skips_delete(self):
        self.git("update-ref", "refs/remotes/origin/main", self.base)
        self.write("notes.md", BAD + "\n")
        bad = self.commit("new branch path")
        self.write("notes.md", "clean\n")
        clean = self.commit("cleanup")
        stdin = self.push_line(clean) + f"(delete) {ZERO} refs/heads/old {self.base}\n"
        output = self.check(stdin=stdin, code=1)
        self.assertIn(f"{bad[:12]}:", output)
        self.check(stdin=f"(delete) {ZERO} refs/heads/old {self.base}\n")

    def test_pre_push_new_branch_uses_merge_base(self):
        self.git("checkout", "-b", "topic")
        self.write("topic.md", "safe\n")
        topic = self.commit("safe topic")
        self.git("checkout", "main")
        self.write("main.md", BAD + "\n")
        main = self.commit("path on main after divergence")
        self.git("update-ref", "refs/remotes/origin/main", main)
        self.check(stdin=self.push_line(topic))

    def test_pre_push_uses_named_remote_default_branch(self):
        self.git("update-ref", "refs/remotes/upstream/trunk", self.base)
        self.git("symbolic-ref", "refs/remotes/upstream/HEAD", "refs/remotes/upstream/trunk")
        self.write("notes.md", BAD + "\n")
        head = self.commit("named remote path")
        self.check(stdin=self.push_line(head), remote="upstream", code=1)

    def test_pre_push_existing_and_overlapping_ranges(self):
        self.write("notes.md", BAD + "\n")
        head = self.commit("existing branch path")
        output = self.check(stdin=self.push_line(head, self.base) * 2, code=1)
        self.assertEqual(output.count(f"{head[:12]}:"), 1)

    def test_pre_push_empty_and_deletion_need_no_default_branch(self):
        self.check(stdin="")
        self.check(stdin=f"(delete) {ZERO} refs/heads/old {ZERO}\n")

    def test_invalid_ranges_and_stdin_fail_closed(self):
        for argument in ["HEAD", "HEAD...HEAD", "..HEAD", "HEAD..", "missing..HEAD"]:
            with self.subTest(argument=argument):
                result = self.run_command([sys.executable, str(CHECKER), argument])
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.check(stdin="malformed\n", code=2)
        self.check(stdin=self.push_line(self.base), code=2)  # No default-branch ref.
        self.check(stdin=self.push_line(self.base, "1" * 40), code=2)  # Missing old remote object.

    def test_patterns_use_common_git_dir_in_linked_worktree(self):
        self.patterns("/srv/example-private/\n")
        linked = Path(self.temporary.name) / "linked"
        self.git("worktree", "add", "-q", "-b", "linked", str(linked))
        (linked / "notes.md").write_text("/srv/example-private/work\n")
        result = self.run_command(["git", "-c", "commit.gpgsign=false", "commit", "-qam", "linked path"], cwd=linked)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("notes.md:1:", self.check(cwd=linked, code=1))

    def copy_hook_scripts(self):
        for relative in ["scripts/install-hooks.sh", "scripts/hooks/pre-push", "scripts/check-host-paths.py"]:
            target = self.repo / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, target)

    def test_installer_is_opt_in_idempotent_and_hook_preserves_stdin(self):
        self.copy_hook_scripts()
        self.assertNotEqual(self.run_command(["git", "config", "--get", "core.hooksPath"]).returncode, 0)
        for _ in range(2):
            result = self.run_command(["scripts/install-hooks.sh"])
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("config", "--local", "--get", "core.hooksPath"), "scripts/hooks")
        self.write("notes.md", BAD + "\n")
        head = self.commit("hook path")
        result = self.run_command(["scripts/hooks/pre-push", "origin", "unused"],
                                  stdin=self.push_line(head, self.base))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("notes.md:1:", result.stdout)

    def test_installer_refuses_existing_hook_configuration(self):
        self.copy_hook_scripts()
        self.git("config", "--local", "core.hooksPath", "other-hooks")
        for args in [[], ["--force"]]:
            result = self.run_command(["scripts/install-hooks.sh", *args])
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("Refusing to replace existing core.hooksPath", result.stderr)
            self.assertEqual(self.git("config", "--local", "--get", "core.hooksPath"), "other-hooks")

    def test_installer_refuses_and_lists_active_default_hooks(self):
        self.copy_hook_scripts()
        for name in ["pre-commit", "pre-push"]:
            self.write(".git/hooks/" + name, "#!/bin/sh\nexit 0\n")
            (self.repo / ".git/hooks" / name).chmod(0o755)
        result = self.run_command(["scripts/install-hooks.sh"])
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Refusing to bypass active hooks", result.stderr)
        for name in ["pre-commit", "pre-push"]:
            self.assertIn("\n  " + name, result.stderr)
        self.assertIn("--force", result.stderr)
        self.assertNotEqual(self.run_command(["git", "config", "--local", "--get", "core.hooksPath"]).returncode, 0)

    def test_installer_ignores_samples_and_nonexecutable_hooks(self):
        self.copy_hook_scripts()
        self.write(".git/hooks/pre-commit.sample", "#!/bin/sh\nexit 0\n")
        (self.repo / ".git/hooks/pre-commit.sample").chmod(0o755)
        self.write(".git/hooks/pre-push", "#!/bin/sh\nexit 0\n")
        (self.repo / ".git/hooks/pre-push").chmod(0o644)
        result = self.run_command(["scripts/install-hooks.sh"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("config", "--local", "--get", "core.hooksPath"), "scripts/hooks")

    def test_installer_force_explicitly_bypasses_active_hooks(self):
        self.copy_hook_scripts()
        content = "#!/bin/sh\nexit 0\n"
        self.write(".git/hooks/pre-push", content)
        hook = self.repo / ".git/hooks/pre-push"
        hook.chmod(0o755)
        result = self.run_command(["scripts/install-hooks.sh", "--force"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("config", "--local", "--get", "core.hooksPath"), "scripts/hooks")
        self.assertEqual(hook.read_text(), content)
        self.assertTrue(os.access(hook, os.X_OK))
        result = self.run_command(["scripts/install-hooks.sh"])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_installer_checks_common_hooks_from_linked_worktree(self):
        self.copy_hook_scripts()
        self.write(".git/hooks/pre-push", "#!/bin/sh\nexit 0\n")
        (self.repo / ".git/hooks/pre-push").chmod(0o755)
        linked = Path(self.temporary.name) / "linked"
        self.git("worktree", "add", "-q", "-b", "linked", str(linked))
        result = self.run_command([str(self.repo / "scripts/install-hooks.sh")], cwd=linked)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("\n  pre-push", result.stderr)
        self.assertNotEqual(self.run_command(["git", "config", "--local", "--get", "core.hooksPath"]).returncode, 0)


if __name__ == "__main__":
    unittest.main()
