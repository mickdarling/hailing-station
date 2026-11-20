# #1246: privacy cutoff and stop-control ordering

Part of #1246. This is the stacked follow-up `fix/1246-stop-scope` on corrected first-branch head
`0f4333a0a6607c5fa5a13c6a6099192753da3771`. Install both branches together. The supplied independent round 5 review of
`56ddd18c85e7c39281826a0cf0344e6ccd0c1043` reported over-stopping and no P1 finding.
The reviewer's boundary probe sources and log were read before implementation. This record describes
local corrective verification; fresh independent exact-head review remains pending.

## Fixes

- **P2a:** `closePrivacyEntry` captures the privacy announcement's request cutoff and transport barrier in the
  same router-lock step that decides its clip. `decideEntry` and `announceEntry` carry that immutable control
  to the listener. The listener carries its supplied cutoff explicitly into session retirement, so a delayed
  announcement cannot accept a fresh stop covering a request admitted after privacy exit.
- **P2c:** The existing connection-scoped cutoff remains the sole request-stop authority. Its gate also holds
  transient pending-control tokens for wire ordering. Newer correlated publication waits asynchronously
  outside all locks; final synchronous commit checks the barrier again. A newer request refused solely by that barrier
  preserves its existing record, waits for the control, and retries all normal gates.
  The prepared `stop_playback` is enqueued under the same request-stop mutex before its barrier is removed
  and waiters resume. Network completion is awaited after that mutex is released. Failed control enqueue
  retires the transport before releasing newer frames. Voice-report coalescing and older-device capability
  handling retain their existing decisions. Peer retirement clears barriers and resumes waiters, whose
  retired transport grants no publication authority. No wire format or device-controller code changes.
- **P3:** Remove `endSegmentTracking()` and the per-teardown task invoking that empty method. Peer teardown
  now clears its request-stop gate synchronously after transport retirement.

The lock order is still policy/binding, privacy, optional ticket queue, request-stop gate, transport handoff.
No actor hop, asynchronous wait, or transport-completion wait runs while the request-stop mutex is held.
The pending-control tokens grant no request, target, recipient, policy, or media authority.

## Regressions and scope

`ReplyPrivacyStopScopeTests` commits the reviewer's held-decision / privacy-exit / new-request probe, with
only its suite name, diagnostic-print removal and formatting changed. It checks retained request state,
publication status, and actual text delivery after the delayed announcement.

`ReplyStopControlOrderTests` holds an accepted stop before session retirement, admits a newer request, and
starts its text publication. It checks that publication waits, then verifies real loopback wire order:
`stop_playback`, newer text, newer audio. Both marked and unmarked stops are exercised, including an audio-only newer reply. Peer-retirement and caller-cancellation regressions verify
that waiting publication terminates, and that a cancelled attempt preserves the later request for retry. The earlier
`ReplyQueueStopAcceptanceTests` retain their request/ticket/flight preservation assertions; their later text
publication now runs asynchronously and explicitly checks the stop comes first, matching the new device-order
requirement. Both pre-audio and streaming continuation cases remain covered. All earlier-round queue,
authority, privacy, recipient, controller, and stop regressions remain in the selection below.

Against the first-branch head, the checker's exact exclusions and rename handling count **3/4 production
files, zero renames**: `Sources/HailDaemonKit/Listener/HostReplyDelivery.swift`,
`Sources/HailDaemonKit/Listener/WebSocketListener.swift`, and
`Sources/HailDaemonKit/Listener/WebSocketPeer.swift`. Tests and docs are excluded. Scripts remain byte-identical
to the supplied main `f12ba2fbf78e26566b9aa4a7b4b0f968846b948f`; HailCore and app files have no changes.
The first branch's separate record is `docs/testing/1246-new-request-reply-queue.md`.

## Commands

