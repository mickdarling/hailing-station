# Tmux submission admission

Part of #1120. This records a local implementation stacked on the delivery stage-order work at
`8a67c4e9186230a27195884e089204e0dbd9ddbb`. That stack parent has a tree identical to main
`461b40c1d9886be237ef34bc7c9d20484895857d` (both trees are
`f9c6228bb7c1896670d92315408c2dce6049db3f`). Evidence below is synthetic VM verification;
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
Ticket completion acquires no retained authority gate. Neither path takes peer, permit or lease and then router,
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

Tmux command fixtures use test-owned fake executables and never contact a tmux server.

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
| `TaskProgressTmuxAdmissionTests.wakeAttemptCommitsOnlyAtPasteAdmission` | Production host, retained task authority and tmux adapter; no attempt during buffer preparation, attempt set before the paste side effect, no attempt or writing command on tainted pre-admission refusal. |
| `TmuxRefusalEvidenceTests.rebindingAfterPasteKeepsUnsubmittedEvidenceAndStickyRefusal` | Rebind before submit, exact unobserved/unsubmitted evidence prefix and suffix on two later sticky refusals, no later capture or write. |
| `TmuxDeliveryCommitTests.cancellationAfterTheCommitPointStillCompletesTheEnter` | Acknowledged Enter invocation with zero effects at cancellation; one completed Enter, directly observed clean input, and a fresh successful delivery. |
| `TmuxSubmitConfirmationTests.cancellationDuringSettleCompletesTheSubmission` | An acknowledged injected-clock barrier holds the settle wait during cancellation; the admitted Enter and later fresh delivery complete. |
| `DeliveryAdmissionStageOrderTests` and existing admission/held suites | Fixed composed order and checked-handoff semantics on the underlying stack. |

## Assertion restoration batch

The whole-submission rule is unchanged. This batch restores the exact single terminal refusal frame
and message, the refusal's no-capture/no-write checks, the collapsed-paste exact single Enter vector
and empty input, and the cancelled-paste exact total evidence count. A rebind-after-paste case retains
the unsubmitted taint evidence prefix/suffix and checks repeated sticky refusals after recovery.

The shared fake records invocation before its original delay and performs its responder only inside
`launch.perform`; executed-command tracking keeps actual delivery distinct from an attempted invocation.
Acknowledged Enter and settle barriers prove cancellation occurs while those operations are parked.
Queued-delivery tests acknowledge initial authority and cross an adapter actor fence before cancellation.
No fixed-duration sleep orders these tests; the own-insert age test waits for its clock condition.
All barriers have watchdogs and are drained before checking results.

`LaunchAdmittingDelivery` is internal. The public guarded runner and command-launch contracts are
unchanged. `TaskProgressTmuxAdmissionTests` sends a wake prompt through retained task stages,
`HailHost` and the production `TmuxAdapter`: buffer preparation leaves the attempt unset, the paste
side effect sees it set, and a tainted pre-admission refusal leaves it unset and launches no capture or write.

## Existing expectations changed

Compared with main `461b40c1d9886be237ef34bc7c9d20484895857d`, each changed assertion below is
**KEPT**, **TIGHTENED**, or **WEAKENED**. A WEAKENED row identifies only a whole-submission-rule
inversion of an old post-admission prohibition; its reason is explicit. Awaited successful completion
replacing an exception expectation counts as an assertion. Unchanged assertions outside these rows remain
in place. The unsubmitted evidence prefix/suffix and later refusal are retained in the rebind case.
New task-wake and launch-capability suites are additional coverage, outside these existing-test counts.

Table counts: **29 KEPT, 31 TIGHTENED, 34 WEAKENED; 94 rows total**.

