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

## R13: refusal identity, flap wording, and retired send failures

This round supersedes the historical unrestricted notice-replacement rule in
root cause 6 above. An applied restore does not own every later refusal in the
listening run. Replacement now requires the exact restored stream and binding,
including its connection generation, before acceptance. The same identity check
also has the original 60-second restore bound as a backstop; elapsed time alone
never authorizes replacement. An accepted stream's later refusal follows the
ordinary stop path, preserving the actual reason or the calm moved-away handoff.
`replacedAppliedNotice` is set only when that same bounded replacement occurs.

Acceptance uses the existing confirmed ping/pong round-trip machinery. The R1
store adds an identity-aware `confirmRoundTrip(for:)` overload on the connection,
using its existing pending pings, generation guard, send API and pong deadline.
It sends one ping after successful delivery of the restored first segment.
The host processes that socket's frames in order and refuses ambient streams at
start, so its matching pong proves acceptance if no refusal preceded it. The
probe retains its nonce and registration token. Refusal delivery queries that
exact nonce on the connection actor before stopping the controller. This also
handles a pong followed immediately by a refusal while the polling confirmation
task has not resumed. A failed, canceled, unregistered, or retired-generation
probe cannot prove acceptance. No wire message or R0 file changed.

The pre-acceptance regression now waits for that ping without answering it,
advances only an injected clock by five seconds, and requires replacement of the
same notice ID without another ordinary-stop callback. The app's existing
notice-ID deduplication therefore preserves one haptic per drop. The
post-acceptance regression answers the ping and immediately sends either final
refusal, without waiting for the polling task or more PCM. Both require the
ordinary path. Another test rejects mismatched stream and generation identities.
None of these acceptance tests depends on wall-clock delay.

An interrupted attempt now has outcome `interrupted` and says
“Connection dropped again; still reconnecting”, with a reconnecting title.
Capture remains armed, the original deadline remains in force, and each drop
still owns one distinct notice. Existing flap/deadline expectations use that
outcome. The R2 presentation uses current listening/pending state to offer a
resume action, so this outcome needs no app adaptation.

A send failure is ignored when its immutable binding generation differs from
the current store snapshot. This prevents a late old-socket error from treating
the replacement as another drop. The streamer's one-shot transport-resume flag
is cleared when a recovery decision is consumed, when transport is suspended,
and when capture stops. A held backoff completing after transport resume cannot
grant a later unrelated failure a free restart. The admission-versus-queue-check
race remains fail-closed and is documented beside the check; no admission rule
was relaxed. Restore still never sends privacy off, capture still discards gap
PCM, and only an owner start clears an owner veto.

The compiler fix uses exactly a separately typed `let elapsed: Duration =
now() - began`, followed by the deadline ternary subtracting `elapsed`. The other
instant differences in this touched coordinator likewise use separately typed
locals. This follows the supplied older-host type-check evidence; local package
builds do not claim execution on that older compiler.

### R13 fail-before evidence

The requested probes were ported under normal test names and compiled against
the unchanged supplied R1 production head. `test --disable-xctest --no-parallel
--filter AmbientReconnectLate --skip DiagnosticReplyComposition`, with the
common offline flags, exited 1: **4 tests in 2 suites, 5 failed assertions,
8.583 seconds**. Both arguments of the parameterized refusal test failed on
assertions, not setup or timeout. Exact original assertion locations:

- `refusalLongAfterAppliedRestoreUsesOrdinaryStopPath(movedAway:)`, true and
  false: `AmbientReconnectLateRefusalTests.swift:25`, notice count was 2, not 1.
  The false argument also failed at line 26: ordinary-stop count was 0, not 1.
- `interruptedAttemptNoticeDoesNotTellArmedOwnerToTap`:
  `AmbientReconnectLateDropTests.swift:18`, the notice said listening stopped
  while capture remained armed and resumed without a tap.
- `lateOldGenerationSendFailureDoesNotCreateAnotherDrop`:
  `AmbientReconnectLateDropTests.swift:51`, outcomes were failed then applied
  instead of one applied notice.