Before each build/test phase, the scratch runner executes the host-slot gate then the full voice-quiet gate,
rechecks host load after quiet, and caps the work command at 810 seconds. `$SCRATCH` is the external scratch
directory; configuration, temporary files and module caches are isolated there. Every phase exports the Xcode
developer directory. The unchanged host harness uses fake binaries and service tools with isolated directories.
The first expanded Swift selection is shown here; the final #1246 and affected privacy-reply selection is
recorded under Privacy refusal compatibility below.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
taskpolicy -b swift build --build-tests -j 2 --cache-path "$SCRATCH/swift-cache"
taskpolicy -b swift test --no-parallel --skip-build --cache-path "$SCRATCH/swift-cache" \
  --filter '(Reply(NewRequestQueue|QueueAuthority|QueueLifecycle|QueueStopAcceptance|QueueStopCoverage|QueueConnectionCheck|PrivacyStopScope|StopControlOrder|QueuedAudio|Segment|Playback(Recipient|Controller|Stop|Supersede|FirstAudio)|Recipient|StreamPacer)|RequestStreamLifetime|ProviderTurnRequestLifetime|LateAnswer|FinalDelivery|DeliveryStageOrder|RecipientPublicationGate|HostPlaybackStop|DeviceVoiceStop|AmbientWiringDismiss|AmbientWiringVoiceMute|SessionUpdateAudioAdmission|AmbientPrivacy|AmbientDuck|ModeSnapshot)'
# Working directory: Tests/ReplyCLITests
python3 -m unittest discover -s .
# Working directory: worktree root
env PATH="$SCRATCH/host-bin:$PATH" taskpolicy -b bash scripts/tests/test-host.sh
# All changed Swift files across both branches, with the new regression files staged.
swiftlint lint --strict --no-cache --cache-path "$SCRATCH/swiftlint-cache" \
  $(git diff --name-only f12ba2fbf78e26566b9aa4a7b4b0f968846b948f -- '*.swift')
```

## Mutations

The scratch runner saves all three production-file SHA-256 digests, applies one fault at a time, runs a fresh
gated build and its gated targeted test, and restores source in `finally`. A mutation must build successfully
and produce exit 1 with the intended assertion; a timeout, compilation error, or empty test selection does
not count. Each mutation uses the build command above, followed respectively by:

```sh
taskpolicy -b swift test --no-parallel --skip-build --cache-path "$SCRATCH/swift-cache" \
  --filter 'ReplyPrivacyStopScopeTests.delayedPrivacyAnnouncementMustNotRetractPostExitRequest'
taskpolicy -b swift test --no-parallel --skip-build --cache-path "$SCRATCH/swift-cache" \
  --filter 'ReplyStopControlOrderTests.newerReplyFollowsStopOnWire'
```

1. **P2a:** Replace `let control = stop?.control ?? requestStop` with `let control = stop?.control` at the listener
   boundary, so an unmarked announcement takes the fresh-control fallback. This accepts a fresh cutoff when the
   held announcement resumes, rather than using the privacy decision's immutable cutoff.
2. **P2c:** Remove both the asynchronous `waitForControl(connection)` call in correlated delivery and the final
   pending-control guard in `ReplyConnectionStopGate.commit`. The request cutoff still applies, but newer
   publication can reach the socket before the unscoped stop control.

After both faults are removed, all three production digests must match the saved fixed bytes. The restored
implementation is rebuilt and the final #1246/privacy-reply selection below is repeated. No mutation remains in the commit.

All results are synthetic Swift, local socket/PCM, CLI, or fake-service harness checks. No push, PR, live
configuration change, installation, daemon restart, simulator/device build, physical playback, or captured-output
round trip is part of this work. Local tests are not independent review approval.

## Build corrections and A/B

The initial follow-up build failed in **14.985 s** (`split2-build.log`): this toolchain's `Mutex` is noncopyable,
so it cannot be the value of `TaskLocal`. The retry indicator now uses a small `Sendable` reference object
containing the mutex; this is only an attempt-local retry signal, not another request-authority source.

The next build compiled the production code but reported noncopyable parameters in the new test helper.
Its owned build process group was stopped after that diagnostic (**152.526 s**, `split2-fixed-build.log`),
rather than compiling the remainder of a known-failing test module. The helper now accepts `Sendable`
reference signals, and its task failure type uses `any Error`. Neither failed/incomplete build counts as
verification evidence.

The same build command on the separate worktree at pinned main
`f12ba2fbf78e26566b9aa4a7b4b0f968846b948f` passed: **1.54 s** Swift / **5.412 s** work-command time
(`split2-main-ab-build.log`). These were introduced ownership/type errors and were corrected; no pre-existing
failure exemption is claimed. The main comparison uses the same Xcode environment, scratch cache and gates
listed above, with working directory `$SCRATCH/main-ab`.

## Privacy refusal compatibility

The first expanded Swift run selected **646 tests in 142 suites** and failed after **424.977 s** test /
**434.213 s** work (`split2-swift.log`): there was **1 unexpected issue**, plus the same 8 known issues.
All five new round-5 regression methods passed, including both marked/unmarked text-first and audio-only
wire cases, cancellation, and peer retirement. The additional failure was
`AmbientPrivacyReplyRaceTests.aFastEntryAndExitNeverLetsAnOldReplyThrough`: a request fenced at privacy
entry was refused before the active hold could report the existing `privacyHeld` result.

The unchanged suite on pinned main passed **5 tests in 1 suite**, **5.406 s** test / **12.862 s** work
(`split2-main-ab-privacy-race.log`). Exact gated command, working directory `$SCRATCH/main-ab`:

```sh
taskpolicy -b swift test --no-parallel --skip-build --cache-path "$SCRATCH/swift-cache" \
  --filter 'AmbientPrivacyReplyRaceTests'
