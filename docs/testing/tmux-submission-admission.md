# Tmux submission admission

Part of #1120. This records a local implementation stacked on the delivery stage-order work at
`8a67c4e9186230a27195884e089204e0dbd9ddbb`, based on main
`2f17d604a180e2af8b5d5e3a4769289028412fd0`. Evidence below is synthetic VM verification;
this is not a shipped release, simulator run, physical-device proof or live captured-output round trip.

## Behavior as built

`ProcessCommandRunner` prepares its `Process`, arguments, pipes and input on a detached executor.
`CommandLaunch.perform` surrounds only synchronous `Process.run()` with retained admission.
Pipe draining, process-exit waits, pane observations and settle/confirmation waits run after all gates release.
The actor's paste callback runs after the runner returns, including the possibly-executed error path.
It never runs on the detached executor under authority locks.

Buffer filling is preparation. The first target-writing launch admits a ticket whose immutable fields fix
the delivery UUID, executable, socket arguments, pane, binding, buffer, payload and command vectors.
The ticket admits one paste and permits at most two Enter launches: the first Enter and the existing
conditional retry. Each subsequent sanitized line needs a separate ticket and fresh admission.
Binding verification and framed server-side agent checks remain operative for completion.

Caller cancellation commits at paste admission under the cancellation decision lock. After admission,
retirement of retained authority or caller cancellation does not interrupt the submission. Enter and its
single conditional retry consume the ticket without acquiring policy, permit, lease or peer authority again.
The next submission still validates and admits against its own current authority. A refused preparation
or first admission deletes the unused buffer and records no pasted line.

An admitted submission completing after retirement does not produce `pastedUnsent`, a policy-retired
unsent entry, pane taint or `inputPending`. Genuine failures after a possible paste retain sticky taint:
Enter failure, leaving the agent and rebinding cannot be cleared by a later pane observation, and later
input is refused without appending. No rollback key is sent.

A guarded delivery requires `GuardedCommandRunner`. A check-only `DeliveryAuthority` refuses admission
with `unsupported`. The host passes operation-bearing authority to `LaunchAdmittingDelivery` adapters;
other adapters retain the committing checked-handoff wrapper, including `CheckedHandoffDelivering`.
`TmuxReplyAdapter` uses the terminal adapter's same launch capability.

## Gate order and execution evidence

The first paste launch uses the composed authority in this fixed order, skipping absent stages:

1. target policy;
2. task output fence;
3. reply permit;
4. binding lease;
5. session update fence;
6. ambient router;
7. privacy hold;
8. peer lifecycle;
9. attempt/cancellation decision;
10. synchronous launch.

The adapter adds its cancellation decision and ticket state after the composed attempt stage.
Ticket completion only locks its own state. Neither path takes peer, permit or lease and then router,
privacy or policy. The host supplies target policy once; task output uses its fence and retained
generation comparison. Held predicates run at policy-gate entry, before the inner gates.
No `await`, pipe wait or process wait occurs under any authority gate.

Launch evidence distinguishes refused admission, definite failure before execution, and possible execution.
An admission error does not establish that its operation was skipped. The runner drains and joins a
possibly launched child before returning such an error, and the adapter uses the synchronized evidence
for tails and taint. It never retries an admission error. Possibly-executed runner errors become a delivery
failure before reaching held-send classification, so they cannot reset attempted handoff as known unsent.

Launch operation errors are captured into a `Result` inside `CommandLaunch.perform` and rethrown only
after admission returns. Thus a `Process.run` error cannot reach the composed authority's held-predicate
catch and be relabelled as a held refusal. Gate errors after a completed launch still retain possible
execution. This keeps the implementation within four production files without changing stage composition.

## Acceptance coverage

All executable fixtures are test-owned fake tmux programs. They never contact a tmux server.

