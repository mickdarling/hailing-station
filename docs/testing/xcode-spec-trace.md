# Declared Xcode test discovery (#143)

Spec traceability is presence evidence, not a test runner. The checker proves that a named Swift suite
has at least one recognizable test declaration in supported declared test sources. Build success,
simulator execution, UI assertions, installed TestFlight metadata, and physical-device acceptance each
need their own evidence. Discovering `StationBuildFooterTests` does not establish any of those results.

## Supported metadata

The trusted base-branch checker reads the PR tree as data. It unions the existing `Package.swift`
`.testTarget` paths with sources explicitly declared in the repository-root `project.yml` under
`bundle.ui-testing` or `bundle.unit-test` targets. It does not run XcodeGen or PR code, read generated
projects, recursively find nested project specifications, or scan every `Tests` directory. For example:

```yaml
targets:
  Hail-iOSUITests:
    type: bundle.ui-testing
    platform: iOS
    sources:
      - Tests/Hail-iOSUITests
```

Supported sources are a literal relative path, a list of such paths, or source mappings containing only
`path`, optional `type: group` / `type: file`, and optional `buildPhase: sources`. A source may be a Swift
file or a directory source group. A directory with an extension needs explicit `type: group`; an explicit
`type: file` directory is not recursively treated as compiled sources. Paths must stay inside the tree
and cannot traverse symlinks. Symlinked manifests, source roots, ancestor directories, and Swift files
do not count. Swift comments, strings, literal `#if false` blocks, and suites without tests still fail.

A tree with neither manifest retains the legacy `Tests/` fallback. An existing manifest with no test
targets does not trigger that fallback: removing the target while leaving its files behind still fails.
The separately located installed-app harness specification is not implicitly discovered.

## Fail-closed boundary

The YAML parser uses a safe data loader and a 1 MiB root metadata limit. Malformed YAML, non-string or
duplicate keys, custom tags, aliases, and `:REPLACE` merge overrides are rejected. Unsupported project
`include`, `configFiles`, `options.fileTypes`, non-group `options.defaultSourceDirectoryType`, target
templates/config files, settings groups, conditional or unconditional source-file-name filters, and
source selection options such as includes/excludes or non-source build phases are not interpreted.
The checker emits an actionable `Xcode test discovery:` diagnostic identifying the unsupported form.
Use concrete unfiltered compile sources, or extend the checker with reviewed fixtures before adopting
another form. Named `trace: partial` suite deferrals cannot hide metadata diagnostics.

These constraints are intentionally narrower than the [XcodeGen project specification](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md).
They do not validate the entire build specification, require a suite to run in a particular scheme, or
resolve Swift conditional compilation beyond the existing literal-false safeguard.

## Local and CI verification

Use an isolated environment; no managed/system Python installation is needed:

```sh
python3 -m venv /tmp/hailing-spec-trace-venv
/tmp/hailing-spec-trace-venv/bin/python -m pip install -r scripts/spec-trace-requirements.txt
/tmp/hailing-spec-trace-venv/bin/python -m unittest scripts/tests/test_trace.py
SPEC_TRACE_PYTHON=/tmp/hailing-spec-trace-venv/bin/python scripts/verify.sh all
/tmp/hailing-spec-trace-venv/bin/python scripts/spec_trace.py --spec-body /path/to/spec-body.md --tree /path/to/tree
```

The requirements pin PyYAML 6.0.3; the checker rejects missing or different versions with setup guidance.
The local `scripts`/`all` verification lane runs the checker unit tests with `SPEC_TRACE_PYTHON` when set.
Otherwise it provisions the pinned dependency in a fresh temporary virtual environment and removes that
environment after the lane, including on failure. This makes fresh verification/CI environments work
without a managed/system install. The `pull_request_target` workflow provisions its own virtual
environment under `RUNNER_TEMP`, installs the pinned dependency from the trusted base checkout, and
uses that same executable for checker tests and final trace before/after reading the separate PR tree.
No dependency manifest, checker, XcodeGen command, or test code from that PR tree is executed by the
privileged traceability lane.