- `refusalWithoutRestoreUsesOrdinaryStopPath`, the requested P1 control, passed
  before the fix (0.816 seconds). It is a passing control, not failed evidence.

The raw baseline is `<scratch>/fail-before.log`; test additions and production
fixes are committed, while the supplied probe file and all build products remain
outside the repository. Later assertions added to the flap test shift its final
source locations; the fail-before locations above refer to the actual baseline
log. No failure is attributed to the passing control.

The focused flag regression was also present in that pre-fix test binary. Its
separate `--skip-build --no-parallel --filter AmbientReconnectResumeFlag` run
exited 1: **1 test in 1 suite, 1 failed assertion, 0.398 seconds**.
`transportResumeDuringBackoffDoesNotAuthorizeAnUnrelatedFailure` failed at
`AmbientReconnectResumeFlagTests.swift:39`: three stream identities were offered
instead of two. The binary was built before any production edit; this additional
baseline used that unchanged binary even though source fixes were being prepared.
Its raw log is `<scratch>/fail-before-resume-flag.log`.

### R13 R1 pass-after

Both warnings-as-errors builds passed after the final recovery adjustment:
`build -Xswiftc -warnings-as-errors` (2.85 seconds) and
`build --build-tests -Xswiftc -warnings-as-errors` (3.90 seconds).
The targeted serial selection matching `AmbientReconnectLate|AmbientReconnectAcceptance|
AmbientReconnectResumeFlag|AmbientReconnectReviewRefusal|AmbientReconnectReviewFlapping|
AmbientReconnectFlappingDeadline|AmbientReconnectFixRound` passed **16 tests in
8 suites, 33.958 seconds**, including both arguments of each refusal test.

An earlier test build rejected a test input edited during compilation; the
stable retry passed. The first pass-after also exposed an extra recovery callback
when stopping cleared the cached queue decision. The final change clears only
the one-shot permission at stop and preserves the once-per-queue decision.
The flag regression now requires two stream identities and two decisions, and
passes. These intermediate failures are retained in scratch logs; neither is
reported as a passing check.

Manual strict-warning lint review covers changed type/function lengths,
complexity, nesting, parameters and 120-column code. The unchanged failure
accessor and its complete explanatory comment moved next to the recovery
methods to keep the streamer type below the warning threshold. No blank lines
were deleted to meet a limit, and no suppression was added. `git diff --check`
passes. CLT linker debug-module-path warnings remain the previously documented
scratch-path warnings; Swift source warnings are treated as errors.

### R13 supplementary send-refusal ordering

The first R13 implementation passed three full R2 repetitions (74 tests in
27 suites each), but path review found that a send can observe the connection's
stored refusal before the wire-refusal callback reaches the controller. The
send-error path now performs the same exact-pong check before reporting its
error, through the shared `acceptConfirmedResume` store helper.

`sendRefusalAfterAcceptancePongUsesOrdinaryStopPathWhileWaiterIsHeld` holds the
post-segment ping's send completion after forwarding it. It waits for the
matching pong to finish the ordered receive callback, then injects a synthetic
remote audio-send refusal while the confirmation sender is still held. This
forces the alternate delivery path without timing assumptions. On the first
R13 implementation, before the shared-helper fix, it exited 1 with **1 test in
1 suite, 3 failed assertions, 2.178 seconds**. Original assertion locations in
`AmbientReconnectAcceptanceSendTests.swift` are line 29 (two notice deliveries
instead of one), line 30 (replacement incorrectly set), and line 31 (ordinary
stop callback suppressed). The raw log is
`<scratch>/acceptance-send-fail-before.log`. No generated identifiers are copied
from that log. The fixture releases the held ping during teardown in both runs.

The refined R1 warnings-as-errors production and test builds passed. The same
targeted selection, now including the held-ping send-refusal regression, passed
**17 tests in 9 suites, 35.838 seconds**. All original probe assertions and
both refusal delivery paths pass together.

