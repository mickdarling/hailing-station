# Held ambient request protocol verification (#1120, PR 1)

This is a proposed protocol slice only. Neither host nor device advertises `held_requests`, sends these controls,
holds requests, handles decisions, or presents a held-message UI as a result of this change. No host/app behavior,
guard evaluation, context exclusion, retention, audit, deployment, simulator or physical-device proof is claimed.

## Wire contract and synthetic coverage

The following initial evidence records commit `781f4041`. The review follow-up below supersedes its open
refusal-token contract and adds closed-vocabulary regressions; both versions remain protocol-only proposals.

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

## Review follow-up: closed metadata and PROPOSED lifecycle

`HeldRequestRefusalReason` replaces the open refusal string with nine values: `policy_changed`,
`target_unavailable`, `binding_changed`, `selection_changed`, `lockdown`, `denied`, `rate_limited`, `capacity`,
`connection_lost`. The generated schema derives the same enum. `HeldRequestRule` remains closed to the 13
built-in guard tokens plus `custom`. Swift and Python now reject arbitrary names, request fragments, short
hex strings and 32/40/64-character hashes in both metadata fields; every refusal reason round-trips with its
exact wire spelling. Missing refusal reasons and reasons on other outcomes still fail closed.
`HeldRequestRuleVocabularyTests.everyDaemonDefaultHasAClosedWireRule` checks all daemon defaults against the
HailProtocol vocabulary and excludes `custom` as a fallback for a missing built-in.

The **PROPOSED** contract in `docs/reply-protocol.md` maps each refusal to a real host gate and defines
at-most-once decisions, unchanged resolution replay for duplicate/conflicting decisions, late expiry,
unknown-ID `stale`, ambient-stream survival, and content retention separately from expired Send authority.
These lifecycle and retention rules are documentation only; no runtime implementation or device proof is claimed.

The final Swift sources were synced by a temporary git-bundle snapshot to `~/codex-workspaces/vw1120a`.
Each SSH invocation used `< /dev/null`, stayed blocking, and completed before the next VM job. VM commands:

```sh
WS=vw1120a ~/codex-workspaces/vw327-run.sh 'HailProtocolTests'
WS=vw1120a ~/codex-workspaces/vw327-run.sh 'HailDaemonKitTests.HeldRequestRuleVocabularyTests'
cd ~/codex-workspaces/vw1120a
taskpolicy -b .build/debug/hail-protocol-gen
git diff --exit-code -- fixtures/frames
```

Results: both runs reported `build=0`, `test=0`; **160 tests in 30 suites passed** for HailProtocolTests
(0.190 seconds), and **1 test in 1 suite passed** for the daemon vocabulary (0.001 seconds). The same run
script/CLT flags described above were used. The generator wrote 48 fixtures and the v1 schema; frame fixtures
were byte-identical (drift check exit 0). The regenerated schema JSON was copied back to the host.

The Python-only schema commands run on the host under background policy were:

```sh
taskpolicy -b python3 -m unittest discover -s Tests/ProtocolSchemaTests
taskpolicy -b python3 -m unittest scripts/tests/test_check_schema.py
taskpolicy -b python3 scripts/check_schema.py
```

The checker commands are the schema checks used in `.github/workflows/ci.yml`; `scripts/verify.sh` and
`CONTRIBUTING.md` do not enumerate a separate Python schema lane. Results: **21 schema tests passed**,
**11 checker unit tests passed**, **48 positive fixtures accepted and 98 negative fixtures rejected**, zero failures.