Regression fixtures cover declared UI/unit test targets, mixed SwiftPM/Xcode roots, explicit Swift files,
undeclared/removed/non-test targets, commented/string declarations, empty/stub/disabled suites, absolute
and escaping paths, symlinks, malformed/ambiguous YAML, filtering and merge overrides. The existing
SwiftPM discovery and named partial-trace tests remain part of the same suite.

## Draft verification (2026-09-29)

The initial draft verification below used base `9be504bd504d6f1120ea72970bef77ceb2b2bbf7`, before the
coordinated version/base update. At that point the reserved 0.1.13 change had not been made. This is
historical draft evidence, not a current-head approval.

- Dedicated virtual environment provisioned PyYAML 6.0.3 from the pinned requirements; checker unit tests:
  36 passed (`artifacts/spec-trace-draft-unit.log`).
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/verify.sh scripts` passed using its
  default fresh temporary-venv provisioning: 36 checker tests, 5 local-intent tests, 1 reply-CLI test,
  shell checks, TestFlight script checks, and actionlint (`artifacts/spec-trace-draft-scripts.log`).
- Offline issue #143 named-path trace: 2 expectations, 0 problems (`artifacts/spec-trace-draft-issue143.log`).
- The draft checker read the untouched main tree at `9e698c2e392463173ef3fffc9c6e7c6096804780`:
  `StationBuildInfoTests` and `StationBuildFooterTests` both discovered without partial deferral,
  2 expectations / 0 problems (`artifacts/spec-trace-draft-footer-presence.log`). This was read-only
  presence checking, not a UI run or fresh physical TestFlight evidence.
- An intentional `python -S` missing-dependency probe exited 1 with the expected isolated-environment
  setup guidance (`artifacts/spec-trace-draft-missing-dependency.log`); it is not a passing test run.
- `git diff --check` passed. No application source, footer worktree, device, or installed build was changed.

## Combined stacked verification (2026-09-29)

The draft was preserved in a retained task-specific recovery stash, then reapplied after a fast-forward to frozen host source
`3e56aa7762bbdf5951991918aed62b8f9d54ff93`. Prior ignored logs were preserved. The source marketing
version is now 0.1.13. This is a stacked tree awaiting PR147's merge, not the final merged-base commit;
source-tree equality and final exact-head review remain pending. Host source changes from review would
require updated combined verification.

- The first captured `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/verify.sh all`
  run passed: 479 Swift tests in 82 suites, audit CLI, strict repository lint, script/TestFlight checks,
  36 checker unit tests using automatic isolated dependency provisioning, 5 local-intent tests,
  1 reply-CLI test, and actionlint (`artifacts/spec-trace-013-all.log`). No rerun was needed.
- The separately captured checker run passed 36 tests (`artifacts/spec-trace-013-unit.log`).
- `scripts/verify.sh sim` with the same Xcode selection passed build-for-testing
  (`artifacts/spec-trace-013-sim.log`). This did not execute simulator UI tests.
- The resulting app and UI-test bundle Info.plists both report marketing version 0.1.13 and build 1
  (`artifacts/spec-trace-013-app-metadata.log`, `artifacts/spec-trace-013-uitest-metadata.log`). These
  are simulator build products, not installed TestFlight metadata.
- Offline issue #143 trace passed: 2 named paths, 0 problems (`artifacts/spec-trace-013-issue143.log`).
  Both named footer suites also discovered in this combined tree without partial deferral: 2 expectations,
  0 problems (`artifacts/spec-trace-013-footer-presence.log`). Presence is not new footer UI execution.
- Four production files change under the actual PR-shape exclusions: checker, verification script,
  traceability workflow, and project version manifest. Tests, this document, and the pinned `.txt`
  requirements are excluded by that checker; no exclusion or gate was changed.
- No application/host source outside the version manifest, footer worktree, installed build, physical
  device, live capture, model, or TestFlight delivery was changed. No commit, push, or PR was created.

PR147 subsequently merged as `a3dc924b965774db1d216afdba0bfa2edf512af6`. An exact Git tree comparison
against the tested host source `3e56aa7762bbdf5951991918aed62b8f9d54ff93` showed no differences.
The combined verification therefore covers the merged host contents. Committing/rebasing this checker
slice and independent exact-head reviews remain separate from that test evidence.
