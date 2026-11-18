# #1258 — optional host session-update cap (part B)

Verification record, 2026-11-18. Part A merged as [PR #1265](https://github.com/mickdarling/hailing-station/pull/1265),
main commit `d269d9612f4c392ce50f63e06f94990305d97278`. Part B's cap commit
`c98f905730718408746b6d8c549301d39116c838` is rebased onto that merged foundation. For part A's unlimited-default
behavior, socket regressions and earlier mutation proof, see [its verification record](1258-unlimited-session-updates.md).
The follow-up here includes the report documentation and admission tests deferred by part A's second-key review.

All verification is synthetic and host-local. No live config, daemon install/restart, device build or physical
proof is claimed. The host harness uses fake binaries/launchctl and scratch configuration only.

## Implementation and traceability

- Flat host.json keys `sessionUpdatePerSessionLimit` (JSON integer 1..10000) and `sessionUpdateWindowSeconds`
  (JSON integer 1..86400) are both absent by default. Both must be present together with `sessionUpdates: true`.
- `scripts/host.sh` validates typed values before changing the fake lifecycle job and emits
  `--session-update-per-session-limit N --session-update-window-seconds S`. The daemon validates again and
  applies the policy at startup. Removing both keys restores unlimited sends; changes require a restart.
- Configured caps retain the queue's sliding-window `rate_limited` refusal and retry timing; refusals spend
  no queue budget. Independently, part A's socket runaway guard protects against a stuck local loop: 60
  submissions/minute per host. Its control bucket admits 120 status/quiet-on requests/minute. Reply traffic
  cannot spend either bucket. Held bounds remain 20 total, 5 per session, 4 hours.
- `SessionUpdateLimitConfigurationTests` checks absent/valid caps reaching the listener, boundaries,
  malformed/incomplete/duplicate values and disabled combinations. Its real-socket case configures 2/hour:
  two cards deliver, queue refusals remain `rate_limited`, only two send timestamps remain, and attempt 61
  is refused `runaway_guard` with a positive retry of at most 60 seconds.
- The shell harness checks typed JSON, exact generated arguments, compatibility when absent and preflight
  refusing invalid caps before fake stop.
- `LocalSessionUpdateReport.reason` and `retryAfter` document `runaway_guard` and `control_rate_limited`.
  These admission refusals carry **no listener status**. Their `held: 0`, `quiet: false`,
  `speechUnavailable: "attention_signal_missing"` and absent `speechStatus` are compatibility placeholders,
  regardless of actual listener state. Only outcome, reason and retry time are meaningful. Existing synthesized
  decoders require `held` and `quiet`; dropping them would break existing readers. The encoder/decoder
  regression checks both required keys and round trips. `LocalReplyResponse` decodes this same report; the
  notify CLI prints only reason/retry for refusals. Its fixture now explicitly checks that placeholder status
  is never printed. The protocol frame schema does not define this separate owner-only socket report.
- `SessionUpdateRunawayGuardTests.malformedActionsSpendSubmitAdmissionBeforeStrictDecoding` sends real
  socket frames of kind `update` with numeric, null, object, unknown and missing actions. Each of the first 60
  fails strict decoding and spends submit admission; attempt 61 is refused before strict decoding. The control
  bucket stays unspent, publisher calls and device sends stay zero, listener state stays unchanged, and no
  durable update audit record appears.
- `SessionUpdateSocketBudgetTests.oversizedUpdatesStillFailBeforeDispatch` checks the unchanged size refusal,
  zero sends and an unchanged limiter, including an unspent update bucket.

## Verification method

Before each build/test phase, a local runner waits for the host's build slot and a quiet stretch, sets
`DEVELOPER_DIR` and a scratch `TMPDIR`, then runs the command. The runner limits command execution to 890
seconds and on timeout terminates only its own process group. Build/test command phases must complete below
15 minutes; waiting at the host gates is recorded separately.
No simulator or physical-device result is implied by these package tests.

## Earlier cap verification

The original split cap verification passed: build 521.12 seconds; serial Swift filter **273 tests in 70 suites**
in 52.231 seconds; scratch shell harness `test-host: OK` in 147.724 seconds. The subsequent pre-merge rebase
verification passed: build 525.14 seconds; focused config/related filter **112 tests in 34 suites** in 20.327
seconds; scratch shell harness `test-host: OK` (phase 140.061 seconds). Strict changed-file Swift lint, shell
syntax and whitespace checks passed in both rounds. These historical results predate the follow-up below.

## Follow-up verification

Each build/test command below uses the ordered gates and environment described above.

The first follow-up build passed (100.46 seconds; runner phase 102.379 seconds). The initial serial run reached
**280 tests in 72 suites** in 113.904 seconds (phase 120.484 seconds), with two fixture-count failures: the
extracted helper returned the audit day header as well as the 60 update records. Existing guard tests need
filtered update history; the new malformed-action test needs full history. The helper now supplies both.
All new admission, oversized-bucket, compatibility and cap-configuration cases passed in that initial run.
The same failing test/helper overlay on `origin/main` reproduced exactly those two count failures: one test
in one suite, 0.457 seconds (phase 7.229 seconds). This identifies an introduced test-fixture error, not a
pre-existing failure in main. The baseline build passed in 753.55 seconds (phase 755.633 seconds), after a copied
module cache was set aside because it embedded the original worktree path. The first copied-cache attempt
failed in 4.467 seconds; this was a cache relocation error, not a source result. The baseline test overlay was
then removed. The exact focused A/B test command was:

```sh
taskpolicy -b swift test --no-parallel --skip-build --filter \
  'SessionUpdateRunawayGuardTests/sixtySubmitsThenARefusalRecordsNothing'
```

Initial lint also exposed an unset `DEVELOPER_DIR` (the same SourceKit load failure reproduced on main) and
introduced file/type-length violations. Setting the required developer directory and extracting test support
and wire tests corrected these issues. Strict lint passes on the corrected changed Swift files.
The corrected worktree build passed in 73.93 seconds (phase 75.368 seconds). The full serial filter then
passed: **280 tests in 72 suites**, 122.088 seconds (phase 128.692 seconds). The scratch host harness passed
with `test-host: OK` (phase 156.477 seconds). The notify CLI fixture passed **7 tests** in 0.459 seconds
(phase 0.545 seconds), including unchanged refusal output.

```sh
taskpolicy -b swift build --build-tests -j 2
taskpolicy -b swift test --no-parallel --skip-build --filter \
  'SessionUpdate|TaskProgress|LocalReplyEndpoint|ReplyQueuedAudioEndpoint|AmbientDuckTimeoutOptionsTests|AmbientSharedAuditTests|AmbientWiringOptionsTests|DiagnosticSessionTests|HostHealthSessionTests|SingleTerminalReplyFallbackTests|VoiceRouteListingTests'
taskpolicy -b bash scripts/tests/test-host.sh
python3 -m unittest discover -s Tests/ReplyCLITests -p test_notify_cli.py
swiftlint lint --strict --quiet \
  Sources/HailDaemonKit/Listener/ConnectionProbeDaemon.swift \
  Sources/HailDaemonKit/Listener/LocalSessionUpdate.swift \
  Sources/HailDaemonKit/PushEndpoint/LocalSessionUpdateSubmission.swift \
  Tests/HailDaemonKitTests/SessionUpdateLimitConfigurationTests.swift \
  Tests/HailDaemonKitTests/LocalSessionUpdateReportWireTests.swift \
  Tests/HailDaemonKitTests/SessionUpdateRunawayGuardTests.swift \
  Tests/HailDaemonKitTests/SessionUpdateGuardTestSupport.swift \
  Tests/HailDaemonKitTests/SessionUpdateSocketBudgetTests.swift
bash -n scripts/host.sh scripts/tests/test-host.sh
git diff --check
```

## Mutation proof

Both mutations were temporary changes to `LocalReplyEndpoint+Submission.swift`; neither remains in the
candidate. The original file was restored byte-for-byte before the final rebuild (`cmp` and an empty source
file diff both passed).

- **Oversized admission:** temporarily charge the update bucket before returning the size refusal. The build
  passed (phase 30.831 seconds). `oversizedUpdatesStillFailBeforeDispatch` failed with the expected **two**
  bucket assertions (test 0.067 seconds; phase 6.044 seconds; exit 1). The size refusal itself stayed unchanged.
- **Malformed action admission:** temporarily bypass admission when strict request decoding fails. The build
  passed (phase 31.323 seconds). `malformedActionsSpendSubmitAdmissionBeforeStrictDecoding` failed for all
  **five** action variants, with 15 expected issues (test 0.467 seconds; phase 6.251 seconds; exit 1).
- The restored-source build passed (28.47 seconds; phase 29.543 seconds). The focused rerun passed both
  tests in two suites, including all five malformed-action variants (0.504 seconds; phase 5.860 seconds).
  Final strict changed-file lint, shell syntax, whitespace and public-record path/history checks passed.
  Every build/test command phase completed below 15 minutes; host gate waits are separate. No unexpected
  failure remains; the two mutation failures above were intentional.

Each command below used its own ordered host-slot/quiet gates and scratch environment:

```sh
taskpolicy -b swift build --build-tests -j 2
taskpolicy -b swift test --no-parallel --skip-build --filter \
  'SessionUpdateSocketBudgetTests/oversizedUpdatesStillFailBeforeDispatch'
taskpolicy -b swift build --build-tests -j 2
taskpolicy -b swift test --no-parallel --skip-build --filter \
  'SessionUpdateRunawayGuardTests/malformedActionsSpendSubmitAdmissionBeforeStrictDecoding'
taskpolicy -b swift build --build-tests -j 2
taskpolicy -b swift test --no-parallel --skip-build --filter \
  'SessionUpdateSocketBudgetTests/oversizedUpdatesStillFailBeforeDispatch|SessionUpdateRunawayGuardTests/malformedActionsSpendSubmitAdmissionBeforeStrictDecoding'
```

## Change shape

The checker's exact exclusions count **four production files relative to merged part A**:

1. `Sources/HailDaemonKit/Listener/ConnectionProbeDaemon.swift`
2. `scripts/host.sh`
3. `Sources/HailDaemonKit/Listener/LocalSessionUpdate.swift`
4. `Sources/HailDaemonKit/PushEndpoint/LocalSessionUpdateSubmission.swift`

`Tests/`, `scripts/tests/` and Markdown docs are excluded; no rename is involved. Part B now targets the merged
part A foundation. The listener and scripts are security-critical. The independent primary and second-key reviews
are recorded on the pull request.