| Suite/test | Assertion | Status | Reason |
| --- | --- | --- | --- |
| `TmuxAuthorityBoundaryTests.retirementDuringFinalBindingCheckCompletesTheSubmission` | Completion succeeds | WEAKENED | Whole-submission admission permits completion after retirement. |
| `TmuxAuthorityBoundaryTests.retirementDuringFinalBindingCheckCompletesTheSubmission` | Input is empty | WEAKENED | Whole-submission admission permits the admitted Enter to clear input. |
| `TmuxAuthorityBoundaryTests.retirementDuringFinalBindingCheckCompletesTheSubmission` | Enter count is one | WEAKENED | Whole-submission admission permits the admitted Enter. |
| `TmuxAuthorityBoundaryTests.retirementBeforeRetryKeepsTheSingleRetryBudget` | Enter side-effect count is two | WEAKENED | Whole-submission admission retains the single conditional retry. |
| `TmuxAuthorityBoundaryTests.retirementBeforeRetryKeepsTheSingleRetryBudget` | send-keys invocation count is two | WEAKENED | Whole-submission admission retains the single conditional retry. |
| `TmuxAuthorityBoundaryTests.collapsedAgentPasteCompletesAfterRetirement` | Completion succeeds | WEAKENED | Whole-submission admission permits framed completion after retirement. |
| `TmuxAuthorityBoundaryTests.collapsedAgentPasteCompletesAfterRetirement` | Input is empty | WEAKENED | Whole-submission admission permits the admitted Enter to clear input. |
| `TmuxAuthorityBoundaryTests.collapsedAgentPasteCompletesAfterRetirement` | Enter side-effect count is one | WEAKENED | Whole-submission admission permits the admitted Enter. |
| `TmuxAuthorityBoundaryTests.collapsedAgentPasteCompletesAfterRetirement` | send-keys invocation count is exactly one | WEAKENED | Whole-submission admission replaces zero keys with exactly the admitted Enter. |
| `TmuxAuthorityBoundaryTests.collapsedAgentPasteCompletesAfterRetirement` | The sole key vector equals the framed Enter vector | TIGHTENED | No non-Enter key or additional invocation is accepted. |
| `TmuxAuthorityBoundaryTests.collapsedAgentPasteCompletesAfterRetirement` | No retired-unsent evidence | WEAKENED | Whole-submission completion no longer reports an unsent paste. |
| `TmuxAuthorityBoundaryTests.retirementAfterPasteCompletesBeforeTheNextTerminalRefusal` | Current outcome is delivered | WEAKENED | Whole-submission admission completes current input before refusing later input. |
| `TmuxAuthorityBoundaryTests.retirementAfterPasteCompletesBeforeTheNextTerminalRefusal` | onlyControl equals the exact notAllowed error | KEPT | One frame and the actual locked-policy message remain mandatory. |
| `TmuxAuthorityBoundaryTests.retirementAfterPasteCompletesBeforeTheNextTerminalRefusal` | No later capture, fill, paste or key invocation | TIGHTENED | Retains the capture prohibition and adds every input-writing command. |
| `TmuxAuthorityBoundaryTests.retirementAfterPasteCompletesBeforeTheNextTerminalRefusal` | Enter count is one | WEAKENED | Whole-submission admission permits current Enter before the next refusal. |
| `TmuxAuthorityBoundaryTests.retirementAfterPasteCompletesBeforeTheNextTerminalRefusal` | Input is empty | WEAKENED | Whole-submission admission permits current Enter to clear input. |
| `TmuxDeliveryAuthorityTests.retirementAfterPasteCompletesTheSubmission` | Completion succeeds | WEAKENED | Whole-submission admission permits completion after retirement. |
| `TmuxDeliveryAuthorityTests.retirementAfterPasteCompletesTheSubmission` | First pasted payload equals the sole original payload | KEPT | The exact initial paste assertion is retained. |
| `TmuxDeliveryAuthorityTests.retirementAfterPasteCompletesTheSubmission` | Initial Enter count is one | WEAKENED | Whole-submission admission permits the admitted Enter. |
| `TmuxDeliveryAuthorityTests.retirementAfterPasteCompletesTheSubmission` | Initial input is empty | WEAKENED | Whole-submission admission permits Enter to consume the original input. |
| `TmuxDeliveryAuthorityTests.retirementAfterPasteCompletesTheSubmission` | Initial key vectors equal one exact Enter | WEAKENED | Whole-submission admission replaces the no-key prohibition with one exact Enter. |
| `TmuxDeliveryAuthorityTests.retirementAfterPasteCompletesTheSubmission` | No retired-unsent evidence | WEAKENED | Whole-submission completion does not create retirement taint. |
| `TmuxDeliveryAuthorityTests.retirementAfterPasteCompletesTheSubmission` | Fresh later delivery succeeds | WEAKENED | Whole-submission completion does not leave retirement taint. |
| `TmuxDeliveryAuthorityTests.retirementAfterPasteCompletesTheSubmission` | Final pasted payloads equal both requests | WEAKENED | Whole-submission completion allows a fresh request to use the clean pane. |
| `TmuxDeliveryAuthorityTests.retirementAfterPasteCompletesTheSubmission` | Final Enter count is exactly two | TIGHTENED | Bounds the newly successful later delivery. |
| `TmuxDeliveryAuthorityTests.retirementAfterPasteCompletesTheSubmission` | Final key vectors equal exactly two Enters | WEAKENED | Whole-submission completion permits a fresh delivery with its own Enter. |
| `TmuxDeliveryAuthorityTests.retirementAfterPasteCompletesTheSubmission` | Final input is empty | TIGHTENED | Checks pane cleanliness after the fresh delivery. |
| `TmuxDeliveryAuthorityTests.retirementAfterPasteCompletesTheSubmission` | No pending-input evidence | WEAKENED | Whole-submission completion does not create sticky retirement taint. |
| `TmuxDeliveryAuthorityTests.retirementDuringDefinitiveEnterRefusalTracksPriorEnter` | Exact first error distinguishes a prior Enter | KEPT | Genuine framed refusal remains exact; a prior Enter retains possiblySubmitted. |
| `TmuxDeliveryAuthorityTests.retirementDuringDefinitiveEnterRefusalTracksPriorEnter` | Later error is exactly inputPending(tainted) | KEPT | Genuine failure retains sticky taint in both variants. |
| `TmuxDeliveryAuthorityTests.retirementDuringDefinitiveEnterRefusalTracksPriorEnter` | No retired-unsent evidence | KEPT | The exact evidence expectation follows genuine framed failure rather than retirement. |
| `TmuxDeliveryAuthorityTests.retirementAfterPasteNeverClearsAReboundPane` | Exact rebound error | KEPT | Binding mismatch remains a genuine refusal before Enter. |
| `TmuxPolicyRetirementTests.retirementDuringLineTwoPreservesThePolicyReason` | Exact partial result includes an admitted second line | WEAKENED | Whole-submission admission includes that line after its Enter; an unadmitted line stays excluded. |
| `TmuxPolicyRetirementTests.retirementDuringLineTwoPreservesThePolicyReason` | Enter count includes the admitted second line | WEAKENED | Whole-submission admission permits that line to finish. |
| `TmuxPolicyRetirementTests.possiblySubmittedLineIsIncludedEvenWhenEnterReplyFails` | Enter count includes the permitted conditional retry | WEAKENED | Whole-submission admission retains the retry; a failed first Enter still prevents it. |
| `TmuxPolicyRetirementTests.clearedInputKeepsFailureTaintAndDeviceRefusalUntilRestart` | First exact host inputPending result | KEPT | A real Enter failure supplies sticky taint. |
| `TmuxPolicyRetirementTests.clearedInputKeepsFailureTaintAndDeviceRefusalUntilRestart` | Second exact host inputPending result after manual clear | KEPT | Manual clearing still cannot lift genuine failure taint. |
| `TmuxPolicyRetirementTests.clearedInputKeepsFailureTaintAndDeviceRefusalUntilRestart` | Exact single terminal refusal frame | KEPT | The genuine pending-input reason remains exact. |
| `TmuxPolicyRetirementTests.clearedInputKeepsFailureTaintAndDeviceRefusalUntilRestart` | Exactly one attempted Enter in the taint fixture | KEPT | The fixture now establishes genuine failure with that Enter. |
| `TmuxPolicyRetirementTests.lineTwoRetirementCompletesOnlyTheAdmittedLine` | Exact terminal policy-refusal message | WEAKENED | Whole-submission completion removes the unsent-paste classification for the admitted line. |
| `TmuxPolicyRetirementTests.lineTwoRetirementCompletesOnlyTheAdmittedLine` | Enter count includes an admitted second line | WEAKENED | Whole-submission admission completes that line before refusing later work. |
| `TmuxPolicyRetirementTests.taintedRig (fixture)` | Exact possiblySubmitted error | KEPT | The fixture now uses genuine Enter failure, retaining prior-attempt classification. |
| `TmuxPolicyRetirementTests.taintedRig (fixture)` | Exactly one Enter attempt | KEPT | The fixture establishes failure taint through that attempted Enter. |
| `AmbientWiringPolicyRetirementTests.taintedRig (fixture)` | Exact rebound error | KEPT | Real rebinding establishes sticky failure taint before policy is reallowed. |
| `TmuxSubmitConfirmationTests.cancellationDuringSettleCompletesTheSubmission` | Acknowledged settle barrier replaces the elapsed-time require | TIGHTENED | The timeout is only a watchdog; cancellation is delivered while settle is parked. |
| `TmuxSubmitConfirmationTests.cancellationDuringSettleCompletesTheSubmission` | Only the paste is delivered at the barrier | TIGHTENED | Proves the admitted paste precedes cancellation. |
| `TmuxSubmitConfirmationTests.cancellationDuringSettleCompletesTheSubmission` | Zero Enter effects before cancellation | TIGHTENED | Proves Enter has not completed before the boundary. |
| `TmuxSubmitConfirmationTests.cancellationDuringSettleCompletesTheSubmission` | Zero Enter effects after cancellation and before release | TIGHTENED | Proves completion remains blocked until release. |
| `TmuxSubmitConfirmationTests.cancellationDuringSettleCompletesTheSubmission` | Cancelled caller still receives completed delivery | WEAKENED | Whole-submission admission ignores later caller cancellation. |
| `TmuxSubmitConfirmationTests.cancellationDuringSettleCompletesTheSubmission` | Fresh later delivery succeeds | WEAKENED | Whole-submission completion does not create cancellation taint. |
| `TmuxSubmitConfirmationTests.cancellationDuringSettleCompletesTheSubmission` | Exact keys include both pastes and their Enters | WEAKENED | Whole-submission admission completes the first Enter and allows fresh work. |
| `TmuxSubmitConfirmationTests.cancellationDuringSettleCompletesTheSubmission` | Exact outcomes are confirmed and unsettled | WEAKENED | Whole-submission completion records both admitted submit outcomes. |
| `TmuxRefusalEvidenceTests.aConfirmedInsertThatCameBackIsNamedStaleAndOwnWithItsLengthAndAge` | Clock condition replaces a fixed age sleep | TIGHTENED | Waits for a whole second with a watchdog; exact age and evidence assertions are retained. |
| `TmuxRefusalEvidenceTests.aCancelledAdmittedPasteStillRecordsItsSubmit` | Acknowledged settle barrier replaces eventual paste polling | TIGHTENED | Cancellation occurs during the parked settle wait. |
| `TmuxRefusalEvidenceTests.aCancelledAdmittedPasteStillRecordsItsSubmit` | Only the paste has executed at the barrier | TIGHTENED | Separates actual side effects from recorded invocations. |
| `TmuxRefusalEvidenceTests.aCancelledAdmittedPasteStillRecordsItsSubmit` | Cancelled delivery completes | WEAKENED | Whole-submission admission permits the admitted Enter after cancellation. |
| `TmuxRefusalEvidenceTests.aCancelledAdmittedPasteStillRecordsItsSubmit` | Exact delivered keys include Enter | WEAKENED | Whole-submission admission completes the admitted Enter. |
| `TmuxRefusalEvidenceTests.aCancelledAdmittedPasteStillRecordsItsSubmit` | Exact outcome is unverifiable | TIGHTENED | Requires the frozen fixture to record its specific outcome. |
| `TmuxRefusalEvidenceTests.aCancelledAdmittedPasteStillRecordsItsSubmit` | Total evidence has exactly one record | KEPT | Unrelated extra evidence still fails the test. |
| `TmuxRefusalEvidenceTests.aCancelledAdmittedPasteStillRecordsItsSubmit` | The sole record equals the exact submit line | TIGHTENED | Checks the whole record rather than an event-filtered subset. |
| `TmuxRefusalEvidenceTests.aCancelledAdmittedPasteStillRecordsItsSubmit` | No pending-input evidence after cancellation | WEAKENED | Whole-submission completion does not create cancellation taint; genuine unsubmitted evidence is retained below. |
| `TmuxRefusalEvidenceTests.rebindingAfterPasteKeepsUnsubmittedEvidenceAndStickyRefusal` | Exact tainted/unobserved prefix | KEPT | The original unsubmitted-state assertion is restored in the genuine rebind-before-submit case. |
| `TmuxRefusalEvidenceTests.rebindingAfterPasteKeepsUnsubmittedEvidenceAndStickyRefusal` | Exact own_submitted=false last_submit=none suffix | KEPT | The original unsubmitted-state assertion is restored in the genuine rebind-before-submit case. |
| `TmuxRefusalEvidenceTests.rebindingAfterPasteKeepsUnsubmittedEvidenceAndStickyRefusal` | Later delivery refuses | KEPT | A real rebound pane remains sticky after binding and input recover. |
| `TmuxRefusalEvidenceTests.rebindingAfterPasteKeepsUnsubmittedEvidenceAndStickyRefusal` | Later refusal is exactly inputPending(tainted), twice | TIGHTENED | Checks both repeated refusals explicitly. |
| `TmuxRefusalEvidenceTests.rebindingAfterPasteKeepsUnsubmittedEvidenceAndStickyRefusal` | Exactly two total evidence lines | TIGHTENED | Both refusals produce only the expected evidence. |
| `TmuxRefusalEvidenceTests.rebindingAfterPasteKeepsUnsubmittedEvidenceAndStickyRefusal` | No submit outcomes | TIGHTENED | Rebinding occurs before any submit. |
| `TmuxRefusalEvidenceTests.rebindingAfterPasteKeepsUnsubmittedEvidenceAndStickyRefusal` | No evidence before later refusals | TIGHTENED | The failed pre-submit path emits no unrelated record. |
| `TmuxRefusalEvidenceTests.rebindingAfterPasteKeepsUnsubmittedEvidenceAndStickyRefusal` | Only two binding lookups after recovery | TIGHTENED | No capture, fill, paste or key call follows either refusal. |
| `TmuxRefusalEvidenceTests.rebindingAfterPasteKeepsUnsubmittedEvidenceAndStickyRefusal` | Exact delivered keys contain only the initial paste | TIGHTENED | No Enter or later text reaches the pane. |
| `TmuxDeliveryCommitTests.cancellationAfterTheCommitPointStillCompletesTheEnter` | Acknowledged recorded Enter replaces polling | TIGHTENED | The runner is parked before its responder side effect. |
| `TmuxDeliveryCommitTests.cancellationAfterTheCommitPointStillCompletesTheEnter` | Only the paste has executed before cancellation | TIGHTENED | Invocation recording cannot stand in for the Enter effect. |
| `TmuxDeliveryCommitTests.cancellationAfterTheCommitPointStillCompletesTheEnter` | Zero Enter effects before cancellation | TIGHTENED | Proves the in-flight Enter window. |
| `TmuxDeliveryCommitTests.cancellationAfterTheCommitPointStillCompletesTheEnter` | Zero Enter effects before barrier release | TIGHTENED | Cancellation cannot accidentally follow completed Enter. |
| `TmuxDeliveryCommitTests.cancellationAfterTheCommitPointStillCompletesTheEnter` | Exactly one Enter effect after completion | TIGHTENED | The admitted Enter completes once. |
| `TmuxDeliveryCommitTests.cancellationAfterTheCommitPointStillCompletesTheEnter` | Observed pane has no pending payload | TIGHTENED | Checks the clean pane directly. |
| `TmuxDeliveryCommitTests.cancellationAfterTheCommitPointStillCompletesTheEnter` | Exact original paste and Enter after completion | KEPT | Retains the original delivered-key assertion. |
| `TmuxDeliveryCommitTests.cancellationAfterTheCommitPointStillCompletesTheEnter` | Fresh later delivery succeeds | TIGHTENED | Proves no sticky cancellation taint. |
| `TmuxDeliveryCommitTests.cancellationAfterTheCommitPointStillCompletesTheEnter` | Exact final keys contain two pastes and two Enters | TIGHTENED | Bounds the fresh delivery as well. |
| `TmuxDeliveryCommitTests.cancellationBeforeTheCommitPointNeverSendsEnter` | Acknowledged fill barrier replaces polling and cleanup sleep | TIGHTENED | Cancellation happens during preparation and the task is drained before assertions. |
| `TmuxDeliveryCommitTests.cancellationBeforeTheCommitPointNeverSendsEnter` | Exact cancellation error | KEPT | Preparation remains cancellable before paste admission. |
| `TmuxDeliveryCommitTests.cancellationBeforeTheCommitPointNeverSendsEnter` | No delivered keys | KEPT | The buffer is never pasted. |
| `TmuxDeliveryCommitTests.cancellationBeforeTheCommitPointNeverSendsEnter` | Fewer than ten fill calls | KEPT | Cancellation stops chunk preparation. |
| `TmuxDeliveryCommitTests.cancellationBeforeTheCommitPointNeverSendsEnter` | Last call deletes the buffer | KEPT | Unused-buffer cleanup remains required. |
| `TmuxDeliveryCommitTests.aDeliveryAbandonedWhileQueuedTypesNothing` | Queued authority acknowledgement and actor fence | TIGHTENED | Proves enqueue before cancellation without fixed sleeps. |
| `TmuxDeliveryCommitTests.aDeliveryAbandonedWhileQueuedTypesNothing` | Exact cancellation error | KEPT | The queued request remains unadmitted. |
| `TmuxDeliveryCommitTests.aDeliveryAbandonedWhileQueuedTypesNothing` | Exact first-request keys only | KEPT | Queued input still types nothing. |
| `TmuxTaintedPaneTests.anAttemptAbandonedWhileFillingLeavesThePaneCleanForTheQueuedAndLaterDeliveries` | Acknowledged fill and queued-enqueue barriers | TIGHTENED | Replaces timing-dependent ordering without changing delivery assertions. |
| `TmuxTaintedPaneTests.anAttemptAbandonedWhileFillingLeavesThePaneCleanForTheQueuedAndLaterDeliveries` | Exact first-task cancellation | KEPT | The first delivery is abandoned before admission. |
| `TmuxTaintedPaneTests.anAttemptAbandonedWhileFillingLeavesThePaneCleanForTheQueuedAndLaterDeliveries` | Exact queued and later delivered keys | KEPT | The clean pane still accepts both later requests. |
| `TmuxTaintedPaneTests.anAttemptAbandonedWhileFillingLeavesThePaneCleanForTheQueuedAndLaterDeliveries` | Unused buffer is deleted | KEPT | Retains cleanup coverage. |
| `TmuxTaintedPaneTests.abandonmentBeforeAnyChunkDoesNotTaintThePane` | Acknowledged fill and queued-enqueue barriers | TIGHTENED | Cancellation of the queued request precedes any of its chunks. |
| `TmuxTaintedPaneTests.abandonmentBeforeAnyChunkDoesNotTaintThePane` | Exact queued-task cancellation | KEPT | The queued request remains unadmitted. |
| `TmuxTaintedPaneTests.abandonmentBeforeAnyChunkDoesNotTaintThePane` | Exact first and later delivered keys | KEPT | The refused queued request leaves no input or taint. |