```

The compatibility correction recognizes a retained, committed request already fenced by its own connection's
cutoff while that connection's privacy hold is active. It checks the existing candidate/media and policy/binding
authority, then uses the existing held-refusal path. This is refusal classification only; candidate admission
and final transport commit continue to enforce the cutoff. The original regression is unchanged.

Final verification selects all earlier #1246 regression families, the new round-5 cases, controller first-audio
behavior, and both directly affected privacy-reply suites. The broader exploratory run is recorded above as a
failure, not a passing result. This exact final selection is run after the correction and again after mutation
restoration:

```sh
taskpolicy -b swift test --no-parallel --skip-build --cache-path "$SCRATCH/swift-cache" \
  --filter '(Reply(NewRequestQueue|QueueAuthority|QueueLifecycle|QueueStopAcceptance|QueueStopCoverage|QueueConnectionCheck|PrivacyStopScope|StopControlOrder|QueuedAudio|Segment|Playback(Recipient|Controller|Stop|Supersede|FirstAudio)|Recipient|StreamPacer)|RequestStreamLifetime|ProviderTurnRequestLifetime|LateAnswer|FinalDelivery|DeliveryStageOrder|RecipientPublicationGate|HostPlaybackStop|DeviceVoiceStop|AmbientWiringDismiss|AmbientWiringVoiceMute|SessionUpdateAudioAdmission|AmbientPrivacyReply)'
