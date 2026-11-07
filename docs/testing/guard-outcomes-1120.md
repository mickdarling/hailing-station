# Guard outcomes and CPU budgets (#1120, PR 2)

This slice keeps guard matches and timeouts distinct without rerunning the guard. `CompiledGuards.hits`
returns positive per-rule `GuardHit` evidence in rule order. `PolicyEvaluator.evaluateWithEvidence` returns
that evidence alongside the existing `Decision`; legacy `evaluate` and `matches` callers keep their APIs.
Both match and timeout still require confirmation. Lockdown, denial ordering, confirmation consumption,
and the unbudgeted target-block path (#658) retain their existing controls.

HailHost uses the evidence-bearing evaluation and copies its outcomes into `ReadBack.guardOutcomes`.
Rule names have the same privacy boundary as existing `guardHits`: custom names must be sanitized before
logging or sending to a device. The existing `RightyoGuardRefusal.record` call still receives names only.
Its structured storage and `guard_timeout` / `rule_match` log formatting are deferred to a later slice;
the evidence is now available at its HailHost call site, with no second match required. Held-message
protocol, phone notices, context exclusion and host hold/resolution behavior remain separate work.

## Budget

The default per-rule budget is 20 ms of thread CPU time from Darwin's
`clock_gettime(CLOCK_THREAD_CPUTIME_ID)`. Matching is synchronous, so both readings refer to one thread.
A separate named 1 s wall cap gives scheduling delays 50 times the CPU allowance while limiting stalled
work. Budgets cover all candidate lines and the joined form together, then reset for the next rule.
Either expiry, including equality at a deadline, an unreadable CPU clock, or any decrease against the
previous CPU or wall sample latches a fail-closed timeout for the remainder of that rule scan (#208).
Each rule starts with fresh previous samples and latch state. Checks run at scan boundaries and ICU
progress callbacks; this is a cooperative cap, not a preemptive interrupt between ICU callbacks. A proven result arriving beyond a deadline remains a timeout.

`GuardBudgetClock` injects both clocks. Existing wall-only test clocks freeze CPU time, preserving frozen
semantic tests and expiring fail-closed fixtures. New tests inject independent readings; no sleeps are used.

The security-review follow-up adds an internal `GuardMatchDriver` task-local enumeration seam, with no
new public API. Its production implementation forwards ICU progress/result callbacks and their stop
signal unchanged. Tests use real regex results but explicitly deliver a result callback or no callbacks,
so they can assert clock-read counts inside the callback and after enumeration. This avoids relying on
ICU progress cadence to distinguish callback expiry from final-check expiry. Clock and driver support
reside beside the guard evidence types in `Confirmation.swift`, keeping the existing 200-line SwiftLint
file limit and four-production-file limit without adding a production file.

## Traceability

- `GuardBudgetClockTests.CPUOverrunIsATimeout`: CPU limit at and past 20 ms.
- `GuardBudgetClockTests.schedulerPauseUsesTheWallCapRatherThanTheCPUBudget`: 50/999 ms wall pauses
  with 1 ms CPU remain clean; 1/2 s wall pauses time out.
- `GuardBudgetClockTests.aPathologicalScanTimesOutAfterEntry`: both clocks abort a scan after it enters ICU.
- `GuardBudgetClockTests.anUnreadableCPUClockFailsClosed`: clock failure at start and during a scan.
- `GuardBudgetClockTests.CPUDeadlineIsSharedAcrossCandidateLinesButResetsPerRule`: per-rule budget scope.
- `DangerousPatternTests.structuredHitsKeepRuleOrderAndJoinedLineMatches`: real matches and joined lines.
- `GuardBudgetClockTests.aClockDecreaseLatchesTimeout`: CPU and wall regressions below the start,
  and below the previous sample while still above the start; a recovery sample cannot clear the latch.
- `GuardBudgetClockTests.aNilCPUSampleMidScanLatchesTimeout`: an unreadable CPU result callback
  latches timeout even when the next injected reading would recover.
- `DangerousPatternTests.expiryAtAMatchingResultCallbackWins`: entry succeeds, then equality at the
  CPU/wall deadline in a proven-match callback yields timeout before the final check.
- `DangerousPatternTests.callbackFreeNoMatchExpiresAtTheFinalCheck`: CPU/wall expiry is detected
  only after a no-match enumeration returns without invoking a callback.
- `DangerousPatternTests.aLaterMatchingCandidateCannotReplaceTimeout`: on both clocks, first-candidate
  expiry prevents a later genuinely matching candidate (and the joined form) from being scanned.
- `PolicyEvaluationTests.matchAndTimeoutEvidenceBothRequireConfirmation`: open and confirm tiers.
- `PolicyEvaluationTests.decisionAndEvidenceUseExactlyOneGuardScan`: clock read count rejects rescanning.
- `PolicyEvaluationTests.denialsNeverReadTheGuardClocks`: locked and lockdown retain precedence.
- `ConfirmationFlowTests.readBackCarriesMatchAndTimeoutEvidenceWithoutDelivering`: evidence reaches read-back.
- Existing guard, policy, confirmation, host and RightyO suites remain regression coverage.

## Validation

The baseline `df8db23095a4ae8d14cced167a6e825042d5b7b2` records 274 passing tests in 27 suites.
The security-review follow-up was bundle-synced using validation snapshot
`efd4d8c92fec54049c12bb89bf505f823590beb2`. The wrapper reported `build=0`, `test=0`:
**278 tests in 27 suites passed** (4.177 s test execution). Build time was 63.77 s, with
missing module-cache debug-info warnings. Job-specific logs were preserved as
`~/codex-workspaces/vw1120b-review-build.log` and `~/codex-workspaces/vw1120b-review-test.log`;
the test log confirms all five new test functions and their eleven cases passed. The final Swift
sources and tests exactly match this snapshot; only this documentation changed after the run.

The VM workspace is `~/codex-workspaces/vw1120b`. Before each run, SSH waits for the shared VM lane.
The literal requested pattern was tried first,
but `pgrep -f vw327-run.sh` also matched its own waiting `zsh -c` process on this VM. The equivalent
self-excluding pattern used for the completed wait was:

```sh
while pgrep -f "[v]w327-run.sh" >/dev/null; do sleep 20; done
```

Then, with SSH stdin closed (`< /dev/null`), run synchronously:

```sh
WS=vw1120b ~/codex-workspaces/vw327-run.sh 'HailDaemonKitTests\.(Guard|DangerousPattern|Policy|Confirmation|HailHost|Host|RightyoInputConsumer)'
```

Host strict lint passed with **zero violations for all eight Swift files** changed cumulatively
from the branch base, using this command once per file:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b swiftlint lint --strict <file>
```

Applying `scripts/pr-shape.py`'s exact production exclusions and rename handling to the cumulative diff
from `5793b82f` counts **four production files**: `DangerousPatternGuard.swift`, `Policy.swift`,
`Confirmation.swift`, and `Daemon/HailHost.swift`. This follow-up changes two of those files. No PR is
created or pushed; the independent review's REQUEST CHANGES remains the latest completed verdict until
fresh independent review of the final head. No approving review is claimed here.

`git diff --check` and the staged equivalent passed.

This is synthetic macOS VM iteration evidence, not a physical captured-output round trip, deployment,
app installation or shipping-Xcode validation. No host Swift build or test ran for this task.