| Test | Invariant |
| --- | --- |
| `TmuxSubmissionAdmissionTests.admittedPasteCompletesBeforeTheNextSubmissionIsRefused` | Production adapter and process runner; peer retirement, policy retirement and caller cancellation, each with plain and framed paste. The paste child acknowledges its barrier; retirement returns before release; Enter completes; evidence records submission, with no pending refusal; a fresh delivery proves no sticky taint; the next retired/cancelled submission launches no child. |
| `TmuxSubmissionAdmissionTests.retirementImmediatelyBeforeLaunchStartsNoWritingChild` | Detached pre-launch barrier, with peer/policy/caller retirement and both paste forms. No writing child, paste, Enter or pasted evidence; only unused-buffer cleanup launches afterward. |
| `TmuxSubmissionAdmissionTests.admittedSubmissionKeepsItsConditionalRetryAfterRetirement` | Production runner and both paste forms; one conditional retry completes after peer retirement; the next submission launches nothing. |
| `TmuxSubmissionAdmissionTests.admittedFailuresKeepStickyPendingInput` | Enter failure, agent departure and rebinding after admission retain taint and refuse later appends after the fixture recovers. |
| `TmuxSubmissionAdmissionTests.postLaunchAuthorityErrorRetainsExecutionEvidenceWithoutRetry` | A gate throws after production launch; exactly one paste, no Enter or retry, retained tail and sticky pending-input refusal; held accounting retains attempted handoff. |
| `CommandLaunchAdmissionTests.operationErrorsReturnAfterHeldPredicateEvaluation` | An operation throws `notAllowed` while changing held selection; the original operation error survives rather than becoming a held refusal. |
| `CommandLaunchAdmissionTests.launchEvidenceDistinguishesRefusalFailureAndExecution` | Refusal, missing executable and a post-operation authority error retain distinct evidence. |
| `CommandLaunchAdmissionTests.submissionTicketAllowsOnlyItsFixedCompletionBudget` | A ticket cannot move to another delivery, socket or pane, admit another paste, or authorize a third Enter. |
| `TmuxLaunchCapabilityTests` | Unguarded runner and check-only authority refuse guarded paste while keeping the pane clean. |
| `DeliveryAdmissionStageOrderTests` and existing admission/held suites | Fixed composed order and checked-handoff semantics on the underlying stack. |

## Existing expectations changed

The following existing tests explicitly adopt whole-submission admission or retain genuine failure coverage:

| Suite and test (current name) | Changed expectation and reason |
| --- | --- |
| `TmuxDeliveryAuthorityTests.retirementAfterPasteCompletesTheSubmission` | Formerly required suppressed Enter and taint. Now Enter completes, input clears and a fresh delivery succeeds. |
| `TmuxDeliveryAuthorityTests.retirementDuringDefinitiveEnterRefusalTracksPriorEnter` | Agent departure remains a genuine failure; it retains taint, with agent-only refusal before Enter and possible submission after a prior Enter. |
| `TmuxDeliveryAuthorityTests.retirementAfterPasteNeverClearsAReboundPane` | Rebinding remains a genuine failure and reports rebound rather than attributing unsent input to retirement. |
| `TmuxAuthorityBoundaryTests.retirementDuringFinalBindingCheckCompletesTheSubmission` | Formerly required unsent input and suppressed Enter; unchanged binding completes the admitted submission. |
| `TmuxAuthorityBoundaryTests.retirementBeforeRetryKeepsTheSingleRetryBudget` | Formerly suppressed the retry; permits the existing one retry, retaining failure taint when the fixture still holds input. |
| `TmuxAuthorityBoundaryTests.collapsedAgentPasteCompletesAfterRetirement` | Formerly required unsent collapsed paste; framed Enter completes after retirement. |
| `TmuxAuthorityBoundaryTests.retirementAfterPasteCompletesBeforeTheNextTerminalRefusal` | Current input completes; the next terminal input is refused without new commands. |
| `TmuxPolicyRetirementTests.retirementDuringLineTwoPreservesThePolicyReason` | A second line already pasted completes; a preparing second line remains unsent. Later lines are refused. |
| `TmuxPolicyRetirementTests.possiblySubmittedLineIsIncludedEvenWhenEnterReplyFails` | The conditional retry remains permitted after retirement. Genuine first-Enter or retry failure keeps sticky taint and partial accounting. |
| `TmuxPolicyRetirementTests.clearedInputKeepsFailureTaintAndDeviceRefusalUntilRestart` | Uses a real Enter failure to establish sticky taint; retirement alone completes rather than creating taint. |
| `TmuxPolicyRetirementTests.lineTwoRetirementCompletesOnlyTheAdmittedLine` | Reports policy refusal for subsequent work; an admitted second line includes its Enter. |
| `TmuxSubmitConfirmationTests.cancellationDuringSettleCompletesTheSubmission` | Formerly suppressed Enter and tainted on caller cancellation; admitted work completes and a later delivery succeeds. |
| `TmuxRefusalEvidenceTests.aCancelledAdmittedPasteStillRecordsItsSubmit` | Formerly required no submit evidence and later pending refusal; now records the admitted submit and no pending refusal. |
| `AmbientWiringPolicyRetirementTests.reallowedPolicyTaintRefusesTwoRequestsWithoutEndingAmbient` | Adds actual rebinding after paste to establish failure taint; reallowing policy alone does not taint an admitted submission. |