```

## Executed final results

| Phase | Result | Work-command time | Evidence under `$SCRATCH` |
| --- | --- | --- | --- |
| Compatible build | Passed; 122.56 s Swift | 126.872 s | `split2-compatible-build.log` |
| Final #1246/privacy-reply selection | 409 tests in 93 suites passed; 151.486 s test; 8 known issues | 160.32 s | `split2-compatible-swift.log` |
| Full Reply CLI suite | 174 tests passed; 377.906 s test | 380.596 s | `split2-cli.log` |
| Unchanged host harness | `test-host: OK` | 154.909 s | `split2-host.log` |
| P2a mutant build | Passed; 32.81 s Swift | 36.305 s | `split2-mutation-privacy-build.log` |
| P2a mutant regression | Expected exit 1: 1 test in 1 suite failed; 1.691 s test; 3 issues | 10.691 s | `split2-mutation-privacy-test.log` |
| P2c mutant build | Passed; 38.46 s Swift | 42.649 s | `split2-mutation-control-order-build.log` |
| P2c mutant regression | Expected exit 1: 1 test in 1 suite failed; 0.397 s test; 6 issues | 8.585 s | `split2-mutation-control-order-test.log` |
| Restored build | Passed; 32.13 s Swift | 36.243 s | `split2-restored-build.log` |
| Restored #1246/privacy-reply selection | 409 tests in 93 suites passed; 153.112 s test; 8 known issues | 161.423 s | `split2-restored-swift.log` |


The successful final selections each contain only the same eight deliberately matched known
publication-gate/handoff timeout and cancellation issues. No unexpected failure remains in these final
checks. The unchanged privacy-race regression passes after the classification correction.

The P2a fault produced the intended retained-record, ready-status and text-delivery failures. The P2c fault
allowed newer text to complete before the held stop, and the socket received text before the control, in both
marked and unmarked cases. These are assertion failures in real selected tests following successful builds;
none is a timeout, compilation error, or empty selection.

After each fault, all three production files were restored. SHA-256 equality against the saved fixed bytes
was checked before the restored build (`split2-fixed-digests.json`, `split2-restoration.log`). Final working
and staged source bytes also match those fixed digests (`split2-final-scope.log`). The full CLI suite and host
harness used the same fixed bytes before mutation; the restored build and final Swift selection replace and
verify the mutant binaries. No fault is retained.

Final strict lint covers all **24 Swift files changed across both branches** and reports zero violations
(`split2-final-lint.log`). Final checker-based scope is **3/4 production files against the first-branch head,
zero renames**. Scripts match pinned main; HailCore/app files are unchanged. Working/staged whitespace and
source-byte checks pass. These checks are local and synthetic; independent review of the new exact heads
remains pending.


## Round 6: requestless publication ordering

The supplied round-6 review approved PR 1 at
`2380d5c676138828a5e5f5d87279d0242de96945` and requested changes to PR 2 at
`35d828c62ee96642a4f9ee827a9400637be3cd37`. Its requestless reproducer and failure log were read
before implementation. The reproducer is committed as `ReviewRound6RequestlessOrderProbes`, with
prints removed and the existing wait signal replacing the fixed negative polling interval. Both marked
and unmarked cases still reserve a newer requestless audio ticket while an accepted stop is held, publish
its text, and assert actual loopback order **stop, text, audio**. The admission-only ticket/status paths
remain nonblocking; neither grants transport authority.

Routed/requestless publication now waits asynchronously, then retries a final control-only refusal with
fresh preparation and all its ordinary recipient/policy/privacy/ticket checks. `PreparedWebSocketReply`
carries its connection's ordering scope: preparation waits and final synchronous enqueue checks the same
stop mutex. Correlated commit still checks the request cutoff and uses the same nested synchronous scope.
The private scope avoids relocking only while an outer same-connection commit already owns that mutex;
there is no suspension in that scope. Requestless clip batches and stop-confirmation batches take one
control check across all their prepared frames. Transport completion stays outside every control lock.

### Publication audit

| Publication | Boundary and stop behavior |
| --- | --- |
| Correlated text/audio, including ticketed CLI frames | Existing async wait/retry and cutoff commit; nested prepared enqueue shares that atomic check. |
| Last-input routing, pinned requestless replies and single-terminal fallback | `deliverRoutedReply` waits/retries, then checks the control under the final privacy/ticket gates. Stopped reply IDs still refuse audio. |
| Ordinary acknowledgements and host privacy/mode clips | `deliverRequestlessReply` uses routed delivery for every frame. A stop between frames still retires any already-started audio stream; it cannot make a later frame gain authority. |
| Privacy-respecting acknowledgement/not-sent clips | `deliverRequestlessClip` waits/retries and holds the final control check across the whole text/audio batch. |
| Spoken stop confirmations | `confirmAmbientStop` prepares with the shared wait and takes one control check inside its existing device-stop admit callback for the whole batch. |
| Session-update cards, including silent cards and task-progress cards | `deliverSessionUpdate` calls shared preparation and final prepared enqueue inside its existing policy/binding/privacy/fence gates. A new control after preparation refuses enqueue without a delivered card. |
| Proactive/session-update audio | `enqueueSessionUpdateAudio` uses shared preparation/final enqueue plus its existing proactive stop-generation and privacy gates. A control after preparation refuses publication; renderer cleanup runs as before. |
| Station cues | `enqueueAnnouncement` is device-local, uses `ReplyStreamKey.announcementEndpoint` and a fresh local UUID, and creates no host reply presentation or first-audio claim. It sends nothing on this connection. An accepted stop may cancel shared playback, but cannot label a newer host reply as stopped through a cue. |
| Other `send`/`post` frames | Hello/state (including owner-voice status), mute/mode/duck, heard/overheard, route-failure and session-update-cancel controls have no new host reply descriptor/audio stream. They update state or retire an existing identity, so cannot introduce a newer host first-audio claim. Ping/close transport frames likewise create none. |

`ReplyPublicationControlBarrierTests` exercises the routed, ordinary acknowledgement, privacy-respecting
clip, confirmation-batch, card/task-progress prepared-frame and proactive-audio boundaries against real
loopback sockets, with both marked and unmarked stops. Dedicated card/task-progress/audio policy entry
points remain covered by their existing suites; the new wire tests use their shared prepared-frame
boundary with synthetic frame shapes. Each case also starts an old requestless audio stream and proves
its continuation remains refused after the stop. A separate final-check test accepts a control after
preparation and proves no enqueue occurs until that control is completed. These tests are synthetic,
not physical playback or independent review evidence.

### Round-6 commands and evidence

`$SCRATCH` is the external task scratch directory. Each build/test command below is launched by the
scratch `phase.py` runner after the user-supplied `hostslot-wait.sh` and then `voice-quiet.sh` gates.
The runner exports `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, isolates temporary/config
and module-cache directories in scratch, records the exact command and result, and caps each work command
at 810 seconds. No live configuration, install, daemon restart, simulator build or device delivery is involved.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
taskpolicy -b swift build --build-tests -j 2 --cache-path "$SCRATCH/swift-cache"
taskpolicy -b swift test --no-parallel --skip-build --cache-path "$SCRATCH/swift-cache" \
  --filter '(ReviewRound6RequestlessOrderProbes|ReplyPublicationControlBarrierTests)'