## Verification record

Final executable source and tests were verified at
`6b0bdca092fa2374e3e31946788545b8acab651d`. The follow-up documentation commit changes this
record only. The VM verification clone was re-synchronized from a local full-HEAD
bundle and its `git rev-parse HEAD` matched before execution. No GitHub calls were made.

| Run/group | Tests | Suites | Result |
| --- | --- | --- | --- |
| Targeted repeat 1 | 274 | 64 | Passed in 109.184 s |
| Targeted repeat 2 | 274 | 64 | Passed in 112.499 s |
| Targeted repeat 3 | 274 | 64 | Passed in 108.436 s |
| Core broad families | 494 | 103 | Passed in 165.897 s; 10 known issues, zero unexpected issues |
| Ambient A–M | 111 | 21 | Passed in 97.272 s |
| Remaining Ambient | 507 | 107 | Passed in 425.728 s |
| Reply CLI | 124 | — | Passed in 215.313 s; exit 0 |
| Warnings as errors | — | — | `werr build=0`, exit 0; build completed in 41.49 s |

The three targeted runs cover every suite changed by this batch and the shared tmux runner's regression
families. Broad coverage is split into three disjoint bounded groups whose union is exactly the required
`HailDaemonKitTests\.(DeliveryAdmission|DeliveryAuthority|FinalDelivery|TaskProgress|Held|LocalDispatch|HailHost|Host|Ambient|Tmux|Reply|CommandLaunch)`
filter, including the new `TaskProgressTmuxAdmissionTests` suite. Broad total: **1,112 tests in 231 suites**, zero unexpected issues.
The ten deliberate known issues in the core group are the five each in the existing
`LocalDispatchPreflightWaitTests` and `ReplyRecipientHandoffWaitTests` diagnostics.

