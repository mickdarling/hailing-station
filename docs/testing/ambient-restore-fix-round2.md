# Ambient restore, fix round 2 (#904 ask 3)

Synthetic offline evidence for the restore-core and restore-app slices. This is
not a physical microphone round trip, an iOS application build, or physical haptic
proof. No installed build, TestFlight identifier, PR, issue, or remote ref changed.
Independent exact-head review of these fixes remains pending.

## Fail-before evidence

The eight review probes were ported into `AmbientReconnectReview*Tests` and run
against unchanged core head `4085ccdf6cc1213ce4ca6da39c82dc7675055293`.
The run exited 1: **8 tests, 6 failing, 10 failed assertions**. The six failing
methods were:

- `senderAlreadyInFlightMustNotRebindPreDropPCMToReplacementConnection`
- `delayedOldGenerationModeEventMustNotConfirmNewGenerationPrivacy`
- `failedOwnerPrivacyTapMustNotBeClearedByAnotherHostsConfirmation`
- `secondDropBeforeFirstResumedPCMStillMustDiscardAtCapture`
- `retainedSuccessCardMustNotKeepStreamingAfterTargetRemoval`
- `asynchronousWireRefusalMustNotAnnounceSuccessfulRestore`

The two second-drop probes during privacy confirmation and reauthorization
passed before the fix. Their notice expectations now require the newly specified
per-drop outcomes rather than the old coalesced success. The sender test feeds
fresh PCM after releasing its held old sender so a correct implementation can
progress after discarding the old send. The target-removal test does not wait for
forbidden PCM to appear. The origin test now injects the actual old generation
through the new dispatcher context and verifies a genuine new-generation
confirmation can subsequently restore. Test helpers only factor the long probes;
the failing security assertions remain in committed tests.

The host-local baseline log is `fix2-fail-before.log` in the authorized scratch
directory; it is not a committed build product. Its command used the common
flags below and `test --disable-xctest --no-parallel --filter AmbientReconnectReview
--skip DiagnosticReplyComposition`.

## Root causes and fixes

1. A controller send closure rewrote its binding to the latest one, including
   for a suspended, in-flight old encoder. Every queue send now carries its
   immutable capture epoch through executor hops. Each encoder's stream binds
   once, a new binding requires a resume start, and the connection actor checks
   the binding's generation before any send. Mismatches throw and discard; they
   never fall back to a newer binding. Late old-send errors cannot poison the
   replacement stream. The first restored frame is sequence zero with resume.
2. Privacy confirmation substituted the store's latest snapshot for callback
   provenance. The connection dispatcher now stamps the receiving generation
   before the callback's actor hop. Confirmation requires that exact generation;
   stale mode callbacks cannot change privacy state or settle a switch request.
3. Host confirmation used to clear a latched owner veto globally. Only
   `ownerStarted` now clears a veto. A healthy owner's unsettled switch request
   stays in that host's own request state; a drop with it pending, a gap tap, a
   failed send, or a mismatching confirmation latches the veto. Another host's
   notices cannot clear or reinterpret it. The regression also proves a fresh
   owner start clears the veto and permits a later restore.
4. Pending recovery skipped suspension on later drops. Every distinct dropped
   socket closes admission immediately, including after renewal but before PCM.
   Send failure and receive-loop reports for the same socket coalesce as one
   drop. A different dropped generation ends the interrupted attempt once as
   failed, starts a fresh attempt, and keeps the original 60-second deadline.
   The second-drop probes and
   `secondDropHasItsOwnOutcomeButCannotExtendOriginalCaptureDeadline` cover this
   definition of flapping, capture discard, background reuse, and terminal notice
   counts. No cancellation callback can revive an older attempt.
5. A completed notice retained the destination card, while an authoritative empty
   target list still yielded its old binding. The core invalidates that binding.
   The app slice renders the current notice at the root independently of the
   card, retains the card only for pending transport recovery, and keeps normal
   destination-loss and binding-change hooks active. It avoids putting obsolete
   reconnect successes in the unrelated announcement queue.
6. Ambient streams have **no positive host acceptance acknowledgement**. The
   existing pong acknowledges target selection, not acceptance of the stream.
   Therefore a terminal ambient refusal is published immediately on receipt,
   carrying both the connection generation and refused stream ID. The owning
   controller stops capture and revises any applied notice to failed/moved-away
   with the same notice ID. A refusal preceding send completion also prevents
   that completion from publishing applied. The separate
   `refusalAfterAppliedReplacesNoticeWithoutWaitingForMorePCM` test verifies the
   correction requires no subsequent PCM. Transient-refusal recovery is retained.