taskpolicy -b swift test --no-parallel --skip-build --cache-path "$SCRATCH/swift-cache" \
  --filter '(ReviewRound6RequestlessOrderProbes|ReplyPublicationControlBarrierTests|Reply(NewRequestQueue|QueueAuthority|QueueLifecycle|QueueStopAcceptance|QueueStopCoverage|QueueConnectionCheck|PrivacyStopScope|StopControlOrder|QueuedAudio|Segment|Playback(Recipient|Controller|Stop|Supersede|FirstAudio)|Recipient|StreamPacer)|RequestStreamLifetime|ProviderTurnRequestLifetime|LateAnswer|FinalDelivery|DeliveryStageOrder|RecipientPublicationGate|HostPlaybackStop|DeviceVoiceStop|AmbientWiringDismiss|AmbientWiringVoiceMute|SessionUpdateAudioAdmission|AmbientPrivacyReply)'
taskpolicy -b swift test --no-parallel --skip-build --cache-path "$SCRATCH/swift-cache" \
  --filter '(SessionUpdate|SilentSessionUpdate|TaskProgress)'
# Working directory: Tests/ReplyCLITests
python3 -m unittest discover -s .
# Working directory: worktree root
env PATH="$SCRATCH/host-bin:$PATH" taskpolicy -b bash scripts/tests/test-host.sh
# With intended files staged; all eight Swift files changed versus PR 1.
swiftlint lint --strict --no-cache \
  $(git diff --cached --name-only 2380d5c676138828a5e5f5d87279d0242de96945 -- '*.swift')
```

The first build exposed an introduced nonescaping-to-optional-escaping closure mismatch in the batch
helper (`round6-build.log`). The correction preserves its nonescaping commit closure and nests the
connection check inside it. A/B uses a separate detached worktree at PR 1's exact head and the identical
gated build command (`round6-pr1-ab-build.log`); no protected branch is checked out or changed.
The next build reached the new test module and caught a missing actor-isolated `connectionID` await
in its final-race test (`round6-fixed-build.log`, 69.203 s work). That introduced test error is corrected;
the PR 1 A/B build passes with the same build command and environment. No baseline-failure exemption
is claimed for either introduced compilation error.
An initial lint launch without the required developer-directory export could not load SourceKit;
with the export, formatting findings were corrected. These failed preflights are not passing test evidence.

Mutation method: save all three production files and their SHA-256 digests. In `deliverRoutedReply`,
remove its explicit asynchronous wait and call preparation with `waitForControl: false`; replace only the
connection-only `commit(UUID, ...)` overload with direct enqueue. The correlated request overload keeps
its cutoff and barrier checks. After a successful mutant build, run the exact command below and require
exit 1 with the intended wait/wire assertions in both cases. Restore the saved bytes in `finally`, compare
all three digests, rebuild, and repeat the full #1246 selection above. Compilation errors, timeouts and
empty selections do not count as successful mutation evidence.

```sh
taskpolicy -b swift test --no-parallel --skip-build --cache-path "$SCRATCH/swift-cache" \
  --filter 'ReviewRound6RequestlessOrderProbes'