VM execution was synchronous over SSH with stdin redirected from `/dev/null`. Each phase finishes
before the next begins. A 600-second process-group watchdog surrounds each phase and joins its child;
termination/kill cleanup is available on timeout. Builds use `-j 4`, tests use `--no-parallel -j 4`.
No host build or test was run. Strict host lint passed all **22 Swift files changed from main**, with
zero violations. `git diff --check` passes. No physical-device, simulator or live tmux result is claimed.

`VM_TOOLS` below is a generic location for verification wrappers outside the repository;
`SYNC_BUNDLE` is the transferred git bundle.

Equivalent remote commands, run serially under the watchdog over SSH with
`< /dev/null`. Targeted round 1 passed before a log filter mistook a successful `outcome="failed"`
parameter for a failure; correcting that filter required no source change. The continuation ran rounds
2 and 3. The loop below represents the same build and test filter used for all three rounds:

```sh
# Wait for the shared VM verification lane to become idle.
git fetch "$SYNC_BUNDLE" HEAD
git checkout -B submission-verification FETCH_HEAD
git rev-parse HEAD
export PATH="$VM_TOOLS:$PATH"

for round in 1 2 3; do
  swift build --build-tests -j 4
  swift test --skip-build --no-parallel -j 4 --filter 'HailDaemonKitTests\.(Tmux|CommandLaunch|DeliveryAdmission|TaskProgress|Held|AmbientWiringPolicyRetirement)'
done

# The same idle check precedes each bounded broad group:
swift build --build-tests -j 4
swift test --skip-build --no-parallel -j 4 --filter 'HailDaemonKitTests\.(DeliveryAdmission|DeliveryAuthority|FinalDelivery|TaskProgress|Held|LocalDispatch|HailHost|Host|Tmux|Reply|CommandLaunch)'
swift build --build-tests -j 4
swift test --skip-build --no-parallel -j 4 --filter 'HailDaemonKitTests\.Ambient[A-M]'
swift build --build-tests -j 4
swift test --skip-build --no-parallel -j 4 --filter 'HailDaemonKitTests\.Ambient([^A-M]|$)'

python3 "$VM_TOOLS/phase.py" python3 -m unittest discover -s Tests/ReplyCLITests
python3 "$VM_TOOLS/phase.py" swift build --build-tests -Xswiftc -warnings-as-errors -j 4
```

