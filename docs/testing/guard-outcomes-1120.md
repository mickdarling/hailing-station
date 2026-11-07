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
Either expiry, including equality at a deadline, or an unreadable CPU clock yields a fail-closed timeout
(#208). Checks run at scan boundaries and ICU progress callbacks; this is a cooperative cap, not a
preemptive interrupt between ICU callbacks. A proven result arriving beyond a deadline remains a timeout.

`GuardBudgetClock` injects both clocks. Existing wall-only test clocks freeze CPU time, preserving frozen
semantic tests and expiring fail-closed fixtures. New tests inject independent readings; no sleeps are used.

## Traceability

- `GuardBudgetClockTests.CPUOverrunIsATimeout`: CPU limit at and past 20 ms.
- `GuardBudgetClockTests.schedulerPauseUsesTheWallCapRatherThanTheCPUBudget`: 50/999 ms wall pauses
  with 1 ms CPU remain clean; 1/2 s wall pauses time out.
- `GuardBudgetClockTests.aPathologicalScanTimesOutAfterEntry`: both clocks abort a scan after it enters ICU.
- `GuardBudgetClockTests.anUnreadableCPUClockFailsClosed`: clock failure at start and during a scan.
- `GuardBudgetClockTests.CPUDeadlineIsSharedAcrossCandidateLinesButResetsPerRule`: per-rule budget scope.
- `DangerousPatternTests.structuredHitsKeepRuleOrderAndJoinedLineMatches`: real matches and joined lines.
- `DangerousPatternTests.anInjectedOverrunReportsTimeoutInsteadOfMatch`: timeout classification.
- `PolicyEvaluationTests.matchAndTimeoutEvidenceBothRequireConfirmation`: open and confirm tiers.
- `PolicyEvaluationTests.decisionAndEvidenceUseExactlyOneGuardScan`: clock read count rejects rescanning.
- `PolicyEvaluationTests.denialsNeverReadTheGuardClocks`: locked and lockdown retain precedence.
- `ConfirmationFlowTests.readBackCarriesMatchAndTimeoutEvidenceWithoutDelivering`: evidence reaches read-back.
- Existing guard, policy, confirmation, host and RightyO suites remain regression coverage.

## Validation

A fresh GitHub clone at `~/codex-workspaces/vw1120b` was synced by git bundle, without pushing. The VM
ran this command serially, with SSH stdin closed, on implementation/test commit
`14fe0561399a05197923ad65e72a33bf37635ef4`:

```sh
WS=vw1120b ~/codex-workspaces/vw327-run.sh 'HailDaemonKitTests\.(Guard|DangerousPattern|Policy|Confirmation|HailHost|Host|RightyoInputConsumer)'
```

The wrapper reported `build=0`, `test=0`: **274 tests in 27 suites passed** (4.105 s test execution).
The build completed in 13.84 s with missing module-cache debug-info warnings. The preserved job-specific
logs confirmed the new tests ran. An earlier run's shared logs were overwritten by a different VM task;
its counts are discarded. Only this documentation changed after the verified run.

Host lint passed for all seven changed Swift files with zero violations, using this command once per file:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b swiftlint lint --strict <file>
```

`git diff --check` passed. Applying `scripts/pr-shape.py`'s exact production exclusions to the base diff
counts **four production files**: `DangerousPatternGuard.swift`, `Policy.swift`, `Confirmation.swift`,
and `Daemon/HailHost.swift`. The PR-shape service/review gate was not run: no PR was created or pushed;
independent security review remains future PR work.

This is synthetic macOS VM iteration evidence, not a physical captured-output round trip, deployment,
app installation or shipping-Xcode validation. No host Swift build or test ran for this task.