```

### Executed round-6 results

| Phase | Result | Work-command time | Evidence under `$SCRATCH` |
| --- | --- | --- | --- |
| PR 1 A/B build | Passed; 766.91 s Swift | 770.767 s | `round6-pr1-ab-build.log` |
| Corrected build | Passed; 77.57 s Swift | 81.798 s | `round6-fixed-build2.log` |
| Round-6 wire regressions | 3 tests in 2 suites passed; 3.468 s test | 10.692 s | `round6-targeted.log` |
| #1246 selection | 412 tests in 95 suites passed; 155.546 s test; 8 known issues | 161.876 s | `round6-swift.log` |
| Session-update/task-progress selection | 214 tests in 58 suites passed; 92.628 s test | 98.747 s | `round6-session-progress.log` |
| Full Reply CLI suite | 174 tests passed; 378.470 s test | 381.516 s | `round6-cli.log` |
| Unchanged host harness | `test-host: OK` | 160.401 s | `round6-host.log` |
| Requestless mutant build | Passed; 28.90 s Swift | 34.087 s | `round6-mutation-build.log` |
| Requestless mutant regression | Expected exit 1: 1 test in 1 suite failed; 0.401 s test; both marked/unmarked cases, 6 intended issues | 8.651 s | `round6-mutation-test.log` |
| Restored build | Passed; 36.50 s Swift | 40.426 s | `round6-restored-build.log` |
| Restored #1246 selection | 412 tests in 95 suites passed; 160.024 s test; 8 known issues | 169.236 s | `round6-restored-swift.log` |

The two introduced compilation errors were corrected, as described above; the unchanged PR 1 A/B
build passes. All final Swift selections pass with no unexpected failures. The eight matched known
issues in each #1246 run are the existing synthetic publication-gate/handoff timeout/cancellation checks.
The mutant builds successfully, then the committed reproducer fails its wait and actual wire-order
assertions in both marked and unmarked cases (6 intended issues); neither timeout nor compilation
failure is counted as mutation proof. All three production SHA-256 digests match the saved fixed bytes
before the restored build (`round6-fixed-digests.json`, `round6-restoration.log`). The CLI, host and
extra session/progress selections used these same fixed source bytes before mutation; the restored
build replaces the mutant products before the full #1246 selection runs again. No mutation remains.

Final strict lint covers all eight Swift files changed versus PR 1 and reports zero violations
(`round6-all-changed-lint.log`). Checker's exact exclusions and rename handling count **3/4 production
files, zero renames**, against PR 1's pinned head. Scripts match pinned main/origin-main
`f12ba2fbf78e26566b9aa4a7b4b0f968846b948f`; HailCore and app files are unchanged
(`round6-scope.log`). No source push, PR, live configuration change, installation, daemon restart,
simulator/device build, physical playback or captured-output round trip was performed. A fresh
independent review of the new local exact head remains pending.


## Full-suite host-gate corrections

The first slice was amended to preserve the correlated expiry refusal contract and to include the
small privacy-refusal classification correction described above. This stacked slice is rebased
as one commit on that corrected first-slice head. Both original regression tests remain unchanged
and fully enforced; no known-issue wrapper is added or inherited.

The expiry failure came from an extra request-clock read introduced by the first slice's queue
check inside `replyCandidate`. The deterministic clock expired before ready status could be
returned, changing the refusal to `.noRecipient`. Queue deadline and request lifetime now share
one candidate timestamp, while status under authority and final enqueue retain their independent
expiry checks. Expiry after the ready snapshot remains non-retryable `.publicationFailed`.
See the first slice's full-suite host-gate section for the complete cause and privacy correction.

The rebase conflict was confined to that candidate's timestamp sampling; retaining the corrected
sampling leaves the production tree identical to supplied second-slice head
`d0711b9d36741a39483803291a41ad710f98d074` apart from this expiry fix. The privacy classification
helper already existed on that head and now comes from the corrected parent instead. No other
production behavior is changed by this repair.

Each build/test phase runs the required host-slot gate and then voice-quiet gate, exports
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, and uses external scratch for temporary
configuration and caches. The full unfiltered Swift phase has a 45-minute work-command deadline.
Commands match the first slice's host-gate section:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
taskpolicy -b swift build --build-tests -j 2
taskpolicy -b swift test --no-parallel --skip-build \
  --filter 'CorrelatedReplyPublicationTests|AmbientPrivacyReplyRaceTests'
taskpolicy -b swift test --no-parallel --skip-build
# Working directory: Tests/ReplyCLITests
taskpolicy -b python3 -m unittest discover -s .
# Working directory: worktree root; PATH includes the isolated scratch mktemp shim.
taskpolicy -b bash scripts/tests/test-host.sh
```