The warnings-as-errors build (`swift build --build-tests -Xswiftc -warnings-as-errors`) uses the same watchdog.
Its helper temporarily adds `-j 4` to the build command and is restored afterward. Its required result
was `werr build=0` and wrapper exit 0. The helper's SHA-256 matched its pre-run value after restoration.
The build emitted the existing Command Line Tools missing module-cache debug-information warnings
and completed successfully.

Targeted-repeat and broad-group build/test logs, reply CLI output, and warnings-as-errors
build/result logs were retained on the VM.
Final inspection found no running phase, Swift build, Swift test or package-test process from this session.
The VM's tracked worktree was clean, and its executable verification head still matched the full hash above.

The existing real-tmux suites remain skipped when tmux is unavailable: `TmuxDeliveryCommitFakeTUITests`,
`TmuxDeliveryCommitShellPromptTests`, `TmuxIntegrationTests`, `TmuxPasteAgentTests` and `TmuxPasteEnterTests`.
Production-runner fixture tests execute without tmux. No tmux binary was installed.

Host lint command, run separately for every changed Swift file:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b swiftlint lint --strict <file>
```

Production-file counting loads `scripts/pr-shape.py` locally with `runpy.run_path`, reads
`git diff --name-status --find-renames 461b40c1 HEAD`, includes both names of renames, and applies
`EXCLUDED_PREFIXES` and `EXCLUDED_SUFFIXES` exactly. The result is **4**, equal to `MAX_SOURCE_FILES`.
The GitHub-dependent PR checker entry point was not called.

## Launch hold measurement

`CommandLaunchAdmissionTests.productionLaunchGateHoldMeasurements` completed on the VM with the
production runner. The passing runs recorded the following gate-hold intervals:

| Run | Launches | Minimum | Median | p95 | Maximum |
| --- | --- | --- | --- | --- | --- |
| Targeted repeat 1 | 60 | 0.123708 ms | 0.2467705 ms | 0.800708 ms | 1.146042 ms |
| Targeted repeat 2 | 60 | 0.109500 ms | 0.285583 ms | 0.800625 ms | 3.248750 ms |
| Targeted repeat 3 | 60 | 0.109375 ms | 0.478500 ms | 0.985125 ms | 12.999167 ms |

It measures 60 sequential production runner launches of `/usr/bin/true`, from immediately before the
synchronous launch operation until it returns, with process completion outside the measured interval.
Median is the mean of the two central values; p95 uses nearest rank. These are synthetic VM dispatch
measurements, not device or production latency guarantees.

## Scope

The checker excludes tests and documentation. Relative to main (and the tree-identical stage-order parent), the four
production files are:

- `Sources/HailDaemonKit/Adapters/Tmux/CommandRunner.swift`;
- `Sources/HailDaemonKit/Adapters/Tmux/TmuxAdapter.swift`;
- `Sources/HailDaemonKit/Adapters/Tmux/TmuxAdapter+Paste.swift`;
- `Sources/HailDaemonKit/Daemon/HailHost.swift`.

`TmuxAdapter+Submit.swift` is unchanged. Independent exact-head reviews and current required
GitHub protections remain separate release requirements; this local record does not claim those reviews.
No source was pushed, no installed build was replaced and no delivery was uploaded.