The first refined full R2 run passed all production-fix regressions but failed
its no-restore control's combined notice/ordinary-stop assertion. That control
previously returned from `feed()` without awaiting its asynchronous first send;
it could inject an ambient refusal before the connection had an ambient stream.
The control now explicitly waits for its first audio frame and requires no
pending recovery or notice before sending the refusal. This establishes the
normal-stream premise without a wall-clock assumption. Its original fail-before
run remains a passing control; the full post-refinement repetitions are rerun
with this explicit ordering barrier. The unsuccessful run is retained as
`<scratch>/r2-final-focused-1.log`, not counted as a passing repetition.

### R13 completed verification
The ordered R1 control selection passed **2 tests in 1 suite, 4.095 seconds**.
The three full R2 serial repetitions after that ordering fix each passed
**75 tests in 28 suites**: 141.994 seconds, 143.053 seconds, 147.945 seconds.
All use `--skip-build --disable-xctest --no-parallel --filter AmbientReconnect`
and `--skip DiagnosticReplyComposition`, with the common offline/resource flags.
The complete requested broad family ran once in three non-overlapping serial
module lanes, each with its own 590-second execution bound and process cleanup:

- core: **410 tests in 116 suites**, 281.919 seconds.
- daemon: **593 tests in 135 suites**, 417.257 seconds.
- remaining modules: **50 tests in 9 suites**, 0.186 seconds.

Total broad selection: **1053 tests in 260 suites**.
The final successful logs contain no assertion issues and no
DiagnosticReplyComposition suite/test start. The raw logs are
`r2-ordered-focused-1.log` through `r2-ordered-focused-3.log`, and
`r2-broad-core.log`, `r2-broad-daemon.log`, `r2-broad-remaining.log` in the
uncommitted scratch directory. Earlier failed runs remain explicitly documented.

Both required warnings-as-errors build commands passed for each slice's final
production/test tree. After this results-only update, both commands are required
again on each delivered head before bundling; those logs use `r1-final-build`,
`r1-final-build-tests`, `r2-final-build`, and `r2-final-build-tests`.

Every Swift launch uses the process gate, `taskpolicy -b`, `-j 4 -Xswiftc -j1`,
offline resolution, all supplied Testing flags, and process-group TERM/KILL
cleanup on interruption or a 590-second execution limit. Manual strict-warning
lint review and `git diff --check` pass. No additional lint suppression or
blank-line deletion is used. R0 is unchanged. R1 retains exactly its four
production files; R2 retains its original three, byte-for-byte, with no app
adaptation commit. These are synthetic package checks; native iOS/older-host
compiler execution, physical audio/haptic proof, and independent exact-head
approval remain unclaimed. No remote ref, PR or issue was changed.

## Acceptance completion before the sender continuation

The independent delta finding exposed an executor-ordering gap: the matching
post-segment pong cleared the restored stream's acceptance proof, but recovery
remained pending until the first audio sender's continuation resumed. A terminal
refusal in that interval therefore emitted a failed connection-drop notice and
suppressed the ordinary stop alert, despite proven stream acceptance.

### Fail-before evidence

The unchanged production tree was built with warnings-as-errors, then the ported
`AmbientReconnectAcceptanceSettlingTests` (in AmbientReconnectAcceptanceCompletionTests.swift) and
`AmbientReconnectAcceptanceOrderingTests` ran serially with the common offline
flags and `--skip DiagnosticReplyComposition`. The test run exited 1: **6 tests
in 2 suites, 1 failing test, 2 failed assertions, 14.299 seconds**, with no timeout.
`acceptedStreamRefusalBeforeSenderContinuationResumesUsesOrdinaryStop` failed at
`Tests/HailCoreTests/AmbientReconnectAcceptanceCompletionTests.swift:34:9`
(no failed connection-drop notice) and `:36:9` (one ordinary stop alert).
The original pending-state observation at line 31 passed. The raw evidence is
`<scratch>/fail-before.log`; generated runtime identities are not copied here.

All five regression methods in `AmbientReconnectAcceptanceOrderingTests` passed
before the fix, including both arguments of the first method:

- `orderedRefusalAfterPongUsesOrdinaryStopWhileConfirmationSendIsHeld`
- `terminalRefusalOfRenewedStreamCannotRewriteUnacceptedRestore`
- `unrelatedPongCannotAcceptRestore`
- `stalePongOnReplacementCannotAcceptNewRestore`
- `sendErrorBeforeMatchingPongRevisesSameNotice`