Host lint:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b swiftlint lint --strict Sources/HailProtocol/HeldRequests.swift Sources/HailProtocol/Schema.swift Tests/HailProtocolTests/HeldRequestsProtocolTests.swift Tests/HailProtocolTests/HeldRequestsVocabularyTests.swift Tests/HailDaemonKitTests/HeldRequestRuleVocabularyTests.swift
```

Result: **zero violations in five Swift files**. `git diff --check` passed. Exact `scripts/pr-shape.py`
exclusions count **two production files in this follow-up**, `HeldRequests.swift` and `Schema.swift`, and
**three across PR 1**, including `Control.swift`. Tests, docs and generated schema JSON are excluded.
No host Swift build/test, push, simulator build, installation or physical-device validation was performed.
Independent review of this new head remains pending; the earlier REQUEST CHANGES is not an approval.

## Round 2 corrections: retention and frozen compatibility — PROPOSED

This section supersedes the retention/lifecycle and daemon-default mapping contracts in the historical sections
above. The earlier REQUEST CHANGES is not approval of this revision; independent review of the new head is pending.
Everything remains a proposal: no capability advertisement, host retention/decision handler, app UI, deployment,
installation, simulator build or physical-device validation is introduced.

The proposed content disposition is successful Send or explicit Discard only. Every refused Send retains content
and shows its closed reason; expiry ends only the current notice's Send authority. A later Send evaluates every
host gate afresh and a continuing hold produces a fresh notice for the same content/UUID. Disconnect retains
content; authenticated same-device re-offer is explicitly deferred and blocks advertisement, with a visible
"Held on host; disconnected — recovery pending" entry instead of silent loss. Admission is reserved before
acceptance, limited to 8 unresolved holds/reservations per connection allocation and 64 host-wide, with no eviction;
the app visibly retains unadmitted content while asking the owner to resolve a hold. Restart still loses in-memory
content: the app must show `stale` and loss (or uncertain delivery), without automatic resubmission. No persistence
is invented. Privacy-on and lockdown deletion exceptions remain undecided issue-level questions for #1120.

The unshipped `expired` outcome is renamed to `notice_expired` (`HeldRequestOutcome.noticeExpired`); the old token
is now rejected by Swift and schema fixtures. `refused` and `notice_expired` are nonterminal content outcomes.
Only successful Send / explicit Discard are terminal and replay unchanged. Serialization, uncertain-handoff
reconciliation and fresh evaluation remain proposed host requirements, not behavior proven by these wire tests.

`HeldRequestRule.wireRule(for:isBuiltIn:)` lives entirely in HailProtocol. It normalizes trusted built-ins into
the frozen vocabulary and maps unknown built-ins and all configured names to `custom`. The separate protocol
mapping test pins the frozen set, tests known/unknown/configured names and verifies fallback notices retain both
closed hold reasons. `everyDaemonDefaultMapsToAFrozenWireRule` accepts additional defaults when mapped to `custom`
and fails on any emitted token outside the frozen set. No daemon production code changed.

### Fixtures discovered by the existing CI lane

Nine canonical positive fixtures were added to `Fixtures.all` and `fixtures/frames`:

- `control-request-held.json`, `control-request-held-turn.json`
- `control-held-decision-send.json`, `control-held-decision-discard.json`
- `control-held-resolution-{sent,discarded,notice-expired,refused,stale}.json`

Twenty-three hand-written negative fixtures under `fixtures/invalid/control-{request-held,held-decision,held-resolution}-*.json`
cover raw/unfrozen rule names, unknown reasons/actions/outcomes, the rejected old `expired` outcome, missing fields,
invalid UUIDs, forbidden content fields, null turn, list/expiry bounds and incorrect refusal-reason presence.
The existing CI `scripts/check_schema.py` glob discovers all of them without workflow changes. Swift fixture
conformance also covers the canonical positives and negative decoder cases. The older Swift/Python heard-turn
exclusion tests now allow the already-proposed `request_held` correlation, and the fixture command-coverage test
includes all three held controls. The first schema regression run exposed those obsolete exclusions; after correction,
all schema tests passed. No CI/workflow/script enforcement file changed.

### Final verification

Sources and fixtures were copied to the existing `~/codex-workspaces/vw1120a` iteration workspace. Every SSH
invocation was blocking with stdin `< /dev/null`; each VM job completed before the next started. No Swift build
or test ran on the voice host. Exact VM-side test commands:

```sh
WS=vw1120a ~/codex-workspaces/vw327-run.sh 'HailProtocolTests'
WS=vw1120a ~/codex-workspaces/vw327-run.sh 'HailDaemonKitTests.HeldRequestRuleVocabularyTests'
```

Both reported `build=0`, `test=0`. Final results: **161 tests in 30 suites passed** (0.147 seconds) and
**1 test in 1 suite passed** (0.001 seconds), respectively. The protocol run was repeated after a formatting-only
lint repair so this evidence covers the final Swift files; the initial run also passed 161 tests. The supplied
script uses the bounded background-policy CLT build and serial filtered test commands documented above.

Generator verification on the VM, in `~/codex-workspaces/vw1120a`:

```sh
taskpolicy -b .build/debug/hail-protocol-gen /tmp/hs1120-round2-generated/frames
diff -qr fixtures/frames /tmp/hs1120-round2-generated/frames
cmp fixtures/schema/frame-v1.schema.json /tmp/hs1120-round2-generated/schema/frame-v1.schema.json
```

Result: generated **57 fixtures** plus schema; both byte-comparison commands exited **0**. The schema's outcome
enum is derived from the Swift enum, including its non-refused conditional list.

Exact host Python commands (all under background policy):

```sh
taskpolicy -b python3 -m unittest discover -s Tests/ProtocolSchemaTests
taskpolicy -b python3 -m unittest scripts/tests/test_check_schema.py
taskpolicy -b python3 scripts/check_schema.py
```

Results: **21 schema tests passed**, **11 validator tests passed**, and the built-in checker reported
**57 positive fixtures accepted, 121 negative fixtures rejected, 0 failing**. This proves the existing fixture
validation discovers the new controls; it does not claim a remote CI run.

Exact host lint command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b swiftlint lint --strict Sources/HailProtocol/HeldRequests.swift Sources/HailProtocolFixtures/Fixtures.swift Tests/HailProtocolTests/FixtureConformanceTests.swift Tests/HailProtocolTests/HeardTurnProtocolTests.swift Tests/HailProtocolTests/HeldRequestsProtocolTests.swift Tests/HailProtocolTests/HeldRequestsVocabularyTests.swift Tests/HailDaemonKitTests/HeldRequestRuleVocabularyTests.swift
```

Result: **0 violations in 7 Swift files**. `git diff --check` passed. Applying the actual `scripts/pr-shape.py`
exclusions counts **2 production files in this correction**, `HeldRequests.swift` and `Fixtures.swift`, and
**4 across PR 1**, including `Control.swift` and `Schema.swift`. No security-critical paths are changed.
No push or PR metadata update is performed by this correction. The new commit requires fresh independent review.

Open questions for #1120 remain explicit: any privacy-on/lockdown deletion exception and its owner-visible notice;
authenticated same-device re-offer and host-local recovery/Discard; admission/backpressure and device buffering;
restart-loss/uncertain-handoff reconciliation; and whether persistence is required to eliminate restart loss.