`TmuxDeliveryCommitTests` changes only a stale coverage comment. Test runner support now explicitly models
guarded launch, while the capability suite preserves coverage for a runner lacking that contract.

## Verification record

The targeted regression run passed 271 tests in 62 suites. Strict lint passed all 17 changed Swift files.
The final broad VM phases remain pending. The VM workspace is re-synchronized from a local
`origin/main..HEAD` bundle before execution. The local main baseline was also transferred by bundle;
no GitHub calls were made. Runs use at most four workers, no parallel test execution, and a 600-second
process-group watchdog with termination/kill cleanup for each phase. SSH uses stdin from `/dev/null`.
The host gate file must be absent before the broad suites and Reply CLI tests run.

VM commands (SSH stdin redirected from `/dev/null`; each execution phase uses `/tmp/f3b-phase.py`):

```sh
while pgrep -f '[v]w327-run.sh' >/dev/null; do sleep 20; done
WS=vwf3b python3 /tmp/f3b-phase.py /bin/zsh ~/codex-workspaces/vw327-run.sh 'HailDaemonKitTests\.(Tmux|CommandLaunch|DeliveryAdmission|TaskProgress|Held)'

while pgrep -f '[v]w327-run.sh' >/dev/null; do sleep 20; done
WS=vwf3b python3 /tmp/f3b-phase.py /bin/zsh ~/codex-workspaces/vw327-run.sh 'HailDaemonKitTests\.(DeliveryAdmission|DeliveryAuthority|FinalDelivery|TaskProgress|Held|LocalDispatch|HailHost|Host|Ambient|Tmux|Reply|CommandLaunch)'

cd ~/codex-workspaces/vwf3b
python3 /tmp/f3b-phase.py python3 -m unittest discover -s Tests/ReplyCLITests

python3 /tmp/f3b-werr.py
```

The warnings-as-errors wrapper invokes `~/codex-workspaces/vw-werr.sh vwf3b` under the same watchdog,
temporarily adds `-j 4` to its build command, and restores the helper afterward. The watchdog creates
a process group, sends termination on timeout/interruption, waits up to five seconds, then kills and
joins remaining children. The idle check uses `[v]` to avoid matching its own shell command.

The existing real-tmux suites remain skipped when tmux is unavailable: `TmuxDeliveryCommitFakeTUITests`,
`TmuxDeliveryCommitShellPromptTests`, `TmuxIntegrationTests`, `TmuxPasteAgentTests` and `TmuxPasteEnterTests`.
The production-runner fixture tests above execute without tmux. No tmux binary was installed.

Host lint command, run separately for every changed Swift file:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b swiftlint lint --strict <file>
```

Local `git diff --check` passes. Production count is computed from the checker's exact exclusion
constants and both names of renamed files; it is four relative to the stage-order parent.

## Launch hold measurement

`CommandLaunchAdmissionTests.productionLaunchGateHoldMeasurements` completed on the VM with the
production runner. The passing targeted run recorded the following gate-hold intervals:

| Launches | Minimum | Median | p95 | Maximum |
| --- | --- | --- | --- | --- |
| 60 | 0.115250 ms | 0.186688 ms | 0.420709 ms | 0.773334 ms |

It measures 60 sequential production runner launches of `/usr/bin/true`, from immediately before the
synchronous launch operation until it returns, with process completion outside the measured interval.
Median is the mean of the two central values; p95 uses nearest rank. These are synthetic VM dispatch
measurements, not device or production latency guarantees.

## Scope

The checker excludes tests and documentation. Relative to the local stage-order parent, the four
production files are:

- `Sources/HailDaemonKit/Adapters/Tmux/CommandRunner.swift`;
- `Sources/HailDaemonKit/Adapters/Tmux/TmuxAdapter.swift`;
- `Sources/HailDaemonKit/Adapters/Tmux/TmuxAdapter+Paste.swift`;
- `Sources/HailDaemonKit/Daemon/HailHost.swift`.

`TmuxAdapter+Submit.swift` is unchanged. Existing independent exact-head reviews and current required
GitHub protections remain separate release requirements; this local record does not claim those reviews.
No source was pushed, no installed build was replaced and no delivery was uploaded.