These cover ordered pong/refusal receipt while the confirmation sender is held,
a genuinely renewed non-restored stream, unrelated and retired-generation pongs,
and a send refusal before the matching pong. The latter identity-matched refusal
still revises the existing notice; another stream cannot revise it.

### Fix and regression coverage

After checking the acceptance object's identity, `accepted()` now settles a still
pending, renewed restore as applied. The usual finish path cancels its deadline
and publishes one applied notice immediately. `sent()` explicitly requires a
pending restore, so its later callback cannot publish a second notice. The
existing notice delivery and app deduplication therefore retain one haptic per
drop; physical haptic delivery is not claimed by these package tests.

The original regression now requires no pending restore and exactly one applied
notice before the refusal and after sender teardown. Its two original refusal
assertions remain intact. `acceptanceAndSendCompletionPublishOneNoticeAndHapticHook`
keeps listening active and explicitly checks both orders: matching pong first
with the sender held, and sender completion first with acceptance still pending.
It counts exactly one notice/haptic callback after each step and requires the
same single applied notice ID. A following audio frame proves the held sender
passed transportSent and resumed its queue.
`settlingNeverChangesPrivacyOrSendsPrivacy` runs both orders separately, comparing
the complete `privacyLocal` and `duckMode` dictionaries across each step and
rejecting every outgoing `set_privacy` frame. The host explicitly confirms
privacy off before settling; settling cannot change that state. Identity matching and the pre-acceptance refusal
replacement path are unchanged. No protocol, app, or additional production file
is changed by this fix.


### Acceptance-completion verification

The clean scratch rebuilds passed with the common offline and Testing flags:
`build -Xswiftc -warnings-as-errors` (50.75 seconds) and
`build --build-tests -Xswiftc -warnings-as-errors` (132.85 seconds).
The serial acceptance-completion, acceptance-ordering, and privacy-settling
selection passed **8 tests in 3 suites**, 23.433 seconds. This includes both
parameterized completion orders for the notice/haptic hook and privacy checks,
and all five ported F1 regression methods (including both ordered-refusal cases).
The original fail-before assertions remain recorded above and in the pre-fix
commit; this pass-after run has no assertion issues.

On the merged app tree, both warnings-as-errors build forms passed (4.94 seconds
and 59.04 seconds). All three full serial `--filter AmbientReconnect` repetitions
passed **83 tests in 31 suites** each, in 186.539, 191.020, 191.646 seconds.
Each uses `--skip-build --disable-xctest --no-parallel` and
`--skip DiagnosticReplyComposition`, with the same common flags.
The complete requested broad family
`Ambient|HostConnection|Listening|Reconnect|Notice|AudioGate|TapCapture|HeardTurn|Privacy|Segment`
ran once in three serial, non-overlapping module lanes:

- core: **418 tests in 119 suites**, 316.741 seconds.
- daemon: **593 tests in 135 suites**, 415.266 seconds.
- remaining modules: **50 tests in 9 suites**, 0.199 seconds.

Total broad selection: **1061 tests in 263 suites**.
The core and daemon filters are `^HailCoreTests[.].*(family)` and
`^HailDaemonKitTests[.].*(family)`; the remaining lane selects the full family
and excludes those two modules. Every lane also skips DiagnosticReplyComposition.
The successful logs contain no recorded assertion issue and no start of that
excluded suite or its tests. Raw evidence is in `<scratch>/r1-acceptance.log`,
`r2-focused-1.log` through `r2-focused-3.log`, and `r2-broad-core.log`,
`r2-broad-daemon.log`, and `r2-broad-remaining.log`.

Every launch first waits on the supplied literal Swift-process gate. Each phase
uses `taskpolicy -b`, `-j 4 -Xswiftc -j1`, a 590-second execution bound, and
process-group TERM/KILL cleanup. Scratch products from the interrupted run were
removed before the clean rebuilds. Missing debug module-cache path warnings
still appeared during linking after that cleanup; the compiler
warnings-as-errors builds exited successfully. These are toolchain debug-path
warnings, not a claim of warning-free linker output.

