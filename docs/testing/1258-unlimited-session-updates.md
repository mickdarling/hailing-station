# #1258 — unlimited session sends with independent socket admission (branch A)

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
- After the unchanged frame-size check, a cheap kind/action probe selects independent host-wide admission:
  `local-session-update` allows 60 submissions/minute; `local-session-update-control` allows 120 status/quiet-on
  requests/minute. Admission precedes strict decoding, bookkeeping and listener work. This runaway guard
  protects against a stuck local loop at a rate normal use never reaches; there is no session send budget.
  Refusals report `runaway_guard` or `control_rate_limited` with retry seconds and spend no admission.
  Content-free refusal logs are limited to once per minute per reason. Reply traffic cannot spend either bucket;
  updates cannot spend the reply bucket. All other kinds retain their existing buckets and owner-only access.
- Held bounds stay 20 total, 5 per session, 4 hours, with existing `full`/`expired` and oldest-info eviction.
- `SessionUpdateSocketBudgetTests` uses real Unix connections, the real endpoint receive/submission path,
  real listener update policy and a synthetic device peer. Reply publication returns a deterministic synthetic
  success. Both info/action cases deliver 60 updates, then admit 120 reply frames, proving updates do not
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

## Original results and mutation (before round-2 correction)

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
4. `Sources/HailDaemonKit/PushEndpoint/LocalSessionUpdateSubmission.swift`

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


## Round-2 correction (local source candidate)

The current candidate keeps the unlimited session policy and held bounds (5/session, 20 total, 4 hours), with
independent socket protection against a stuck local loop: submits 60/minute per host; controls 120/minute.
`SessionUpdateRunawayGuardTests` exercises real sockets for the 60th/61st and 120th/121st boundaries,
refusals recording nothing and not reaching the listener, disabled updates, control isolation, throttled stderr
lines and real-time window reopening. `SessionUpdateSocketBudgetTests` proves isolation in both directions
from reply traffic. The notify CLI fixture verifies both new refusal reasons and their retry times.
Earlier results above describe original part A, `df5fd5c804b2e62db54f703ef5cc3c24bcbb8396`.

Correction verification uses the same per-command gate runner and developer directory shown above. The first
build failed in the new test helper because it synchronously read an actor-isolated socket URL. The fixture now
derives its path from its own scratch directory; that is a correction defect, not a pre-existing failure claim.
The corrected build passed (phase 282.724 seconds), followed by **239 tests in 60 suites**, **112.051 seconds**
(phase 119.622 seconds), using:

```sh
taskpolicy -b swift build --build-tests -j 2
taskpolicy -b swift test --no-parallel --skip-build --filter \
  'SessionUpdate|TaskProgress|LocalReplyEndpoint|ReplyQueuedAudioEndpoint'
```

The guard suite passed in 67.016 seconds; its real-time flood/window case passed in 65.832 seconds.
The exact `origin/main` base was checked in a separate scratch worktree with the same build and serial filter.
Its cold-cache build reached the enforced 890-second runtime limit with no source errors; the runner terminated
only its own build group. A fresh gated phase resumed cached progress and passed in 562.234 seconds.
The baseline then passed **226 tests in 57 suites**, **52.602 seconds** (phase 60.177 seconds). The new fixture
is absent from that base; its compile defect is owned by this correction. No failure is called pre-existing.
Gate waits precede the timed build/test phases and were extended by live voice activity.

All three temporary mutations were detected, then both production files were restored byte-for-byte:

| Mutation | Build phase | Targeted test result |
| --- | --- | --- |
| Route updates through `local-reply` | exit 0, 99.997 s | exit 1; 2 tests, 16 issues, 1.561 s; both isolation directions fail for both priorities |
| Move admission after bookkeeping | exit 0, 33.908 s | exit 1; 1 test, 2 issues, 0.486 s; the no-record assertion fails for both priorities |
| Drop the guard | exit 0, 33.750 s | exit 1; 1 test, 50 issues, 0.640 s; the 61st submit reaches the publisher instead of being refused |

Each mutation uses the same gated build command above. The shared-bucket mutation uses the first filter below;
the late-admission and guard-removal mutations each use the second:

```sh
taskpolicy -b swift test --no-parallel --skip-build --filter \
  'SessionUpdateSocketBudgetTests/(sixtyUpdatesDoNotSpendTheReplyBudget|exhaustedReplyBudgetCannotBlockAnyUpdateAction)'
taskpolicy -b swift test --no-parallel --skip-build --filter \
  'SessionUpdateRunawayGuardTests/sixtySubmitsThenARefusalRecordsNothing'
```

The restored build passed (35.289 s). One restored serial attempt stalled in the unchanged
`LocalReplyEndpointTests.mebibyteDispatchCrossesTheSocketWhileReplyFramesKeepTheirCap` test. After taking a
sample, only the verified owned test helper was stopped; that interrupted phase exited 1 after 472.150 s.
Buffered output confirmed the preceding dispatch tests had passed. The exact focused A/B command was then run
in the clean main worktree and this worktree, with the same gates:

```sh
taskpolicy -b swift test --no-parallel --skip-build --filter \
  'LocalReplyEndpointTests/mebibyteDispatchCrossesTheSocketWhileReplyFramesKeepTheirCap'
```

Both passed: main 9.505 s (phase 16.389 s), A 9.654 s (phase 15.963 s). This did not reproduce a baseline defect,
so no pre-existing-failure claim is made. The complete restored serial filter was then rerun and passed:
**239 tests in 60 suites**, **115.623 s** (phase 119.716 s), including the strengthened assertion that the first
refusal spends no submit admission. The dispatch test passed in that full run too (8.882 s).

Logs use the `r2-` prefix under the scratch root: mutation build/test logs, `r2-restored-tests-interrupted.log`,
`r2-restored-dispatch-hang.sample.txt`, both `*-dispatch-comparison.log` files and `r2-restored-tests.log`.
No mutation is committed. Strict lint passed on all eight Swift files changed by A; whitespace checks passed.
The CLI fixture passed **6 tests**, **0.391 s** (phase 0.446 s), including both new reasons and retry times:

```sh
python3 -m unittest discover -s Tests/ReplyCLITests -p test_notify_cli.py
```

Final strict lint used the configured rules on all changed Swift files:

```sh
swiftlint lint --strict --quiet \
  Sources/HailDaemonKit/Notify/SessionUpdate.swift \
  Sources/HailDaemonKit/Notify/SessionUpdateQueue.swift \
  Sources/HailDaemonKit/PushEndpoint/LocalReplyEndpoint+Submission.swift \
  Sources/HailDaemonKit/PushEndpoint/LocalSessionUpdateSubmission.swift \
  Tests/HailDaemonKitTests/LocalSessionUpdateTests.swift \
  Tests/HailDaemonKitTests/SessionUpdateUnlimitedTests.swift \
  Tests/HailDaemonKitTests/SessionUpdateSocketBudgetTests.swift \
  Tests/HailDaemonKitTests/SessionUpdateRunawayGuardTests.swift
git diff --check
```

All completed build/test command phases stayed below 15 minutes; the cold baseline phase was stopped at the
890-second limit and resumed as described above. Host-slot and voice-quiet waits precede those timed phases.
All results remain host-local and synthetic; no installation or physical-device proof is claimed.