These are local synthetic checks only. No push, PR action, live configuration, installation,
daemon restart, simulator/device build or physical validation is included. Fresh independent
exact-head review remains pending.


The rebased build passed in **445.46 s** Swift / **450.755 s** work
(`gatefix-pr2-build.log`). The unchanged affected suites passed **13 tests in 2 suites** in
**5.059 s** test / **12.872 s** work (`gatefix-pr2-focused.log`). Strict uncached lint of all
**26 Swift files changed across the stack** passed with zero violations
(`gatefix-pr2-all-lint.log`). The checker's exact exclusions and rename handling still count
**3 production files, zero renames**, relative to corrected PR 1 (`gatefix-pr2-scope.json`).


The corrected second-slice full unfiltered run passed **4,246 tests in 891 suites**, with
**13 expected known issues and zero unexpected failures**, in **1,946.087 s** test /
**1,953.070 s** work (`gatefix-pr2-full.log`). The known issues match the first slice:
`LocalDispatchPreflightWaitTests` (5), `RecipientPublicationGateTests` (3), and
`ReplyRecipientHandoffWaitTests` (5), each deliberately matched by existing test expectations.
No new known-issue annotation was added. Both original regression tests pass in the full run.
The HailCore AudioInput load flake did not occur, and no additional failure needed a main A/B
exemption. These results supersede the older filtered selections as full-suite evidence for
the repaired stack; those earlier records remain historical evidence for their respective heads.


The full Reply CLI suite passed **174 tests** in **452.145 s** test / **455.428 s** work
(`gatefix-pr2-cli.log`), with no failures.

The unchanged isolated host harness returned **`test-host: OK`**, exit 0, in **137.404 s**
(`gatefix-pr2-host.log`). All requested host-gate verification phases completed successfully on
both branches. No unexpected Swift, CLI or host-harness failure remains. Final history contains
one amended first-slice commit on pinned main and one rebased/amended second-slice commit on that
parent, with both original commit messages retained. Scripts remain identical to pinned main;
HailCore and app source are unchanged. No absolute home-directory or private host-tool paths are
added. Only this testing record changes after the second-slice verification; tested production
and test source bytes are retained. No independent exact-head approval is claimed.

## CI-only harness correction and stack rebuild (2026-11-19)

Part of #1246. Rebuild the original single second-branch commit
`f25f35d0de7f230e36b71ac9c383c18df46113c1` on amended first-branch head
`0f4333a0a6607c5fa5a13c6a6099192753da3771`, preserving its commit message and all production content.
The first-branch record documents the production lock trace and reproduces both original semaphore timeouts
under the full CI non-core parallel selection. It also records the unrelated full-suite and parallel-lane
failures encountered during that verification; those results remain failed.

The inherited `ReplyQueueStopAcceptanceTests` and `ReplyQueueStopCoverageTests` accept Stop synchronously
inside the enqueue callback before final `commit`, preserving accepted-Stop/refused-commit/zero-submission
assertions. No asynchronous production API or extra production test hook is introduced.