Manual strict-warning lint review and committed-range `git diff --check` pass.
No lint suppression, blank-line removal, or code reflow was added to satisfy a
threshold. The base slice is unchanged; the restore slice retains exactly its
four production files, and the app slice's incremental production files are
unchanged. Final delivered-head rechecks use `r1-final-build.log`,
`r1-final-build-tests.log`, `r2-final-build.log`, and `r2-final-build-tests.log`.
These remain synthetic package checks; native app builds, physical audio/haptic
delivery, and independent exact-head approval are not claimed.

## Deadline, endpoint refresh, and suspension-order follow-up

The host's sleep change is retained: optional injected sleep values default to
nil; production waits go through `ambientSleep(for:injected:)` and directly call
`Task.sleep(for:)`. No stored async closure-literal or static-function default is
reintroduced on those paths. The macOS 15 / Xcode Swift 6.2.4 abort is tracked
separately in #991; actor-method overload hygiene did not cause or fix that abort.
The host recorded five passing repetitions of its formerly crashing test.

### Acceptance deadline fail-before

The reviewer's deadline case is committed as
`AmbientReconnectAcceptanceDeadlineTests.acceptanceAfterSixtySecondsMustNotCancelRecoveryDeadline`.
Against unchanged restore production after the infrastructure hygiene merge,
the warnings-as-errors test build passed. The serial probe then failed without
a timeout: **1 test in 1 suite, 3 assertion issues** at
`Tests/HailCoreTests/AmbientReconnectAcceptanceDeadlineTests.swift:28:9`,
`:30:9`, and `:31:9`: applied instead of blocked, no timedOut reason, and capture
still listening. Evidence is `<scratch>/deadline-fail-before.log`.

### Deadline and endpoint policy

Identity-matched acceptance now calls `withinDeadline()` before settling the
pending restore. At or after 60 seconds the existing timedOut block path ends
capture; the pong cannot publish applied or cancel that bound as a success.
The sender-completion deadline guard remains in place.

A same-host endpoint refresh updates the pending endpoint and display name,
suspends admission, and cancels old acceptance/privacy confirmation work. It
retains the original began time, target identity, known privacy requirement, and
owner selection serial. An active stream can enter that same bounded recovery
path when its endpoint is refreshed. A secure-to-insecure scheme downgrade is
rejected as endpointChanged. Removal, explicit disconnect, owner host/target
changes, and a missing or dead retained target continue to end listening.

The per-connection callback token is always replaced, never resurrected. Confirmed
selectedTargets and outstanding selectionRequests are cleared; only the existing
owner selection serial is retained for a permitted refresh. The new connection
must handshake, advertise the matching live retained target, and complete a new
selection ping/pong before producing a binding. Known-private recovery uses the
existing privacy-on reassertion and confirmation before PCM. No remembered URL,
old token, old confirmation, or different target authorizes a send. Connection
construction is factored into a helper to keep the upsert body within strict
warning limits without code reflow or another production file.

### Adapted suspension races

`offRevokesResumeInsideTransportSelectionConfirmation` holds the restore's
selection pong, turns listening off, then delivers the pong. Capture starts only
once and no sequence-zero segment may reach the wire.
`newerDestinationOwnsSelectionWhileTheOlderOneDrains` holds A's sender, applies
the existing binding-observer stop path, requests B then C, and confirms C before
B. Only C may retain a binding or send audio when A drains. Ask 3 does not expose
Part 10's drain-aware destinationSelected API: B may appear on the wire while it
is current, but its later confirmation must never overwrite C.
`systemEndDuringStopThenTheStreamWatcherClaimsOnlyOnePause` posts an interruption
synchronously from capture stop, holds both the retry and release, and checks one
pause owner, one release, and one capture start while the stream watcher ends.
It uses the interruption cause because a generic engine stop ends listening in
ask 3; that policy is preserved. Explicit gates replace scheduling delays for
host execution on Swift 6.2.4. The endpoint-replacement race is shared with the
URL/name and public/private refresh test rather than copied from another API.
