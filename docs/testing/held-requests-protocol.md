# Held ambient request protocol verification (#1120, PR 1)

This is a proposed protocol slice only. Neither host nor device advertises `held_requests`, sends these controls,
holds requests, handles decisions, or presents a held-message UI as a result of this change. No host/app behavior,
guard evaluation, context exclusion, retention, audit, deployment, simulator or physical-device proof is claimed.

## Wire contract and synthetic coverage

`HeldRequestsProtocolTests` has 17 test functions (46 case executions). It round-trips the three controls through
`FrameCoding`, all four reasons, both actions, all five outcomes, optional heard-turn correlation, combined match
and timeout, all built-in rule tokens, empty/max-size rule lists, expiry endpoints and the longest refusal token.
It rejects unknown enum values, oversized/wrong-type lists, arbitrary rule names/patterns, long rule tokens,
invalid UUIDs, missing/extra fields, null optional fields, nonintegral/out-of-range expiry and malformed or
misplaced refusal reasons. Invalid constructible values also fail encoding. Existing canonical payloads and the
legacy refusal extension remain decodable. All IDs and contents in tests are synthetic.

`HeldRequestsSchemaTests` adds seven regression methods covering the proposed schema's shapes, UUIDs, bounds,
closed vocabulary, strict fields and conditional refusal token. The lightweight schema validator does not enforce
`uniqueItems`; this test asserts that the schema retains the constraint, and the Swift tests reject duplicate
reasons. The generated schema changed; existing generated frame fixtures did not.

## Dev Work VM verification

A fresh GitHub clone in `~/codex-workspaces/vw1120a` received the unpushed commit by git bundle. Runs were sequential;
each SSH command closed stdin with `< /dev/null`. No Swift build or test ran on the live voice host.

VM-side command:

```sh
WS=vw1120a ~/codex-workspaces/vw327-run.sh HailProtocolTests
```

The supplied run script built tests with `taskpolicy -b swift build --build-tests -j 4`, then ran
`taskpolicy -b swift test --skip-build --no-parallel -j 4 --filter HailProtocolTests`, with its configured CLT
framework/plugin/rpath flags, build path and phase time limits. Final result: `build=0`, `test=0`, **158 tests in
29 suites passed** (0.237 seconds for the test phase). An earlier iteration also passed 158/158 before schema
edge-case hardening. These are synthetic macOS VM iteration results, not shipping Xcode or physical-device proof.

After that run, on the VM in the same workspace:

```sh
taskpolicy -b .build/debug/hail-protocol-gen
python3 -m unittest discover -s Tests/ProtocolSchemaTests
python3 -m unittest scripts/tests/test_check_schema.py
python3 scripts/check_schema.py
```

Results: generator wrote 48 fixtures and the v1 schema; 19 schema regression methods passed; 11 validator methods
passed; the built-in fixture checker accepted 48 positive fixtures and rejected 98 negative fixtures with zero
failures. The regenerated schema was copied back to the worktree.

## Host lint and change size

Each changed Swift file was linted on the host using the requested command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b swiftlint lint --strict Sources/HailProtocol/Control.swift Sources/HailProtocol/HeldRequests.swift Sources/HailProtocol/Schema.swift Tests/HailProtocolTests/HeldRequestsProtocolTests.swift
```

Result: zero violations in four Swift files. `git diff --check` passed. The exact exclusions in
`scripts/pr-shape.py` count **three production files**: `Control.swift`, `HeldRequests.swift`, `Schema.swift`.
Tests, docs and the generated schema JSON are excluded. No PR, push, online review or live delivery was performed.

Host hold/revalidation, stream survival, UI/announcements, context exclusion and audit are deferred to subsequent
#1120 slices; this protocol verification does not claim those acceptance criteria are shipped.