The audit covered all five second-branch test files changed against its parent:

- `ReplyPrivacyStopScopeTests`: use a continuation notification for entry into the held privacy decision,
  replacing polling of `hold.entered`.
- `ReplyPublicationControlBarrierTests`: await a continuation notification for the publication barrier.
  Early completion also wakes the observer, which retains its assertion that publication has not completed.
- `ReplyQueueStopAcceptanceTests`: retain the inherited deterministic Stop fix and the original second-branch
  asynchronous later-text publication/wire-order assertions.
- `ReplyStopControlOrderTests`: replace waiting/completion polling with continuation notifications, including
  peer retirement and cancellation completing before Stop is released. Early publication completion wakes
  the observer and still fails the unchanged premature-completion assertion.
- `ReviewRound6RequestlessOrderProbes`: the same continuation notification replaces barrier polling. The
  held-Stop setup is factored into a private helper to keep the test body within the existing lint limit.

No audited file retains a `DispatchSemaphore` or GCD-worker handshake. The remaining privacy subprocess/log
readiness checks use the existing suspending `eventually` helper; they do not block Swift cooperative workers.
Strict SwiftLint on all six affected/inherited Swift test files passed with zero violations.

Production files are byte-identical to the original second-branch commit. The checker's exact exclusions
and rename handling still count **3/4 production files**, zero renames, against the amended first branch.
Scripts and workflows remain identical to the supplied main. All verification is local and synthetic;
new independent exact-head review remains pending. No push, PR update, live configuration, installation,
daemon restart, simulator/device build, or physical playback proof is claimed.

### Rebuilt-branch verification

Every build/test phase ran the external host-slot gate, then the full voice-quiet gate. All work commands
used `taskpolicy -b`, the selected Xcode developer directory, and scratch temporary/module/package caches.
Builds used two jobs. With `$PR2_SUITES` equal to:

```text
(ReplyPrivacyStopScopeTests|ReplyPublicationControlBarrierTests|ReplyQueueStopAcceptanceTests|ReplyQueueStopCoverageTests|ReplyStopControlOrderTests|ReviewRound6RequestlessOrderProbes)
```

the work commands were:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
taskpolicy -b swift build --build-tests -j 2 --cache-path "$SCRATCH/ci-fix/swift-cache" -Xswiftc -warnings-as-errors
# Repeated 20 times in one gated phase:
taskpolicy -b swift test --skip-build --parallel --cache-path "$SCRATCH/ci-fix/swift-cache" --filter "$PR2_SUITES"
taskpolicy -b swift test --no-parallel --skip-build --cache-path "$SCRATCH/ci-fix/swift-cache"
```

| Verification | Result | Work-command time | Evidence in scratch `ci-fix` |
| --- | --- | --- | --- |
| Warnings-as-errors test build | exit 0 | 441.036 s | `pr2-build.log` |
| Added/affected suites under parallel scheduling | **20/20 passed**, 15 tests in six suites each, no known or unexpected issues | 93.713 s total | `pr2-added-20.log`, `pr2-added-run-01.log` through `pr2-added-run-20.log` |
| Full serial suite, one invocation | **exit 0**, 4246 tests in 891 suites passed, 13 expected known issues | 1913.601 s (1910.230 s test time) | `pr2-full.log` |
| Strict SwiftLint on all six affected/inherited test files | exit 0, zero violations | — | local command output |

All nine Swift files captured in `pr2-tested-digests.json` (three production files and six affected/inherited
test files) match their pre-build SHA-256 digests after verification. Production still matches the original
`f25f35d0de7f230e36b71ac9c383c18df46113c1` byte for byte. No mutation remains. Only the evidence record changed
after these tests. The final checker count is **3/4**, zero renames, relative to the amended first branch.

The parent record retains its failed first-branch full run, passing isolated audio-input recheck, failed
CI-style parallel lane with passing corrected Stop probes, and passing separately completed serial timing
lane. The one `scripts/verify.sh test` attempt remains failed; this second-branch serial pass is a separate
result. The loaded semaphore mutation reproduced both reported CI Stop failures before restoring the fixes.
