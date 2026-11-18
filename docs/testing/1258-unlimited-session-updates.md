# #1258 — unlimited session updates, including socket admission (branch A)

Local source candidate, 2026-11-18, based on `origin/main`
`38c62e4f9f457ac9212578253d8a898a9a4c81c5`. The owner's decision supersedes the issue's original
separate-budget proposal: action, info and spoken updates have no send budget. This branch contains no
host.json cap bridge. The optional-cap branch depends on this branch and has its own testing record.
Original combined commit: `2f4e953cdb8bab565f1818f83fdd578167849924` (retained in the existing review worktree).

All proof is synthetic and host-local. No live configuration, daemon install/restart, device build, physical
delivery or captured-output round trip is claimed. No push or PR occurred; independent review is pending.

## Implementation and traceability

- `SessionUpdatePolicy.perSessionLimit` defaults to nil. Unlimited sends retain no timestamp/session history;
  removing a configured policy cap clears its history. Explicit in-memory caps retain refusal/retry behavior.
- After the unchanged frame-size check, `LocalReplyEndpoint.submit(_:from:)` dispatches every
  `LocalSessionUpdateRequest.kind` action before checking or spending any socket admission bucket. The request
  still passes the existing strict update decoder, fail-closed audit and listener validation. All other kinds
  keep their existing shared, terminal, release or telemetry buckets. Owner-only socket access remains.
- Held bounds stay 20 total, 5 per session, 4 hours, with existing `full`/`expired` and oldest-info eviction.
- `SessionUpdateSocketBudgetTests` uses real Unix connections, the real endpoint receive/submission path,
  real listener update policy and a synthetic device peer. Reply publication returns a deterministic synthetic
  success. Both info/action cases deliver 121 updates, then admit 120 reply frames, proving updates do not
  consume the reply bucket. Separate cases first submit 120 replies, then accept submit/status/quiet actions
  with update reports. Reply 121 remains rate limited. Oversized updates still fail before dispatch. Each burst
  asserts completion within one minute. No test pre-fills the limiter or calls the listener instead of the socket.
- `SessionUpdateUnlimitedTests` covers all priority/listening combinations, 50 synthetic transport deliveries,
  empty history, cap removal, explicit-cap retry/reopening, held bounds and exact expiry. Existing local tests
  now opt into the cap for their cap-specific assertions through a test-only actor helper.

## Commands

Before **each** build/test command, the scratch runner executes, in order:

```sh
/Users/mick/.local/share/jarvis/voicework-2026-11-11/hostslot-wait.sh
/Users/mick/.local/share/jarvis/voicework-2026-11-11/voice-quiet.sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export TMPDIR=/Users/mick/codex-workspaces/hs-1258-scratch
```

`python3 /Users/mick/codex-workspaces/hs-1258-scratch/run-split-phase.py <command>` wraps each command,
limits it to 890 seconds after the gates and terminates only its own process group on timeout.

```sh
taskpolicy -b swift build --build-tests -j 2
taskpolicy -b swift test --no-parallel --skip-build --filter \
  'SessionUpdate|TaskProgress|LocalReplyEndpoint|ReplyQueuedAudioEndpoint'

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swiftlint lint --strict --quiet \
  Sources/HailDaemonKit/Notify/SessionUpdate.swift \
  Sources/HailDaemonKit/Notify/SessionUpdateQueue.swift \
  Sources/HailDaemonKit/PushEndpoint/LocalReplyEndpoint+Submission.swift \
  Sources/HailDaemonKit/PushEndpoint/LocalSessionUpdateSubmission.swift \
  Tests/HailDaemonKitTests/LocalSessionUpdateTests.swift \
  Tests/HailDaemonKitTests/SessionUpdateUnlimitedTests.swift \
  Tests/HailDaemonKitTests/SessionUpdateSocketBudgetTests.swift
git diff --check
```

## Results and mutation

- Initial build passed: 522.68 seconds (phase wall time 525.059 seconds), exit 0.
- The first serial run exposed a new reply-fixture defect: `SilentUpdateRig.frame` uses a terminal source and
  cannot round-trip through the real reply decoder with its host reply descriptor. Its 600 failures were all in
  the reply-fill success assertion; update delivery assertions passed. The fixture now builds valid host-source
  replies explicitly and requires each success before continuing. This is a corrected new-test defect, not a
  pre-existing failure claim. Corrected build passed: 77.23 seconds, exit 0.

- Corrected serial run passed: **235 tests in 59 suites**, **50.238 seconds**, exit 0 (phase 58.210 seconds).
  The socket suite passed all four test functions, including both priorities for each burst regression, in
  2.016 seconds. Strict lint passed on all seven changed Swift files; `git diff --check` passed.

The required temporary mutation moves update dispatch back below
`limiter.record`, restoring the shared bucket. Its build and filtered tests use the same gates and commands:

```sh
taskpolicy -b swift build --build-tests -j 2
taskpolicy -b swift test --no-parallel --skip-build --filter \
  'SessionUpdateSocketBudgetTests/(moreThan120UpdatesDoNotSpendTheReplyBudget|exhaustedReplyBudgetCannotBlockAnyUpdateAction)'
```

Branch A has four production files:

1. `Sources/HailDaemonKit/Notify/SessionUpdate.swift`
2. `Sources/HailDaemonKit/Notify/SessionUpdateQueue.swift`
3. `Sources/HailDaemonKit/PushEndpoint/LocalReplyEndpoint+Submission.swift`
4. `Sources/HailDaemonKit/PushEndpoint/LocalSessionUpdateSubmission.swift` (correct the old budget comment only)

Mutation result: build exit 0, **31.29 seconds**; filtered test exit 1, **2 tests in 1 suite**, **20 issues**,
**1.556 seconds**. Both priorities failed in each regression: only 120 updates reached the synthetic peer, and
reply exhaustion prevented submit/status/quiet reports. The mutated source was restored immediately before the
final build/rerun. Logs are `split-a-mutation-build.log`, `split-a-mutation-tests.log` and
`split-a-mutation-orchestration.log` under the scratch root. No mutation is committed.

After restoration, the final build passed in **30.55 seconds** (exit 0), and the identical full serial filter
passed again: **235 tests in 59 suites**, **49.222 seconds** (phase 55.947 seconds), exit 0. No timeout occurred;
all build/test phases, including their 120-second quiet gates, completed below 15 minutes. No failure is claimed
as pre-existing, so no baseline A/B worktree was needed. Final strict lint and whitespace checks passed.

Production-file counts use `scripts/pr-shape.py` exclusions and rename handling. No rename is involved.
A future PR touches security-critical socket paths and requires genuine exact-head independent review and a
second key; this record does not claim approval or current GitHub protection checks.