The reapplication starts with R0 (two infrastructure files) on main-24be, followed
by R1 (four restore files) and R2 (two app files). `AmbientListeningReconnect`
remains in its own file with its privacy-confirmation helper. A reasoned
file-length exemption keeps those related types together. The #932 segment
wiring, reply_yield and capability advertisement remain intact.

The original fail-before run above is retained; it was against the old R1 base,
not re-recorded against main-24be. The reapplication ports those same assertions
and reruns pass-after on the new base. Independent exact-head review is pending.

## Verification commands

Every Swift phase runs under `taskpolicy -b`, with `-j 4 -Xswiftc -j1`, automatic
resolution disabled, and scratch products only in the authorized scratch tree.
A process-group cleanup trap terminates descendants on interruption or a 590 s
phase timeout. Phases run sequentially, using at most four workers. Common test
support flags are:

```text
-Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
-Xswiftc -plugin-path
-Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
-Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
-Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Per branch: `swift build -Xswiftc -warnings-as-errors`; `swift build --build-tests`;
five `swift test --skip-build --disable-xctest --no-parallel --filter AmbientReconnect
--skip DiagnosticReplyComposition` runs. The serial broad family is
`Ambient|HostConnection|Listening|Reconnect|Notice|AudioGate|TapCapture|HeardTurn|Privacy|ReplySegment`.
It is partitioned into two bounded, non-overlapping lanes: HailCoreTests only,
then the same family excluding HailCoreTests. Both skip DiagnosticReplyComposition.
The five focused repetitions also execute the host pre-arm/start-private
`AmbientReconnectHostAdmissionTests` more than the required three times.

`restorePathNeverSendsPrivacyOffAcrossRepeatedDrops` covers both known-public and
known-private restores through two drops, and inspects every control send. The
privacy-host assertions separately require exactly one privacy-on per private
attempt. Restore never sends `set_privacy off`.

Manual strict lint review covers 200-line files unless already disabled or covered
by the coordinator's explicit exemption for the reconnect file,
150-line type bodies, 40-line function bodies, complexity 10, 120-column code,
parameter counts, nesting, optional Bool, and tuple sizes. The lightweight
brace-count aid misidentifies protocol requirements as function bodies; those
unchanged requirements were inspected manually. Whitespace-only closing-brace
cleanup in the ported tests preserves the exact non-whitespace token sequence.
`git diff --check` is also required.

## Reapplication boundaries

R0 supplies origin task-locals, opt-in refusal notices, and the optional immutable
send-admission predicate. R1 samples the capture epoch when creating each queue;
that predicate checks the same gate after every executor hop. R1 explicitly opts
in to refusal notices around both `connect` and foreground nudges so every
replacement receive-loop task inherits the flag. R1 alone remains inert for
transport restoration until an app attaches its controller.

The incremental production-file counts are R0 **2**, R1 **4**, R2 **2**.
The cumulative counts against main-24be are **2**, **5**, **7**, respectively;
the review bases must be main-24be, R0, and R1. No renamed file is involved.
R1's four files are Capture.swift, AmbientAudioStreamer.swift,
AmbientListeningReconnect.swift, and Transport/HostConnectionStore.swift.
The #932 store suffix and both ingress hooks were compared with main-24be;
they remain byte-for-byte intact. The R0 protocol patch keeps reply_yield and
ReplySegments capability advertisement.

The new-base commands use warnings-as-errors on the test build too. The first
clean CLT link emits debug-module-path warnings for scratch PCM references;
no Swift source warning is suppressed. iOS app builds and physical haptic/audio
proof remain unverified on this Command Line Tools-only VM.

### R1 results on main-24be plus R0

Both required builds passed. All **54 focused tests in 18 suites** passed on each
of five runs. The serial broad lanes passed **377 tests in 99 suites** (236.673 s)
and **637 tests in 141 suites** (423.036 s), including the #932 device, host, and
protocol segment suites. No DiagnosticReplyComposition suite ran. All six failed
review probes now pass, along with the extra late-refusal and flapping deadline
checks and every earlier privacy/no-off test. Manual strict-warning lint review
and `git diff --check` passed; the brace-count aid's two Capture protocol findings
are declaration false positives, not function bodies. The reconnect file uses
only the expressly permitted, reasoned file-length exemption.

### R2 results and final-tree checks

R2 changes only StationCard.swift and RootView+DestinationSelection.swift in
production. The completed notice lives on the root surface, independently of
the card. The card is retained only during pending recovery; disappearance still
calls destinationLost. The destination-selection helpers are grouped in two
extensions within the same 199-line file, without another exemption or file.
The notifier deduplicates the haptic by notice ID when a late refusal corrects a
success. Existing per-stop notification titles remain unchanged.

Both required SwiftPM builds passed. All **55 focused tests in 19 suites** passed
on each of five runs. The serial broad lanes passed **378 tests in 100 suites**
(240.990 s) and **637 tests in 141 suites** (417.080 s). The #932 segment suites
remain green. DiagnosticReplyComposition was excluded throughout.
`successNoticeNeverRetainsCaptureOrAuthorizesADestination` models target removal,
destination change, and card disappearance; all three cases release capture,
clear the active binding, and forbid later PCM while retaining notice history.
This model is not native SwiftUI or physical-device proof.

A final blank-closing-brace cleanup in R1 test support preserves every Swift
token. Both required builds were rechecked on the final R1 and R2 source trees.
The extra final R1 review selection passed **9 tests in 6 suites**; the extra
R2 lifetime selection passed **1 test with 3 cases**. Strict-warning manual lint,
committed-range `git diff --check`, exact production-file counts (including rename
handling), and the three-commit stack audit passed. No other new lint exemption
was added. Old R1/R2, interrupted WIP, and main-24be refs remain unchanged.

The initial fail-before evidence remains the recorded old-base run; it was not
replayed on main-24be. No independent approval, GitHub protection result, native
iOS build, physical haptic, or live captured-output proof is claimed.
## R8 coordinator rulings and pass-after record

The preceding R7/reapplication entries are historical. This fix starts from R0
`411ecb1b0be70b8ff13d1f7283c92776b6cd60a9`, R1
`ad018fa710f90f63e76063399050cf844b9cdf35`, and R2
`02b2c2676c481a9e358ea1bc38462308df92c2d8`, on main-24be
`24be5c5180a54103334026793f411bf083f9d172`. The supplied review logs are the
fail-before evidence on those heads. They are synthetic scripted transports,
not physical microphone, haptic, device, or native SwiftUI execution evidence.
Independent review of the new heads remains pending; the prior verdict is
REQUEST CHANGES. Nothing here claims a completed approval or GitHub checks.

### F1: declined finding, realistic owner-tap orderings retained

No new production veto rule was added for F1. The rejected probe injects a
successful confirmation after the same socket's receive has already failed.
That confirmation cannot arrive over the failed receive path. Its hypothetical
ordering is not evidence that a successful healthy-link tap must latch forever.
`successfulOwnerTapDuringUnpublishedDropMustRemainLatched` was **not ported**.
The original log's failing lines included:

```text
Expectation failed: !((rig.controller → HailCore.AmbientListeningController).isListening → true → true)
Expectation failed: (rig.notices.last?.reason → nil) == .privacy
Expectation failed: try await audioFrames(rig.socket).isEmpty
```

The reachable orderings are pinned instead:

- `failedOwnerPrivacyTapMustNotBeClearedByAnotherHostsConfirmation` sends a tap
  while close is held; the send fails, the veto survives another host's notice
  and restoration, no PCM resumes, and only an owner start clears it. Its pending
  assertion now reflects F3's earlier loss signal, preserving the veto assertions.
  The two directions in `privacyTapBeforeDropPublicationMustBlock` receive the
  same pending-state update; both still require a privacy stop and one notice.
- `unconfirmedOwnerPrivacyTapBlocksRestoreAtDrop` sends successfully but gets no
  confirmation before loss; drop stops with reason privacy, and restoration
  sends no PCM.
- `staleGenerationCannotSettlePendingOwnerPrivacyTap` proves a stale duck_mode
  leaves the request pending. The existing
  `delayedOldGenerationModeEventMustNotConfirmNewGenerationPrivacy` proves a stale
  generation cannot confirm a reassert. `earlyConfirmationWaitsForSuccessfulReassertSend`
  supplies a matching-generation notice while send is held and proves no resume
  until send succeeds. Ordinary send-first confirmation remains covered by
  `knownPrivacyReassertsBeforeResumeWithOrWithoutPark`.

### F2: both send and notice must succeed within the same five seconds

`AmbientRestorePrivacy` records send success and matching-generation confirmation
separately. Either order is valid. An early notice cannot finish/cancel the send;
its later error or the five-second timeout fails closed. A failed send reported
by the loss hook settles the privacy waiter before ordinary drop handling, while
receive loss during confirmation retains the existing flapping recovery policy.
This preserves zero PCM before confirmation, the original hard 60-second bound,
and the rule that restore never sends privacy off. Host notices do not veto.

`confirmationMustNotEraseLaterReassertSendError` preserves the failed probe's
security assertions. Its old wait for premature binding change is replaced with
a wait for delivery of the early notice plus an assertion that binding is still
unchanged; the error is then released. The original failing lines were:

```text
Expectation failed: !((rig.controller → HailCore.AmbientListeningController).isListening → true → true)
Expectation failed: try await audioFrames(base).isEmpty
```

### F3: close latency cannot admit capture or extend the deadline

R0 installs an optional transport wrapper only for opted-in connections. It binds
the receiving/sending socket's generation before negotiation, awaits the loss
observer before rethrowing a raw transport failure, and preserves the original
close/publication behavior when absent. No existing production code is moved.
R1 installs the observer with store-token and generation guards, suspends capture
admission, and starts the original deadline immediately. The later reconnecting
snapshot deduplicates the same generation. The original flapping deadline and
capture-epoch tests remain intact. The held-close probe is committed as
`transportCloseMustNotDelayDiscardOrStartOfDeadline`; its failed assertions were:

```text
Expectation failed: (rig.capture.discardedCount → 0) == (before + 6 → 6)
Expectation failed: !((rig.controller.reconnect → HailCore.AmbientListeningReconnect).withinDeadline() → true)
Expectation failed: !((rig.controller → HailCore.AmbientListeningController).isListening → true → true)
```

R0's `absentLossHookPreservesCloseBeforeReconnectPublication` pins the unchanged
state/publication order during a held close, and
`optedInLossReportsLostGenerationBeforeCloseOrStatePublication` pins the early
opt-in callback. Its other default wire, sequence, notice, queue and failure
proofs are recorded in ambient-restore-send-origin.md.

### F4: a corrected restore notice owns its stop notification

The coordinator records when a terminal refusal replaces an applied notice.
Controller end suppresses the ordinary unexpected-stop callback only for that
replacement, leaving the same notice ID for the app's existing haptic dedupe.
`lateGenericRefusalMustNotEmitAnExtraOrdinaryStopNotice` keeps the same-ID,
failed-outcome and empty ordinary-notice assertions; it also pins both outcome
callbacks to the same notice ID. The supplied failing line was:

```text
Expectation failed: (rig.unexpected → ["Stopped: the host ended listening (not_allowed: ambient busy)."]).isEmpty → false
```

`AmbientListeningRecoveryTests.aFinalRefusalStopsAtOnceAndIsReported` remains
unchanged and requires one ordinary unexpected-stop notice for a non-restore
terminal refusal. It is included in R1's selected verification and R2's broad lane.
Native haptic delivery remains unverified; the synthetic proof covers callbacks
and notice identity, with the app's existing per-ID haptic deduplication retained.

### F6: refusal opt-in survives all loop replacements

R0 replaces the task-local opt-in with an immutable per-HostConnection flag,
false by default. R1 enables it when constructing its connections; the connect
and foreground task-local wrappers are removed. Deadline callbacks, foreground
nudges and reconnect backoff use the same flag. The separate origin-generation
and stream-ID task-locals remain observer provenance only.
`refusalOptInMustSurviveNegotiationDeadlineLoopReplacement` ports both assertions
from the detached deadline probe. The original failed lines were:

```text
Expectation failed: await recorder.events.count == 1
Expectation failed: await recorder.streams == [stream]
```

### R8 verification method and R1 commands

Use the exact common command prefix/flags and scratch path in the R8 section of
ambient-restore-send-origin.md. Every Swift process runs under taskpolicy -b,
-j 4 -Xswiftc -j1, the required CLT Testing framework/plugin/rpaths, automatic
resolution disabled, and a 590-second process-group kill trap. Phases are
sequential; no phase exceeds ten minutes. DiagnosticReplyComposition is skipped.

R1 actions: `build -Xswiftc -warnings-as-errors`;
`build --build-tests -Xswiftc -warnings-as-errors`;
`test --skip-build --disable-xctest --no-parallel --filter
'AmbientReconnect|SendOrigin|AmbientListeningRecovery' --skip DiagnosticReplyComposition`.

R1 R8 results: the production build and final test build passed with
warnings-as-errors. The selected **77 tests in 26 suites passed in 126.974 s**.
An initial selection failed only the two old pending-state expectations in
`privacyTapBeforeDropPublicationMustBlock`; the corrected full selection above
passed. The existing ordinary terminal-refusal stop test passed unchanged.
The ported F2/F3/F4 assertions, realistic F1 tests, generation guards, privacy
no-off tests, and R0 SendOrigin tests all passed. Strict manual warning-threshold
lint and `git diff --check` passed. New functions, types, lines, parameter counts,
complexity and nesting stay within .swiftlint.yml; no lint suppression was added.
R1's production-file set remains Capture.swift, AmbientAudioStreamer.swift,
AmbientListeningReconnect.swift and Transport/HostConnectionStore.swift (four
incremental, six cumulative against main-24be). The R0 set is now three files,
using HostConnection.swift plus the existing two. No file was renamed or moved.

### F5: applied background restore advances root authorization

The root destination synchronously accepts the coordinator's applied binding
only when it equals the store's current ambientBinding for the selected host
and target and the listening controller still owns it. The existing remembered
endpoint/target checks still apply. This predicate is independent of scene phase,
so rendering can retain the real destination in the same update that clears
pending recovery. The notice-change handler and remembered-selection
reconciliation also accept that core-authorized generation in the background;
they do not start another target-selection round trip. Card disappearance and
current-binding update hooks remain active for genuine destination loss.

`backgroundRestoreMustKeepListeningAfterPendingCardDisappears` ports the review
probe's desired assertions: changed generation, listening survives, and capture
starts once. It retains the assertion that the *former* foreground-only predicate
would remove the card, then checks the corrected predicate keeps it and subsequent
PCM continues without restarting/releasing capture. The original failed line in
`r2-app-probe.log` was:

```text
Expectation failed: (rig.controller → HailCore.AmbientListeningController).isListening → false
```

`appliedBackgroundBindingNeverAuthorizesARealDestinationLoss` covers target
removal, endpoint change and owner selection after background restore. All stop
capture and forbid subsequent PCM through the real disappearance/binding-update
hooks. The existing `successNoticeNeverRetainsCaptureOrAuthorizesADestination`
now runs all three lifetime cases both after foreground and background restore.
The tests model the root/card authorization predicates; **native SwiftUI execution
is not verified on this VM**. SwiftPM builds do not compile the iOS app, and no
physical microphone, haptic or captured-output round trip is claimed.

### R8 R2 verification commands

Use the same common prefix/flags/scratch path as R0. Actions:

```text
build -Xswiftc -warnings-as-errors
build --build-tests -Xswiftc -warnings-as-errors
test --skip-build --disable-xctest --no-parallel --filter AmbientReconnectApp --skip DiagnosticReplyComposition
test --skip-build --disable-xctest --no-parallel --filter AmbientReconnect --skip DiagnosticReplyComposition
```

The AmbientReconnect selection runs three times. The requested broad expression
is `Ambient|HostConnection|Listening|Reconnect|Notice|AudioGate|TapCapture|HeardTurn|Privacy|Segment`.
It runs once across three non-overlapping bounded lanes, each with
`test --skip-build --disable-xctest --no-parallel`, the common flags, and these
filter/skip arguments (substitute the expression above for FAMILY):

```text
--filter 'HailCoreTests.*(FAMILY)' --skip DiagnosticReplyComposition
--filter 'HailDaemonKitTests.*(FAMILY)' --skip DiagnosticReplyComposition
--filter 'FAMILY' --skip 'DiagnosticReplyComposition|HailCoreTests|HailDaemonKitTests'
```

R2 remains exactly two production files incrementally, eight cumulatively
against main-24be. The root selection file is 200 lines without a new exemption;
only blank separators, guard layout and call-argument formatting were compacted.
Existing explanatory comments and production-file locations are preserved.

R2 R8 focused results: both required warnings-as-errors builds passed. The app
model selection passed **3 tests in 2 suites** in 16.041 s, including six
foreground/background lifetime cases and the three background destination-loss
cases. All **63 tests in 22 suites** passed on each of three AmbientReconnect
runs (142.156 s, 134.965 s, 143.358 s). The fail-before probes' security assertions
remain in committed tests, including the original F5 broken-predicate assertion
as a comparison with the corrected destination predicate. No DiagnosticReplyComposition
suite ran. No production/test/app/manifest source changed during these repetitions.

The broad Core lane passed **396 tests in 109 suites** in 242.220 s. A content
hash audit confirms all 991 source/test/app/manifest files remained unchanged
through the repeated selection and this broad lane. The remaining broad lanes
use the same binary and unchanged sources.

The broad DaemonKit lane passed **593 tests in 135 suites** in 422.415 s; the
remaining-module lane passed **50 tests in 9 suites** in 0.193 s. Thus the broad
selection passed **1,039 tests in 253 suites**, with no overlap between lanes and
no DiagnosticReplyComposition execution. Every phase completed below 590 s.
All six required builds passed. The source hash audit remains unchanged.

Final strict-lint inspection found two blank-line violations in the newly added
HostConnectionSendOriginCloseTests.swift: one blank before the suite's closing
brace and one extra separator before its recorder actor. The earlier R0 manual
lint statement missed these whitespace rules. The prepared correction removes
only those two blank lines and preserves every non-whitespace token. Because R0's
single requested fix commit already exists, applying that correction without
rewriting history needs a coordinator exception for a second R0 commit followed
by normal merges into R1/R2. That exception is pending; functional verification
is complete, but strict lint is not yet complete on the three branch heads.

## R10: host vetoes belong to the current owner run

The previous restored binding survives a stop/start so R2 can inspect the applied
restore. It must not let removal of that earlier host latch a veto in a fresh run
on another host. `veto(_:host:)` now matches the controller's current binding, or
the retained binding only while a restore is pending. The retained binding remains
available to R2's applied-restore acceptance. Owner stop/off, privacy taps,
target/endpoint changes or removal, explicit disconnect, and mode changes retain
their existing current-run veto paths.

The review probe is committed as
`AmbientReconnectPreviousHostTests.removingPriorRestoredHostMustNotVetoCurrentHostsRecovery(removePrevious:)`.
Its two arguments are unchanged: `false` keeps host A configured as the control;
`true` removes A after an applied restore on A, owner stop, and a fresh start on B.
Both require B's later transport drop to keep capture and arm recovery. Helpers
only split setup for strict lint; neither assertion is weakened.

Before changing production code, this test ran against supplied R1 head
`4fa30fbd655708dc2fa9b6f21607aaf8af189c93`. It exited 1 with **1 test, 2 cases,
2 failed assertions**, both for `removePrevious: true`; the control had no failure.
The exact failing assertion lines in `AmbientReconnectPreviousHostTests.swift`
were:

```text
26:9: Expectation failed: (rig.controller.reconnect → HailCore.AmbientListeningReconnect).isPending → false
28:9: Expectation failed: (rig.controller → HailCore.AmbientListeningController).isListening → false
```

The assertion messages were “A stale previous-host recovery binding latched an
unrelated endpoint-removal veto” and “Current host's transport drop must retain
capture after only the old host was removed”. The uncommitted-build-products log
is `<scratch>/r1-fail-before.log`; it reports 4.108 seconds of test execution.

All R10 Swift phases use the common Testing flags above, `taskpolicy -b`,
`-j 4 -Xswiftc -j1`, offline resolution, and `<scratch>/build`. A process-group
kill trap covers interruption and a 590-second phase timeout. Phases run
sequentially with at most four workers. Each new branch head gets both
`build -Xswiftc -warnings-as-errors` and
`build --build-tests -Xswiftc -warnings-as-errors`. The R1 pass-after selection is
`test --skip-build --disable-xctest --no-parallel --filter AmbientReconnectPreviousHost
--skip DiagnosticReplyComposition`. The R2 head gets three serial
`AmbientReconnect` selections plus one serial broad selection matching
`Ambient|HostConnection|Listening|Reconnect|Notice|AudioGate|TapCapture|HeardTurn|Privacy|Segment`,
partitioned into HailCoreTests and the remaining targets to bound each phase.
Every test command skips DiagnosticReplyComposition. Results are reported with
the delivered heads; these remain synthetic package checks, with independent
exact-head review and physical-device proof pending.

Manual strict-warning lint checks cover the new test's file/type/function length,
complexity, nesting, parameter count, identifiers and 120-column code lines. The
veto predicate adds one boolean guard within the existing thresholds. No blank
line or explanatory comment is removed, and no lint suppression is added.
R0 remains three production files, R1 four, and R2 two, at their stack boundaries.

## R12: mutation strength for the latched privacy veto (finding 3)

The supplied per-finding mutation review found three vacuous tests on the R11
stack: the failed-owner privacy tap probe, plus the app authorization and app
lifetime suites. The privacy probe tapped only after F3 had reported transport
loss and armed recovery. That tap ended pending recovery immediately, so the
other host's later confirmation could not affect the outcome. The two app suites
copied their app predicates and therefore could not detect mutations to the app.

The R12 privacy probe fails the owner's privacy control send while the connection
is ready and capture is listening. A synthetic `HostConnectionFailure.remote`
control refusal leaves the receive loop healthy; unlike a transport error, it
does not invoke F3's loss observer. Assertions require the failed switch request
to be settled, no pending restore or notice, and continued listening both before
and after the other host confirms its own privacy switch. Only then does the
bound host drop and reconnect. The probe requires a privacy-blocked restore,
no replacement PCM, and stopped listening. The existing owner-start tail still
proves that a fresh owner start clears the veto and permits a later restore.
A cleanup guard also lets a mutant reach that tail after assertion failures,
without turning its unexpected continued listening into a wait timeout.

This R1 increment changes tests and this evidence document only. Its four
production files relative to unchanged R0 are still Capture.swift,
AmbientAudioStreamer.swift, AmbientListeningReconnect.swift, and
Transport/HostConnectionStore.swift. No production mutation is committed.

### Mutation A: fail before, pass after

The temporary mutation added `clearVetoForMutation() { veto = nil }` to the
coordinator and called it on every accepted `duck_mode` in the store, regardless
of host. The targeted command was `test -Xswiftc -warnings-as-errors
--disable-xctest --no-parallel
--filter failedOwnerPrivacyTapMustNotBeClearedByAnotherHostsConfirmation
--skip DiagnosticReplyComposition`, with the common flags above. It exited 1:
**1 test in 1 suite, 4 failed assertions, 3.068 s**. Exact assertion lines:

```text
AmbientReconnectReviewVetoTests.swift:23:9: Expectation failed: (rig.notices.last?.reason → nil) == .privacy
AmbientReconnectReviewVetoTests.swift:25:9: Expectation failed: !((rig.controller → HailCore.AmbientListeningController).isListening → true → true)
AmbientReconnectReviewVetoTests.swift:27:9: Expectation failed: frames.allSatisfy { if case .audio = $0.payload { return false }; return true }
AmbientReconnectReviewVetoTests.swift:34:9: Expectation failed: (rig.notices.map(\.outcome) → [HailCore.AmbientListeningReconnect.Outcome.applied, HailCore.AmbientListeningReconnect.Outcome.applied]) == ([.blocked, .applied] → [HailCore.AmbientListeningReconnect.Outcome.blocked, HailCore.AmbientListeningReconnect.Outcome.applied])
```

Both production files were restored byte-for-byte before the pass-after run.
The raw mutation and restored logs are `r1-mutation-A.log` and
`r1-restored-A.log` in `hs-904-R12-scratch`; no build products are committed.

The restored test passed: **1 test in 1 suite, 2.813 s**. Both required R1 head builds use warnings-as-errors,
including `build --build-tests`. Every R12 phase waits on the supplied literal
`pgrep -f "swift-build|swift-test|swift-frontend"` gate at 60-second intervals
before launching Swift. The scratch Python runner applies `taskpolicy -b`,
`-j 4 -Xswiftc -j1`, offline resolution, all common Testing flags, and process-group
TERM/KILL cleanup on interruption or the 590-second execution limit. The initial
build/test compilation emits CLT linker debug-module-path warnings, as in earlier
rounds; no Swift source warnings are suppressed. Manual strict-warning lint
review and `git diff --check` cover the changed test. The iOS app cannot be built
on this CLT-only VM; package checks remain synthetic.
