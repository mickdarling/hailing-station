# New owner requests preserve the playing reply (#1246)

Local implementation and synthetic verification only. No installation, daemon restart, simulator/device build,
TestFlight delivery, physical playback, or live captured-output round trip is claimed.

## Behavior and configuration

A newly admitted phone or ambient owner request leaves an in-flight segmented reply flowing to its terminal.
Its reply text may arrive while the first is playing. Queue-aware detached CLI jobs retain the existing shared
`reply-audio.lock` until the whole reply ends, and no longer write a same-target supersession stop file while
waiting for that lock. FIFO ticket admission orders producers before the device's existing playout queue. Legacy pre-queue daemons retain
the unticketed CLI supersession compatibility path.

The optional `host.json` compatibility switch was dropped from this PR in round 2 to free the fourth production
slot for request/job lifecycle fixes in `HostReplyDelivery.swift`. `scripts/host.sh` and its test harness are
identical to `origin/main`; no environment read or owner-request backstop remains. The switch may return as a
follow-up if the owner wants it. `didNoteLastInput` retains the interaction event. Explicit stops, addressed
dismissals and device `reply_yield` retain their paths; stops now also retract pre-audio request authority.

The earlier implementation/review history follows; round 2 supersedes its compatibility-switch and orphan
cleanup claims. Executed round 2 validation is recorded at the end.

The only GitHub calls were the three requested issue reads. #1246 is open with `type:feature`; #932 was read.
`gh issue view 954 -R mickdarling/hailing-station` could not resolve that number as an issue. The local
`reply-segments-listener.md` fix-round record supplies the #954 historical evidence; no additional lookup ran.
The #1222 queue changes were read from local commit `c53c715a7fc2d0aa6b117e19dfe75893762b3568`,
`docs/reply-protocol.md`'s queued audio section and `docs/testing/1212-local-voice-stop.md`.

## #1241 terminal-on-stop remainder

At base `3c6fb4ce62bf52921cd026918620e6357d4a204e`, an explicit host stop sends a `stop_playback` control
promptly, **not an audio terminal frame**:

- `HostReplyDelivery.swift:1040` captures the in-flight ids, records them as stopped and clears the flight/segment
  lists; line 1049 returns only `stopPlayback`.
- `WebSocketListener.swift:610` obtains that result, records its stopped ids at line 611, and sends the stop
  control at lines 615–616, before queued-target resolution at line 625. `sendPlaybackStop` sends only that frame
  at line 631.
- `HostReplyDelivery.swift:1315` refuses any subsequently published frame for a stopped reply as `replyStopped`,
  including the producer's ordinary final marker. `ReplyCommand.swift:402` attempts normal terminal recovery;
  `sendFinalPCM` at line 609 constructs the ordinary final marker, which cannot bypass that stop ledger.
- The device handles `stopPlayback` in `ReplyPlaybackController+Stop.swift:7` and retires its stream locally at
  lines 30–44. Thus explicit stop control can end playback promptly without an audio terminal; the backstop
  historically sent neither that control nor a terminal.

A proper terminal-on-stop change needs retained stream descriptor/sequence state and a narrowly scoped send
that cannot resurrect stopped audio, plus explicit-stop routing coverage. That would touch at least
`HostReplyDelivery.swift` and `WebSocketListener.swift` in addition to this slice's four production files.
It is deferred as a separate #1241 slice. The new explicit-stop regression asserts the actual current contract:
wire `stop_playback` immediately, then terminal publication refused and no extra frame at a socket barrier.
`reply_yield` remains unchanged: the device has already stopped locally and no host stop frame is sent.

## Acceptance coverage

| Expectation | Synthetic evidence |
| --- | --- |
| Phone/ambient owner admission preserves first stream through terminal; second audio follows, text may arrive early; interaction event retained | `ReplyNewRequestQueueTests.admittedOwnerRequestPreservesSegmentedStreamThroughTerminal` |
| Real queued producer sends every byte of both segments before next request-bound reply audio, with contiguous sequences and both terminals | `test_reply_new_request_queue.ReplyNewRequestQueueTests.test_same_target_request_waits_for_every_segment_and_terminal` |
| Explicit stop still immediately sends control and stops publication, including terminal | `ReplyNewRequestQueueTests.explicitStopStillCutsSegmentedPlaybackImmediately`, existing `ReplyQueuedAudioImmediateStopTests`, `HostPlaybackStopTests`, `DeviceVoiceStop*` |
| Owner-request backstop removed for phone/ambient, held/refused/complete and legacy handoffs; observers still run after commit gates | `ReplySegmentsBackstopTests`, `FinalDeliveryCommitTests.lastInputObserversRunAfterCommitGatesRelease` |
| Device yield remains scoped, idempotent and stops publication without host stop control | unchanged `ReplySegmentsListenerTests.yieldIsScopedIdempotentAndStopsPublicationWithoutAStopFrame` |
| Existing host script unchanged against base | `scripts/tests/test-host.sh` with fake launchctl/binaries and scratch host config |
| Legacy CLI supersession remains covered | existing `test_reply_cli` and `test_reply_segments` supersession tests explicitly simulate a pre-queue daemon |

## Scope

Four production files under the exact `scripts/pr-shape.py` exclusions; no renames:

- `Sources/HailDaemonKit/Listener/HostSession.swift`
- `Sources/HailDaemonKit/Listener/HostSession+Routing.swift`
- `Sources/haild/ReplyCommand.swift`
- `Sources/HailDaemonKit/Listener/HostReplyDelivery.swift`

Test/support files (excluded from the production count):

- `Tests/HailDaemonKitTests/ReplyNewRequestQueueTests.swift`
- `Tests/HailDaemonKitTests/ReplyQueueAuthorityTests.swift`
- `Tests/HailDaemonKitTests/ReplyQueueLifecycleTests.swift`
- `Tests/HailDaemonKitTests/ReplyQueuedAudioRoutingTests.swift`
- `Tests/HailDaemonKitTests/ReplySegmentsBackstopTests.swift`
- `Tests/HailDaemonKitTests/ReplySegmentsListenerTestSupport.swift`
- `Tests/HailDaemonKitTests/FinalDeliveryCommitTests.swift`
- `Tests/ReplyCLITests/test_reply_new_request_queue.py`
- `Tests/ReplyCLITests/test_queued_reply_stop.py`
- `Tests/ReplyCLITests/test_reply_ticket_release.py`
- `Tests/ReplyCLITests/test_reply_cli.py`
- `Tests/ReplyCLITests/test_reply_segments.py`
- `scripts/tests/test-host.sh`

Documentation (also excluded): this record, `docs/reply-protocol.md`,
`docs/testing/reply-segments-host.md`, `docs/testing/reply-segments-listener.md`, and
`docs/testing/delivery-stage-order.md`.
Listener and script paths require `security:critical` for a future PR, plus actual independent exact-head review
and second-key evidence. No push, PR, online PR-shape run, CI result or independent review approval is claimed.
The final diff has no script changes against base.

## Earlier verification (before round 2)

In recorded commands, `$XCODE_DEVELOPER_DIR` denotes the selected full Xcode developer directory, and
`$SCRATCH` denotes the isolated scratch tree. Host-specific absolute tool and home paths are omitted.

Results and mutation commands are recorded after execution below. Each build/test phase runs
the host build-slot gate, then its voice-quiet gate (the host's build-slot and voice-quiet gate scripts).
Commands use `DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"`, background task policy, two package build
jobs (one compiler worker each for cached verification), serial tests and an 810-second work-command watchdog.
The wrapper rechecks the slot after the voice-quiet window, since another build can start during that window.
It tracks only the phase's child processes by ancestry and start time, including compiler children in separate
process groups; timeout cleanup never targets other host jobs. Scratch logs, temporary config and caches live in
a scratch directory, written `$SCRATCH` below; no generated product is committed.


The scratch-only full host-config harness passed (294.611 s):

```sh
taskpolicy -b bash scripts/tests/test-host.sh
```

It checks the new setting's absent/false/true environment bridge and invalid types, plus the existing complete
plist and lifecycle cases, using fake shell binaries, fake launchctl and a private scratch config/release tree.
It performs no live installation, restart or configuration change.

The initial bounded cold builds saved objects but restarted interrupted test-target batches. Verification then
switched to the repository's explicit-module/compiler-job-cache workflow, with indexing disabled and the cache
kept in scratch, so completed jobs can survive an interrupted build. The exact cached build command is:

```sh
taskpolicy -b swift build --build-tests -j 2 \
  --cache-path $SCRATCH/swift-cache \
  --disable-index-store -Xswiftc -j1 -Xswiftc -explicit-module-build \
  -Xswiftc -cache-compile-job -Xswiftc -cas-path \
  -Xswiftc $SCRATCH/cas -Xswiftc -Rcache-compile-job
```


## Round 1 findings: queue lifetime and FIFO

P1: the 40-second request data deadline used to keep running while a reply waited for the audio lock. A healthy
85-second earlier reply could therefore silently consume the next reply's entire audio opportunity. Ticketed
waiters now have a separate 45-minute monotonic queue lifetime (35-minute stream watchdog + maximum ten-minute
shared-rate extension), including rate-limit retries of queue checks. The stream watchdog and 40-second idle
budget restart after acquisition and a successful final daemon check. A local `HAILD_REPLY_QUEUE_SECONDS` value
can shorten, never lengthen, this bound. CLI exhaustion is `queue_timeout`, with no audio or renderer start;
it releases the reservation and writes a content-free unified log. Optional job-end `audioSkipReason` carries
the reason in synthetic socket tests; older endpoints ignore the optional field. It is not ticket `expired`.

The daemon owner reserves authority after accepted audio-bearing text, only until first audio or a fixed
45-minute deadline. Every 20 seconds it renews an existing, still-current committed pre-audio request under its
original policy/binding authority; it never inserts a missing record. Reservation heartbeats move the stream
clock anchors and an ended provider turn's grace anchor. They do not accept a frame or advance its sequence,
descriptor, pin or flight state. First audio ends renewal. The five-minute watchdog margin still accommodates
the CLI's full 30-minute maximum audio stream after its last heartbeat. Selection/privacy drops, stopped reply
IDs and expired authority cannot be restored. A queue stop is also enforced by the existing daemon ticket
cutoffs at check and first publication, including when a stop leaves request ownership intact. Full reservation
expiry logs `reply_queue_authority reason=queue_timeout request=<UUID>` and removes authority.

P2: the lowest live ticket in the daemon epoch must acquire the stream lock first. A short admission lock covers
ticket issuance/registration and acquisition, preventing a registration race as well as the polling race.
Owner-only `reply-audio.ticket-<epoch>-<position>` files carry held kernel locks. Later waiters remove dead,
unlocked earlier records on their next 250 ms admission pass. No PID reuse heuristic or process mutation is
involved. The stream lock still covers the entire segmented reply. Legacy `ticket == nil` supersession,
40-second deadline and unordered lock behavior remain on their existing compatibility path.

New synthetic coverage reuses `review_queue_probe.py`'s 85-second stream and held-lock release offsets:

- `test_85_second_first_reply_preserves_every_queued_frame`: both PCM payloads, sequences, terminals and order.
- `test_three_waiters_follow_ticket_order_in_repeated_poll_race`: three waiters, eight race repetitions.
- `test_killed_waiter_does_not_wedge_later_tickets`: kill only the first owned waiter, later audio starts within
  two seconds of release, dead/live records cleaned.
- `test_queue_lifetime_has_an_honest_timeout_reason_and_no_audio`: shortened one-second bound, diagnostic reason.
- `test_explicit_stop_while_waiting_skips_before_turn_release`: stop recognized while lock remains held; no audio.
- `test_legacy_unticketed_wait_retains_40_second_request_deadline`: a shortened ticketed queue setting does not
  change the unticketed path's real 40-second deadline or create FIFO records.
- `ReplyQueueAuthorityTests`: injected clock through 43m20s of waiting followed by a full 30-minute stream;
  fixed reservation timeout; privacy, selection, policy, dismissal and already-expired authority; actual daemon
  queue stop cannot be undone by renewal.

The device-side paused-reply supersede (#321) and #1241 terminal-on-stop remainder remain outside this revision.
Only local source/tests/docs and a new local commit are in scope. Round 1 remains REQUEST CHANGES until a fresh
independent review of the resulting head; no independent approval, push, PR, install or physical proof is claimed.

This revision also updates `test_queued_reply_stop.py` to allow nonpublishing probes before acquisition while
requiring the turn lock on every publication (and uncontended admission). Early stopped/stale probes can exit
before waiter readiness. The retry test checks both the preflight and final admission with the same ticket.
`test_reply_ticket_release.py` now forces a one-second queue timeout and verifies its reason and release rather
than expecting a ticketed wait to abandon audio after 40 seconds. These are test contract updates for the
requested behavior; the legacy deadline has its own retained coverage above.

Execution results are appended below after the checks run.

### Executed validation for the round 1 fixes

All work commands use `DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"`. Before every build/test phase,
the host build-slot gate then its voice-quiet gate ran. The scratch
`phase.py` wrapper rechecks the slot after quiet, backgrounds Swift work, and bounds each work command to 810 s.
Config, temporary renderer outputs, module/package caches and logs are under `hs-1246-scratch`.

```sh
export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"

taskpolicy -b swift build --build-tests -j 2 \
  --cache-path $SCRATCH/swift-cache

taskpolicy -b swift test --no-parallel --skip-build \
  --filter '(Reply(NewRequestQueue|QueueAuthority|QueuedAudio|Segments|PlaybackRecipient|Recipient|StreamPacer)|RequestStreamLifetime|ProviderTurnRequestLifetime|LateAnswer|FinalDelivery|HostPlaybackStop|DeviceVoiceStop)' \
  --cache-path $SCRATCH/swift-cache

# Working directory: Tests/ReplyCLITests
python3 -m unittest discover -s .
```

- The full build passed in 547.012 s; the final build after the admission/expiry rechecks passed in 40.132 s
  (`review1-build-fixed.log`, `review1-build-final.log`). An initial telemetry scope compile error was corrected.
- Swift: **234 tests in 58 suites passed**, work command 136.527 s (`review1-swift.log`). Its five known issues
  are deliberately matched `withKnownIssue` timeout/cancellation diagnostics in `ReplyRecipientHandoffWaitTests`,
  not unexpected failures or claims that a failure is pre-existing.
- CLI: **170 tests passed**, 373.716 s test time / 376.448 s work command (`review1-cli-full-updated.log`).
  The first full run exposed four old waiter-readiness/check-count assertions and one old 40-second-abandonment
  expectation. The new queue regressions passed in that run. The contracts were updated as described above,
  then the complete suite was rerun. No failure was attributed to `origin/main` or excused as pre-existing.
- Host strict lint passed with zero violations for every Swift file changed against `origin/main`, including
  the new authority suite. Exact invocation:

```sh
swiftlint lint --strict \
  Sources/HailDaemonKit/Listener/HostSession+Routing.swift \
  Sources/HailDaemonKit/Listener/HostSession.swift Sources/haild/ReplyCommand.swift \
  Tests/HailDaemonKitTests/FinalDeliveryCommitTests.swift \
  Tests/HailDaemonKitTests/ReplyNewRequestQueueTests.swift \
  Tests/HailDaemonKitTests/ReplyQueueAuthorityTests.swift \
  Tests/HailDaemonKitTests/ReplySegmentsBackstopTests.swift \
  Tests/HailDaemonKitTests/ReplySegmentsListenerTestSupport.swift
```

The round 1 fix session made one direct REST read of issue #1246 (open, `type:feature`); no GitHub searches,
CI watches, PR writes, pushes, live configuration changes, installation or daemon restart occurred.

### Required fault mutations

The scratch runner `review1-mutations.py` saves `ReplyCommand.swift`, applies each fault separately, runs the
same gated build command above and the exact test command below, and restores the saved source in `finally`.
It then rebuilds the restored source and runs the complete queue module. The source was compared byte for byte
with that saved version after both faults were removed.

1. Restore the old request deadline inside `waitForAudioTurn`, immediately before `legacyAudioWait`:

   ```swift
   if let latest = RequestKeepAlive.latest(final: false), ContinuousClock.now >= latest {
       throw ReplyCommandError.invalid("another reply is still playing; this reply's audio was skipped")
   }
   ```

   ```sh
   # Working directory: Tests/ReplyCLITests
   python3 -m unittest -v test_reply_new_request_queue.ReplyNewRequestQueueTests.test_85_second_first_reply_preserves_every_queued_frame
   ```

   Build passed (34.874 s work command); the test **failed as required**, exit 1, 81.125 s test time /
   83.902 s work command. Its assertion saw only the first request in audio order: the queued request published
   no audio. This was the intended regression, not a timeout or unrelated test error
   (`review1-mutation-deadline-build.log`, `review1-mutation-deadline-test.log`).

2. Revert admission to unordered polling by changing only the lowest-live-ticket guard in `takeAudioTurn`:

   ```swift
   // Fixed:
   guard try isFirstLiveWaiter(ticket, directory: directory) else { return false }
   // Mutation (mutual exclusion stays; ordering is ignored):
   _ = try isFirstLiveWaiter(ticket, directory: directory)
   ```

   ```sh
   # Working directory: Tests/ReplyCLITests
   python3 -m unittest -v test_reply_new_request_queue.ReplyNewRequestQueueTests.test_three_waiters_follow_ticket_order_in_repeated_poll_race
   ```

   Build passed (32.743 s work command); **all eight race repetitions failed as required** with later requests
   overtaking earlier ones, exit 1, 5.544 s test time / 8.478 s work command
   (`review1-mutation-fifo-build.log`, `review1-mutation-fifo-test.log`).

Restored verification uses the same gated build, followed from `Tests/ReplyCLITests` by:

```sh
python3 -m unittest -v test_reply_new_request_queue
```

The restored build passed in **33.759 s** (`review1-restored-build.log`). All **7 queue tests passed** in
146.889 s test time / 150.128 s work command (`review1-restored-queue.log`), including the 85-second reply,
all eight FIFO repetitions, killed waiter, queue timeout, explicit queued stop, legacy deadline and segmented
terminal ordering. Both mutation faults were removed and the final source matched the saved fixed version
byte for byte. Strict lint was rerun on all eight changed Swift files after restoration: zero violations.

Final staged scope against base `38c62e4f9f457ac9212578253d8a898a9a4c81c5` is **4/4 production files**, with
no renames, using the exact checker exclusions and rename handling. This fix commit changes three of those
production files; `scripts/host.sh` remains solely the original configuration bridge from the preceding commit.
Tests/docs are excluded as specified by the checker. No generated build product is staged. This was the round 1
scope; round 2 replaces the script slot with `HostReplyDelivery.swift`.

## Round 2: authority retraction, admission deadline and historical waiter cleanup

The review probes in `hs-1246-review1` reproduced three defects at
`e1a2ba2ad06c159a9b2a2bcdf80b0684799d1c99`. Their Swift lifecycle scenarios are committed as
`ReplyQueueLifecycleTests`; the ten historical waiter records scenario is committed in
`test_reply_new_request_queue.py`. These are synthetic local socket/PCM and injected-clock checks.

- **P1:** `HostReplyDelivery.swift` binds accepted ticketed text to the exact issued queue job. Its capability
  checks job existence/expiry, connection liveness and connection/target stop cutoffs. `HostSession+Routing.swift`
  renews only ticketed reservations with that capability, under the original request authority gates; unticketed
  text cannot acquire a heartbeat. Release (including job-end/timeout cleanup), job retirement, connection loss,
  stop, privacy and lost authority end renewal. An empty reservation set cancels its heartbeat task. Explicit
  playback stop retracts pending and in-flight request records immediately, including pre-audio records absent
  from `repliesInFlight`, and clears handoff restoration records. Addressed per-reply stops retract the matching
  request too. Ticketed and unticketed publication of the stopped request are both refused.
- **P2a:** `HostReplyDelivery.swift` checks the fixed reservation deadline during candidate admission and again
  inside the final publication gates. First audio at 45 minutes + 1 ms cannot slip between heartbeat sweeps.
- **P2b:** `ReplyCommand.swift` inspects waiter locks across every epoch under the registration/admission lock.
  Unlocked records are collected regardless of epoch or position. Locked historical records survive and only
  earlier live records in the current epoch block FIFO admission. A lazy, nonrecursive scan inspects at most
  4096 entries per pass; reaching the bound defers admission while subsequent passes collect remaining orphans.
  Registration holds the same lock across file creation and record locking, preventing cleanup of a live waiter
  racing registration. No PID probe or mutation is involved.

The optional `replyNewRequestStopsPlaying` switch and owner-request segmented backstop were dropped from this
PR at the owner's direction. The switch may return in a follow-up if wanted. Both host scripts match
`origin/main` byte for byte. A new request never stops the playing reply; the interaction event, explicit stop,
dismissal and `reply_yield` paths remain. The old backstop tests now assert continued publication and no backstop
log for phone/ambient, legacy, held/refused and completed handoffs. `FinalDeliveryCommitTests` still verifies that
observers run after commit gates release. The #1241 audio-terminal-on-stop remainder remains deferred.

Additional lifecycle regressions cover immediate pre-audio retraction with and without queued-stop marking,
200 seconds of attempted renewal, ticketed and unticketed refusal, release, job finish, disconnect, privacy,
dismissal and the absence of unticketed heartbeats. Existing authority tests now reserve actual synthetic queue
jobs. CLI coverage checks all ten historical orphans are collected, a locked historical waiter survives until
unlock, and 4200 orphans make progress across multiple bounded passes.

All build/test work uses the existing scratch `phase.py` runner: before **each** command it runs
the host build-slot gate, then its voice-quiet gate, rechecks the slot,
exports `DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"`, and bounds the work command to 810 seconds.
Caches, logs and temporary config stay under `hs-1246-scratch`. The unchanged host harness gets a scratch-only
`mktemp` PATH wrapper that redirects its temporary harness allocation into that same scratch tree; fake launchctl
and fake binaries keep it isolated from live services. No live configuration, install, restart, push or PR is in
scope. One REST read confirmed #1246 remains open with `type:feature`; no GitHub search or CI watch ran.

The first broad Swift run found two assertions of the old retained-owner authority contract in
`ReplyQueuedAudioRoutingTests` and a real expiry-classification regression in the new capability check.
Owner-stop assertions now require absent authority; a stop on the other connection still preserves its request.
For the exact same ticket, final publication delegates job-state validation to the existing enqueue lock so it
retains `expired`/`stopped` skip classification, including expiry while routing is suspended. Unticketed audio or
a different ticket still checks the original job capability. The fixed reservation deadline is checked for all
publication paths. This correction preserves the existing `expiryKeepsCorrelatedTextAndRequest` regression;
no failure has been labelled pre-existing, and no A/B exemption is claimed.

### Executed round 2 commands and results

Each build/test command below has its own slot/quiet gates and 810-second work watchdog as described above.
The working directory is this worktree unless noted. Exact work commands:

```sh
export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"

taskpolicy -b swift build --build-tests -j 2 \
  --cache-path $SCRATCH/swift-cache

taskpolicy -b swift test --no-parallel --skip-build \
  --filter '(Reply(NewRequestQueue|QueueAuthority|QueueLifecycle|QueuedAudio|Segment|Playback(Recipient|Controller|Stop|Supersede)|Recipient|StreamPacer)|RequestStreamLifetime|ProviderTurnRequestLifetime|LateAnswer|FinalDelivery|HostPlaybackStop|DeviceVoiceStop|AmbientWiringDismiss)' \
  --cache-path $SCRATCH/swift-cache

# Working directory: Tests/ReplyCLITests
python3 -m unittest discover -s .

# Working directory: worktree root; mktemp wrapper only redirects harness scratch allocation.
PATH=$SCRATCH/host-bin:$PATH \
  taskpolicy -b bash scripts/tests/test-host.sh
```

- Build passed in **233.688 s** (`round2-build-fixed.log`), then **138.181 s** after the expiry-classification fix
  (`round2-build-classification.log`). The initial build caught two missing actor-isolation awaits in the new
  lifecycle test helper; it now uses the connection ID from the already captured request context. No build phase
  exceeded 810 seconds.
- Swift passed: **361 tests in 80 suites**, **140.720 s** test time / **151.578 s** work command
  (`round2-swift.log`). All three expiry-race cases and both stop-owner routing cases passed. The five known issues
  are deliberately matched `withKnownIssue` timeout/cancellation checks in `ReplyRecipientHandoffWaitTests`, not
  unexpected failures or a pre-existing-failure exemption. The first broad run's three unexpected issues and
  their corrections are described above (`round2-swift-initial.log`).
- Strict lint passed with **zero violations in all eleven changed Swift files** (`round2-lint.log`):

```sh
swiftlint lint --strict \
  Sources/HailDaemonKit/Listener/HostReplyDelivery.swift \
  Sources/HailDaemonKit/Listener/HostSession+Routing.swift \
  Sources/HailDaemonKit/Listener/HostSession.swift Sources/haild/ReplyCommand.swift \
  Tests/HailDaemonKitTests/FinalDeliveryCommitTests.swift \
  Tests/HailDaemonKitTests/ReplyNewRequestQueueTests.swift \
  Tests/HailDaemonKitTests/ReplyQueueAuthorityTests.swift \
  Tests/HailDaemonKitTests/ReplyQueueLifecycleTests.swift \
  Tests/HailDaemonKitTests/ReplyQueuedAudioRoutingTests.swift \
  Tests/HailDaemonKitTests/ReplySegmentsBackstopTests.swift \
  Tests/HailDaemonKitTests/ReplySegmentsListenerTestSupport.swift
```

- Full Reply CLI passed: **172 tests**, **375.824 s** test time / **378.283 s** work command (`round2-cli.log`).
  This includes the reviewer's ten previous-epoch orphans, a held historical record followed by unlock/collection,
  the 4200-orphan bounded-scan regression, the existing 85-second earlier reply, all eight FIFO races, killed
  waiter cleanup, explicit stop while queued, honest timeout/release, and the legacy 40-second deadline.
- The unchanged host harness passed: **`test-host: OK`**, **141.001 s** work command (`round2-host.log`), using the
  scratch-only allocation wrapper shown above. Both `scripts/host.sh` and `scripts/tests/test-host.sh` remain
  byte-identical to `origin/main`.

### Required round 2 fault mutations

The scratch runner `round2-mutations.py` saves the fixed files, applies each fault separately, runs a gated build
and gated targeted test, restores each file in `finally`, then rebuilds and retests the restored source. An
expected failure must have exit 1 and a real assertion diagnostic; a build error, empty selection or timeout does
not count. Fixed-source SHA-256 digests were also saved for all four production files before mutations.

1. **Skip authority retraction on stop:** replace only
   `replyRequests = replyRequests.filter { $0.value.audioFinished }` in `stopReplyPlayback` with a comment;
   keep ticket cutoff behavior and handoff-restoration clearing. Build: **passed, 36.902 s**
   (`round2-mutation-stop-build.log`). Exact test command:

   ```sh
   taskpolicy -b swift test --no-parallel --skip-build \
     --cache-path $SCRATCH/swift-cache \
     --filter 'ReplyQueueLifecycleTests.explicitStopMustEndPreAudioAuthority'
   ```

   **Failed as required**, exit 1: **seven assertion issues** across both stop variants, 0.080 s test time /
   **8.549 s** work command (`round2-mutation-stop-test.log`). Immediate request/deadline retraction failed for
   both variants; without queued-stop marking, the request also remained renewable and ticketed audio was
   accepted after 200 seconds. The voice gate took 600.131 s because it detected activity in four windows;
   the test work command itself remained under its bound. The fault was then restored.

2. **Drop the admission-time deadline check:** remove the fixed-deadline guard from
   `queueAuthorityIsCurrent`, leaving the periodic renewal sweep unchanged. Build: **passed, 35.990 s**
   (`round2-mutation-admission-build.log`). Exact test command:

   ```sh
   taskpolicy -b swift test --no-parallel --skip-build \
     --cache-path $SCRATCH/swift-cache \
     --filter 'ReplyQueueLifecycleTests.authorityDeadlineIsCheckedOnAudioAdmission'
   ```

   **Failed as required**, exit 1: first audio at **45 minutes + 1 ms** was accepted before the next sweep,
   producing the expected assertion failure; 0.031 s test time / **8.527 s** work command
   (`round2-mutation-admission-test.log`). The fault was then restored. Host-slot and voice waits were outside
   the bounded work commands; the build waited 495 seconds for the slot, and the test waited 270 seconds for
   its slot plus a voice window extended once by activity.

3. **Restore the epoch filter:** replace the all-epoch record-prefix guard in `isFirstLiveWaiter` with the
   current-epoch `prefix` guard, leaving lock probing and scan bounding intact. Build: **passed, 42.339 s**
   (`round2-mutation-epoch-build.log`). Exact test command, from `Tests/ReplyCLITests`:

   ```sh
   python3 -m unittest -v test_reply_new_request_queue.ReplyNewRequestQueueTests.test_dead_previous_epoch_records_are_collected
   ```

   **Failed as required**, exit 1: the result contained **ten extra historical records** after the completed job;
   0.383 s test time / **3.296 s** work command (`round2-mutation-epoch-test.log`). The fault was then restored.
   The build's voice gate took 1200.254 s due to repeated live activity; no build/test work ran during that wait.

All three faults have been removed. All four production files match the saved fixed-source SHA-256 digests
(`round2-restoration-digests.log`), and the mutation runner also compared both modified files byte for byte with
its saved originals before starting the restored build. Restored execution results follow below.

### Restored verification and final scope

The restored build uses the exact build command above and passed in **43.347 s**
(`round2-restored-build.log`). Its runner rechecked the slot after quiet, detected another build, and waited
again before doing work. The restored targeted commands are:

```sh
taskpolicy -b swift test --no-parallel --skip-build \
  --cache-path $SCRATCH/swift-cache \
  --filter '(ReplyQueueLifecycle|ReplyQueueAuthority|ReplySegmentsBackstop|ReplyNewRequestQueue|FinalDeliveryCommit|ReplyQueuedAudioRoundTwo|ReplyQueuedAudioRouting)'

# Working directory: Tests/ReplyCLITests
python3 -m unittest -v test_reply_new_request_queue
```

Final strict lint repeated the eleven-file command above after restoration: **zero violations**
(`round2-final-lint.log`). Working **and staged** production bytes match the saved pre-mutation digests.
`git diff --cached --check` passed. The staged diff against base
`38c62e4f9f457ac9212578253d8a898a9a4c81c5` uses the exact checker's prefix/suffix exclusions and counts both
names for any rename: **4/4 production files, zero renames** (`round2-production-count.log`):

- `Sources/HailDaemonKit/Listener/HostSession.swift`
- `Sources/HailDaemonKit/Listener/HostSession+Routing.swift`
- `Sources/HailDaemonKit/Listener/HostReplyDelivery.swift`
- `Sources/haild/ReplyCommand.swift`

Both staged host scripts are byte-identical to `origin/main`; the local fix includes their reversions, and
neither contributes a production file to the complete diff against base. No generated build products are staged.
The supplied round 2 verdict was REQUEST CHANGES on the previous head. These local fixes and tests do not
constitute fresh independent approval; exact-head review remains required before any future merge. No push,
PR, online PR-shape/CI result, live configuration change, installation, daemon restart, simulator/device build
or physical playback proof is claimed.

- Restored Swift selection passed: **28 tests in 7 suites**, **1.682 s** test time / **11.747 s** work command
  (`round2-restored-swift.log`). This includes every new lifecycle regression, queue authority, owner-request
  backstop removal, commit observers, expiry classification during routing and stop-owner authority handling.
- Restored CLI queue module passed: **9 tests**, **147.818 s** test time / **150.570 s** work command
  (`round2-restored-cli.log`), including both new cleanup regressions, the full long/segmented reply, all eight FIFO
  races, killed waiter cleanup, explicit stop, honest timeout and legacy deadline. The mutation driver completed
  successfully after restoring every fault. No unexpected test failure remains.

## Round 3: atomic reservation commit and acceptance-scoped stop

The supplied round 3 review reported REQUEST CHANGES at
`70864e16bb4793ac2625ea12f2bff4db47e6a96c`. Its probes and
`hs-1246-review1/review-round3-swift.log` were read before implementation. The probe suite is committed as
`ReplyQueueStopAcceptanceTests`, including the exact 45-minute boundary cases. These fixes and local tests
are not a new independent review or approval.

- **P1:** `ReplyAudioQueue.Reservation.performIfCurrent` holds the queue mutex across validation of the original
  reservation and the synchronous transport enqueue. `HostSession.commitQueuedReply` uses it for unticketed
  publication after the policy/binding gates. A stop accepted before this commit wins; a stop arriving while
  the commit holds the mutex is accepted after that commit. Same-ticket publication retains the existing queue
  enqueue boundary and precise skip classification. A different ticket cannot replace a request's bound ticket.
  The enqueue callback receives a synchronous `commit` gate and uses it around the final submission after taking
  the privacy hold, retaining the existing privacy → queue → transport lock order. The copied probe holds a
  synchronous gate inside the enqueue callback, after the preliminary reservation check and before the final mutex,
  accepts stop on a second OS thread, then releases submission. It asserts both refusal and zero transport
  submissions. The hold precedes the callback's `commit` call, so stop acceptance never waits on a mutex held
  by the probe. No sleeps choose the race ordering; the gates do. An initial wrapper-around-enqueue version built
  successfully but was revised before tests because it inverted privacy/queue lock order; its waiting test driver
  was stopped before test work began. Only processes started by this session were signalled. The callback
  refinement's first build then caught nonescaping parameters captured by stored local closures; synchronous
  local functions corrected those compile errors. No failure was labelled pre-existing and no A/B exemption
  is claimed.
- **P2:** Stop acceptance snapshots a process-local monotonic request-admission cutoff under the queue lock,
  alongside its existing ticket cutoff. Request minting advances that order synchronously, without an actor hop;
  it is independent of injected lifetime clocks and ticket issuance. Applying a delayed stop removes only
  unfinished request records at or below the captured request cutoff. Handoff restoration records respect the
  same cutoff. Later request descriptors and queue tickets also preserve their in-flight ids, so the stopped-id
  ledger cannot revoke them indirectly. The copied held-session-hop probe covers both pre-audio and already
  streaming later replies, plus a later request with no ticket or descriptor. It checks old authority is removed,
  later authority survives, the later ticket is admissible, and unticketed continuation still publishes.
- **P3:** The reply-segments overview no longer promises an optional backstop. The unused `segmentedReplies`
  set, all writes and marker-only assertions/fixtures are removed. Tests still exercise the read `repliesInFlight`
  ledger's bound, final-audio retirement, yield, explicit stop and owner-request preservation. The teardown method
  remains a no-op compatibility callback because its existing caller is in `WebSocketPeer.swift`, outside this
  slice's four production files; it stores or clears no segment bookkeeping. Current segment-test documentation
  now describes the in-flight ledger instead.

The issue's optional-setting acceptance and #1241 terminal-frame remainder remain deferred as documented above.
No installed build, physical playback, or live captured-output round trip is claimed. Both host scripts remain
byte-identical to base `38c62e4f9f457ac9212578253d8a898a9a4c81c5` / `origin/main`.

### Round 3 verification

Every build/test work command below runs through scratch `phase.py`: the host build-slot gate then its voice-quiet gate,
with a fresh slot check after quiet, `DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"`, and an
810-second work watchdog. Logs, caches, temporary configuration and the unchanged harness's `mktemp` wrapper
stay under `$SCRATCH`. These are local synthetic Swift/socket/PCM and CLI
checks. One REST issue read confirmed #1246 is open and labelled `type:feature`; no search, CI watch or PR write ran.

Exact work commands (each build/test invocation has its own gates and watchdog):

```sh
export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"

taskpolicy -b swift build --build-tests -j 2 \
  --cache-path $SCRATCH/swift-cache

taskpolicy -b swift test --no-parallel --skip-build \
  --cache-path $SCRATCH/swift-cache \
  --filter '(Reply(NewRequestQueue|QueueAuthority|QueueLifecycle|QueueStopAcceptance|QueuedAudio|Segment|Playback(Recipient|Controller|Stop|Supersede)|Recipient|StreamPacer)|RequestStreamLifetime|ProviderTurnRequestLifetime|LateAnswer|FinalDelivery|DeliveryStageOrder|RecipientPublicationGate|HostPlaybackStop|DeviceVoiceStop|AmbientWiringDismiss)'

# Working directory: Tests/ReplyCLITests
python3 -m unittest discover -s .

# Working directory: worktree root; scratch-only mktemp wrapper, fake launchctl/binaries.
env PATH="$SCRATCH/host-bin:$PATH" \
  taskpolicy -b bash scripts/tests/test-host.sh
```

The deterministic fault checks each use the same build command, then respectively:

```sh
taskpolicy -b swift test --no-parallel --skip-build \
  --cache-path $SCRATCH/swift-cache \
  --filter 'ReplyQueueStopAcceptanceTests.unticketedFinalEnqueueMustOrderWithStopAcceptance'

taskpolicy -b swift test --no-parallel --skip-build \
  --cache-path $SCRATCH/swift-cache \
  --filter 'ReplyQueueStopAcceptanceTests.acceptedStopMustNotRetractLaterRequest'
```

The scratch driver `round3-verify.py` saves the fixed source and all four production SHA-256 digests, applies
one fault at a time, and restores source in `finally`. A mutation counts only with a successful build, test exit 1,
and the intended assertion diagnostic; an empty selection, compile error or timeout is not evidence.

1. Split the original reservation check from commit again: replace only
   `return authority.performIfCurrent { send(enqueue) }` with `return send(enqueue)`.
   The preliminary `queueAuthorityIsCurrent` checks remain before the held enqueue gate.
2. Ignore acceptance cutoff during retraction: replace only
   `replyRequests = replyRequests.filter { $0.value.audioFinished || $0.value.admissionPosition > cutoff }`
   with `replyRequests = replyRequests.filter { $0.value.audioFinished }`.

After removing both faults and verifying all four digests, the restored build uses the same build command and:

```sh
taskpolicy -b swift test --no-parallel --skip-build \
  --cache-path $SCRATCH/swift-cache \
  --filter '(ReplyQueueStopAcceptance|ReplyQueueLifecycle|ReplyQueueAuthority|ReplySegmentsBackstop|ReplyNewRequestQueue|FinalDeliveryCommit|ReplyQueuedAudioRoundTwo|ReplyQueuedAudioRouting)'
```

Executed fixed-source results:

- Final implementation build: **passed**, **381.28 s** Swift build time / **385.382 s** work command
  (`round3-build-final.log`). The earlier wrapper version's build passed in 272.455 s; the intermediate callback
  refinement build failed in 11.677 s on the nonescaping-closure errors described above and was corrected.
- Broad Swift selection: **367 tests in 82 suites passed**, **137.744 s** test time / **146.072 s** work command
  (`round3-swift.log`). The eight known issues are deliberately matched timeout/cancellation diagnostics in
  `RecipientPublicationGateTests` and `ReplyRecipientHandoffWaitTests`; there are zero unexpected failures and
  no pre-existing-failure exemption. Both race regressions passed, including both later-stream states and all
  three exact-deadline cases (`ReplyQueueStopAcceptanceTests`: 0.037 s).
- Strict lint on **all 18 Swift files changed against origin/main** passed with zero violations
  (`round3-lint.log`), using `DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"` and the command below.

```sh
swiftlint lint --strict \
  Sources/HailDaemonKit/Listener/HostReplyDelivery.swift \
  Sources/HailDaemonKit/Listener/HostSession+Routing.swift \
  Sources/HailDaemonKit/Listener/HostSession.swift \
  Sources/haild/ReplyCommand.swift \
  Tests/HailDaemonKitTests/DeliveryStageOrderTestSupport.swift \
  Tests/HailDaemonKitTests/FinalDeliveryCommitTests.swift \
  Tests/HailDaemonKitTests/RecipientPublicationGateTests.swift \
  Tests/HailDaemonKitTests/ReplyNewRequestQueueTests.swift \
  Tests/HailDaemonKitTests/ReplyQueueAuthorityTests.swift \
  Tests/HailDaemonKitTests/ReplyQueueLifecycleTests.swift \
  Tests/HailDaemonKitTests/ReplyQueueStopAcceptanceTests.swift \
  Tests/HailDaemonKitTests/ReplyQueuedAudioRoutingTests.swift \
  Tests/HailDaemonKitTests/ReplyRecipientAuthorityRaceTests.swift \
  Tests/HailDaemonKitTests/ReplyRecipientTestSupport.swift \
  Tests/HailDaemonKitTests/ReplySegmentsBackstopTests.swift \
  Tests/HailDaemonKitTests/ReplySegmentsHostSessionTests.swift \
  Tests/HailDaemonKitTests/ReplySegmentsListenerTestSupport.swift \
  Tests/HailDaemonKitTests/ReplySegmentsListenerTests.swift
```

- Full Reply CLI suite: **172 tests passed**, **376.275 s** test time / **379.067 s** work command
  (`round3-cli.log`). This includes the long earlier reply, FIFO races, dead waiters, historical-orphan cleanup,
  timeout/release, explicit queued stop and the legacy deadline. No unexpected test failure occurred.

- Unchanged host harness: **`test-host: OK`**, **196.324 s** work command (`round3-host.log`). Its quiet gate
  waited **1200.221 s** because of repeated voice activity; no harness work ran during that wait. Fake service
  tools and the scratch-only allocation wrapper kept this isolated from live configuration and services.

Mutation execution results:

- **P1 split check/commit:** mutation build passed in **27.425 s** (`round3-mutation-atomic-build.log`).
  The exact P1 test command above **failed as required**, exit 1, **0.011 s** test time / **7.456 s** work command
  (`round3-mutation-atomic-test.log`). Stop acceptance completed, but the synthetic transport received **one**
  submission and `accepted` was true: both intended assertions failed. This was not a timeout or an empty test
  selection. The runner restored this fault before applying the independent P2 mutation.
- **P2 omit acceptance cutoff:** mutation build passed in **24.139 s** (`round3-mutation-cutoff-build.log`).
  The exact P2 test command above **failed as required**, exit 1, **0.103 s** test time / **8.532 s** work command
  (`round3-mutation-cutoff-test.log`). Both pre-audio and streaming cases lost later reserved and unreserved
  request records, failed ticket admission, and refused continuation with `noRecipient`: eight expected issues
  across the two cases. This was not a timeout or an empty selection.

Both faults are removed. The runner verified **all four production SHA-256 digests** against the fixed bytes
saved before either fault (`round3-restoration.log`, `round3-fixed-digests.json`). Restored execution follows.

Restored build: **passed**, **26.36 s** Swift build time / **30.647 s** work command
(`round3-restored-build.log`), using the exact build command above. This replaces the mutation binaries with
the restored implementation. Post-restoration strict lint repeated the same 18-file command: **zero violations**
(`round3-final-lint.log`). All four working **and staged** production digests match the pre-mutation fixed bytes
(`round3-staged-restoration.log`).

Restored targeted Swift selection: **31 tests in 8 suites passed**, **1.791 s** test time / **9.708 s** work command
(`round3-restored-swift.log`), using the exact restored command above. The driver finished successfully after
restoring and verifying both faults. No unexpected test failure remains. All build/test work commands stayed
below the 810-second watchdog; host-slot and quiet waits were outside those work commands.

Round 3 scope against base `38c62e4f9f457ac9212578253d8a898a9a4c81c5` is **4/4 production files, zero renames**,
using `scripts/pr-shape.py`'s exact prefix/suffix exclusions and counting both names for a rename:

- `Sources/HailDaemonKit/Listener/HostReplyDelivery.swift`
- `Sources/HailDaemonKit/Listener/HostSession.swift`
- `Sources/HailDaemonKit/Listener/HostSession+Routing.swift`
- `Sources/haild/ReplyCommand.swift`

This round modifies the first two production files; tests and docs are excluded by the checker. Both working
and staged host scripts remain byte-identical to `origin/main`. No generated build products, private endpoints,
identities, recordings, transcripts, credentials or signing material are staged. No push, PR, online check,
installation, daemon restart, simulator/device build, physical playback or captured-output round trip occurred.
Fresh independent exact-head review remains pending; these local fixes and tests are not an approval.

## Round 4: one connection-scoped request stop gate

The supplied round 4 review reported REQUEST CHANGES on
`3a44b4b365d6eea2b6ff636e47c1bc888b8d71de`, rebased on
`d269d9612f4c392ce50f63e06f94990305d97278`. The reviewer's four stop-coverage probes and results record were
read first. They are committed as `ReplyQueueStopCoverageTests`, with only naming, diagnostic-print removal,
lint formatting and one additional marked/unmarked argument changed. This is local corrective verification,
not an independent review or approval.

`ReplyConnectionStopGate` holds one request cutoff per connection. Request minting, cutoff acceptance and the
final synchronous correlated transport submission use its mutex. Every correlated frame passes that final
gate, including unreserved continuation audio; the presence of a reservation or queue ticket does not select
whether to check stop authority. No actor hop or transport completion occurs while this gate is held. The
lock order remains policy/binding → privacy → optional ticket queue → request stop gate → transport handoff.
Session teardown removes the connection's cutoff.

Ordinary stops enter through the listener's narrower compatibility overload in `HostReplyDelivery.swift`,
which keeps the existing voice-report implementation and its coalescing behavior. An unmarked stop captures
request acceptance there before calling that implementation, carrying its immutable cutoff through the session
hop with task-local scope. Marked stops and device voice reports capture the same gate inside `captureStop`,
alongside their separate ticket position. Direct session-only stops capture at their synchronous actor step.
This integration stays within the four production files; `WebSocketListener.swift` is unchanged. The delayed
session step never defaults to an unlimited cutoff. Requests admitted after acceptance survive, even without
a ticket or descriptor. Mute still does not mark queued tickets.

Reservation liveness now checks the original job, epoch and connection. The old connection-ticket, target,
unpublished-floor and eviction-floor checks are removed from that request-liveness path, along with its stored
target. Target-wide ticket tombstones remain on queued-audio admission. They cannot retract another
connection's bound request or stop its heartbeat. Renewal and final publication check the owning connection's
request gate instead. The round 3 reservation-only final commit has become the uniform request gate; its
original-job lock still protects reservation retirement against transport commit. Ticket-based preservation
of later **request-less** flights remains a separate queue concern.

The regressions cover the synchronous unreserved transport race, actual loopback continuation publication
with both marked and unmarked stops, later request admission during a held unmarked stop, and the two-connection
shared-target case with B's ticket issued **before** its text. Earlier queue, authority, stop, recipient, policy,
privacy and lifecycle regressions remain in the broad selection below. These are synthetic socket/PCM and
CLI checks; no simulator, physical playback or captured-output round trip is claimed.

### Round 4 commands and mutation method

Before **each** build/test invocation, the host build-slot gate and full voice-quiet gate run in that order;
the slot is rechecked after quiet. Work commands have an 810-second watchdog. Scratch logs, caches, temporary
configuration and the host harness's allocation wrapper stay under `$SCRATCH`. The harness uses fake service
tools and isolated configuration. The selected Xcode developer directory is exported for every phase.

```sh
taskpolicy -b swift build --build-tests -j 2 --cache-path $SCRATCH/swift-cache

taskpolicy -b swift test --no-parallel --skip-build --cache-path $SCRATCH/swift-cache \
  --filter '(Reply(NewRequestQueue|QueueAuthority|QueueLifecycle|QueueStopAcceptance|QueueStopCoverage|QueuedAudio|Segment|Playback(Recipient|Controller|Stop|Supersede)|Recipient|StreamPacer)|RequestStreamLifetime|ProviderTurnRequestLifetime|LateAnswer|FinalDelivery|DeliveryStageOrder|RecipientPublicationGate|HostPlaybackStop|DeviceVoiceStop|AmbientWiringDismiss)'

# Working directory: Tests/ReplyCLITests
python3 -m unittest discover -s .

# Working directory: worktree root
env PATH="$SCRATCH/host-bin:$PATH" taskpolicy -b bash scripts/tests/test-host.sh

# Every Swift file changed against origin/main, including the newly added regression file.
swiftlint lint --strict $(git diff --name-only origin/main -- '*.swift') \
  Tests/HailDaemonKitTests/ReplyQueueStopCoverageTests.swift
```

The scratch driver `round4-verify.py` saves all four production digests, applies one mutation at a time, runs a
fresh gated build and its gated test, and restores source in `finally`. Expected failures require a successful
build, test exit 1 and the intended assertion diagnostic. Compilation errors, empty selections and watchdog
expiry do not count. Each mutation uses the build command above, then respectively:

```sh
taskpolicy -b swift test --no-parallel --skip-build --cache-path $SCRATCH/swift-cache \
  --filter 'ReplyQueueStopCoverageTests.noReservationMustOrderTransportWithAcceptedStop'

taskpolicy -b swift test --no-parallel --skip-build --cache-path $SCRATCH/swift-cache \
  --filter 'ReplyQueueStopCoverageTests.unmarkedStopMustPreserveLaterRequest'

taskpolicy -b swift test --no-parallel --skip-build --cache-path $SCRATCH/swift-cache \
  --filter 'ReplyQueueStopCoverageTests.stopOnOtherConnectionMustPreserveBoundRequestAuthority'
```

1. **P1:** Bypass the final request gate only when `queuedAudioAuthority` is nil, returning `enqueue()` directly.
   Preliminary candidate checks remain, so the held synchronous transport probe must catch the atomicity loss.
2. **P2a:** Derive the unmarked request cutoff from `queueStop?.requestCutoff` instead of independently accepting
   the request stop. Without ticket marking that token is nil, so the delayed session step captures too late.
3. **P2b:** Restore the target-wide ticket tombstone guard to reservation liveness, including its stored target.
   A's stop then wrongly makes B's bound request unrenewable.

After all mutations, digest restoration is checked, the restored source is rebuilt, and the **same broad Swift
selection** is repeated. No mutation is retained in the commit.

### Executed round 4 results

| Phase | Result | Work-command time | Evidence under `$SCRATCH` |
| --- | --- | --- | --- |
| Initial build | Passed; 459.70 s Swift build | 464.277 s | `round4-build.log` |
| Final build, with lifetime/deadline checks inside the request gate | Passed; 27.83 s Swift build | 32.146 s | `round4-build-final.log` |
| Broad Swift selection | 371 tests in 83 suites passed; 135.994 s test time | 144.303 s | `round4-swift.log` |
| Full Reply CLI suite | 172 tests passed; 377.718 s test time | 380.271 s | `round4-cli.log` |
| Unchanged host harness | `test-host: OK` | 123.656 s | `round4-host.log` |
| Strict lint | All 19 changed Swift files; zero violations | — | `round4-lint.log` |
| Restored build | Passed; 90.22 s Swift build | 93.673 s | `round4-restored-build.log` |
| Cache-free strict lint after restoration | Exactly 19 changed Swift files; zero violations | — | `round4-final-lint-pinned.log` |
| Restored broad Swift selection | 371 tests in 83 suites passed; 139.357 s test time; same 8 expected issues | 147.688 s | `round4-restored-swift.log` |
| Spoken-mute / coalescing integration | 7 tests in 2 suites passed; 1.868 s test time | 9.646 s | `round4-integration.log` |

The eight known Swift issues are deliberately matched timeout/cancellation diagnostics in
`RecipientPublicationGateTests` and `ReplyRecipientHandoffWaitTests`; they are expected assertions, with no
unexpected failure. The four new regression methods passed, including both marked/unmarked continuation cases,
as did all earlier queue and stop regressions. Initial build/test verification required no pre-existing-failure
exemption. The initial build was followed by a small refinement that moved lifetime/deadline checks inside the
new mutex; the final build and every subsequent test use that refinement.

Mutation execution results (each fault restored before the next):

| Fault | Build | Targeted test | Evidence under `$SCRATCH` |
| --- | --- | --- | --- |
| P1: unreserved final-gate bypass | Passed; 21.48 s Swift / 24.516 s work | Expected exit 1; 2 assertion issues; 0.011 s test / 7.519 s work | `round4-mutation-unreserved-build.log`, `round4-mutation-unreserved-test.log` |
| P2a: cutoff derived from ticket token | Passed; 21.71 s Swift / 25.656 s work | Expected exit 1; 1 assertion issue; 0.055 s test / 7.520 s work | `round4-mutation-unmarked-build.log`, `round4-mutation-unmarked-test.log` |
| P2b: target tombstone used for request liveness | Passed; 100.07 s Swift / 103.174 s work | Expected exit 1; 1 assertion issue; 0.055 s test / 7.447 s work | `round4-mutation-target-build.log`, `round4-mutation-target-test.log` |

For P1, stop acceptance completed, but `accepted` was true and the transport saw **one** submission. Both intended
assertions failed. This was a real one-test selection, with no timeout or compile error. The preliminary candidate
checks remained intact. The runner restored the fixed source before applying P2a.

For P2a, the request admitted during the held unmarked stop lost its record. The preservation assertion failed
with one real test selected, without a timeout or compile error. The runner restored that fault before P2b.

For P2b, B's ticket was issued before its text, A stopped the shared target, and B's next renewal deleted its
request. The preservation assertion failed with one real test selected, without a timeout or compile error.
All faults are removed. The runner verified all four production SHA-256 digests against the saved fixed bytes
(`round4-fixed-digests.json`, `round4-restoration.log`) before the restored build.

Final lint selects the supplied immutable base explicitly because the shared `origin/main` ref advanced during
verification. Its exact command (with the selected Xcode environment and scratch temporary/module-cache paths)
is:

```sh
HS1246_BASE=d269d9612f4c392ce50f63e06f94990305d97278
swiftlint lint --strict --no-cache --cache-path $SCRATCH/swiftlint-cache \
  $(git diff --name-only "$HS1246_BASE" -- '*.swift') \
  Tests/HailDaemonKitTests/ReplyQueueStopCoverageTests.swift
```

Another host session advanced `origin/main` to `f12ba2fbf78e26566b9aa4a7b4b0f968846b948f`, including unrelated
script changes. This fix retains the supplied branch history and base: the new local commit goes directly on
`3a44b4b365d6eea2b6ff636e47c1bc888b8d71de`. Scope and script-byte comparisons therefore use the supplied
`d269d9612f4c392ce50f63e06f94990305d97278` main base. No comparison against the newly advanced main is claimed
as a passing current PR contract; there is no PR or online check in this task.

Restored execution repeated the exact broad Swift command above. The driver completed successfully after all
three assertion-producing mutations and digest restoration. There is no unexpected build/test failure and no
A/B pre-existing-failure exemption. Each build/test **work command** stayed below the 810-second watchdog;
slot and quiet waits were outside those commands. No work ran while its host gates were waiting.

The compatibility entry point also receives the existing spoken-mute wire-order and stop-coalescing integration
checks, after restoration, using a separate gated phase:

```sh
taskpolicy -b swift test --no-parallel --skip-build --cache-path $SCRATCH/swift-cache \
  --filter '(AmbientWiringVoiceMute|SessionUpdateAudioAdmission)'
```

The integration selection passed all **7 tests in 2 suites**, including capable/older-device confirmation order,
unmute ordering and stop coalescing before transport completion. No unexpected failure occurred.

Final scope uses the checker's exact exclusions and rename handling against the supplied main base:
**4/4 production files, zero renames**. The four paths remain `HostReplyDelivery.swift`, `HostSession.swift`,
`HostSession+Routing.swift` under `Sources/HailDaemonKit/Listener/`, and `Sources/haild/ReplyCommand.swift`.
All working and staged production digests match the saved pre-mutation fixed bytes. All working and staged
`scripts/` bytes match that supplied main base; source and staged whitespace checks pass. Evidence is
`round4-final-scope.log`. The shared ref's later advance is documented above and is outside this local fix.

No generated build products or private endpoints, identities, recordings, transcripts, credentials or signing
material are staged. This is one new local commit on the supplied head. No push, PR, online CI check,
installation, daemon restart, simulator/device build, physical playback or captured-output round trip occurred.
Fresh independent exact-head review remains pending; local verification and mutation detection are not approval.

## Round 5 split, first branch: connection-local queue checks

Part of #1246. The supplied round 5 review of
`56ddd18c85e7c39281826a0cf0344e6ccd0c1043` found over-stopping, with no P1 finding.
The reviewer's boundary probe sources and `review-round5-boundaries.log`, and the preserved
exploratory queue-check patch, were read before implementation. The queue-check probe is committed as
`ReplyQueueConnectionCheckTests`; its obsolete expectation of a stopped check is corrected to require
successful admission. It still checks publication status, renewal after 20 seconds, and unticketed publication.
Diagnostic prints are removed.

A read-only queue check for an already bound request uses the resolved connection, or the job's bound text destination before routing,
to check only that connection's ticket cutoff. Shared-target marks and global eviction/unpublished floors
remain actual audio-publication and requestless-check policy. Bound correlated checks do not wait for another
connection's target snapshot or consume its wait budget; a second regression holds that stop unresolved. They cannot return `stopped` from another connection's check,
finish its original job, and thereby erase its bound request's publication authority on the next heartbeat.

This first branch retains exactly the original four production files against the supplied main base
`f12ba2fbf78e26566b9aa4a7b4b0f968846b948f`: `HostReplyDelivery.swift`, `HostSession.swift`,
`HostSession+Routing.swift`, and `Sources/haild/ReplyCommand.swift`. Only `HostReplyDelivery.swift` changes
in this new commit. The stacked follow-up `fix/1246-stop-scope` fixes **P2a/P2c/P3**: it captures the privacy
decision's original request cutoff, orders the unscoped device stop ahead of newer correlated frames, and
removes the empty teardown callback and its task. Both branches must be installed together. Its evidence is
recorded separately in `docs/testing/1246-stop-scope.md`; these follow-up behaviors are not claimed as fixed
by this first commit alone.

All verification is synthetic and local. Fresh independent exact-head review remains pending. No push, PR,
live configuration change, installation, daemon restart, simulator build, physical playback or captured-output
round trip is part of this work.

### Round 5 first-branch commands

Before each build/test phase, run the host-slot gate and then the full voice-quiet gate. The scratch runner
rechecks host load after quiet and limits each work command to 810 seconds. `$SCRATCH` denotes the external
scratch directory. Configuration, temporary files and module caches are redirected there. The Xcode environment
is exported for every phase. The unchanged host harness uses its own fake binaries, service tools, and isolated
configuration; its allocation wrapper is scratch-only.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
taskpolicy -b swift build --build-tests -j 2 --cache-path "$SCRATCH/swift-cache"
taskpolicy -b swift test --no-parallel --skip-build --cache-path "$SCRATCH/swift-cache" \
  --filter '(Reply(NewRequestQueue|QueueAuthority|QueueLifecycle|QueueStopAcceptance|QueueStopCoverage|QueueConnectionCheck|QueuedAudio|Segment|Playback(Recipient|Controller|Stop|Supersede)|Recipient|StreamPacer)|RequestStreamLifetime|ProviderTurnRequestLifetime|LateAnswer|FinalDelivery|DeliveryStageOrder|RecipientPublicationGate|HostPlaybackStop|DeviceVoiceStop|AmbientWiringDismiss|AmbientWiringVoiceMute|SessionUpdateAudioAdmission)'
# Working directory: Tests/ReplyCLITests
python3 -m unittest discover -s .
# Working directory: worktree root
env PATH="$SCRATCH/host-bin:$PATH" taskpolicy -b bash scripts/tests/test-host.sh
# All changed Swift files, including the staged regression file.
swiftlint lint --strict --no-cache --cache-path "$SCRATCH/swiftlint-cache" \
  $(git diff --name-only f12ba2fbf78e26566b9aa4a7b4b0f968846b948f -- '*.swift')
```

The P2b mutation changes only `checking: probe && correlated, send)` to `checking: false, send)` in
`ReplyAudioAdmission.enqueue`, restoring another connection's target mark as the check's stop authority.
It uses the same gated build followed by:

```sh
taskpolicy -b swift test --no-parallel --skip-build --cache-path "$SCRATCH/swift-cache" \
  --filter 'ReplyQueueConnectionCheckTests.otherConnectionQueueSkipMustNotRetractBoundRequest'
```

The runner restores the saved source bytes in `finally`, verifies byte equality, rebuilds, and repeats the
same broad Swift selection. A successful mutation requires a successful build, exit 1 from the one selected
test, and the intended authority assertion; a timeout, compiler failure or empty selection is not evidence.

### Round 5 first-branch A/B and corrections

The initial exploratory patch passed the reviewer's P2b regression, but its broad run failed:
**379 tests in 86 suites, 143.127 s**, with **3 unexpected issues** plus the existing 8 deliberately matched
known issues (`split1-swift.log`). It had applied the correlated-check exception to requestless checks too,
and consulted a newly learned destination during direct publication. The failures were in
`ReplyQueuedAudioTargetTests` and `ReplyQueuedAudioSelectionAcceptanceTests`.

A separate detached worktree at the supplied main `f12ba2fbf78e26566b9aa4a7b4b0f968846b948f` ran the same
existing suites. **All 8 tests in 2 suites passed**, **2.200 s** test time / **10.725 s** work-command time
(`split1-main-ab-tests.log`). These were introduced regressions, not a pre-existing-failure exemption. The
fix now limits the exception to correlated checks, leaves requestless checks' target policy intact, and uses
a stored destination only for the correlated-check path. It also covers unresolved other-connection stops.

The A/B cold build reached the 810-second watchdog and was stopped with only its owned processes cleaned up
(**812.786 s** including cleanup; `split1-main-ab-build.log`); this was not a completed build. A fresh gated
resume rebuilt the interrupted test module and passed: **424.77 s** Swift / **429.565 s** work-command time
(`split1-main-ab-build-resume.log`). Each work phase remained below 15 minutes. Exact A/B commands, with
working directory `$SCRATCH/main-ab` and the same environment/gates as above:

```sh
taskpolicy -b swift build --build-tests -j 2 --cache-path "$SCRATCH/swift-cache"
taskpolicy -b swift test --no-parallel --skip-build --cache-path "$SCRATCH/swift-cache" \
  --filter '(ReplyQueuedAudioSelectionAcceptance|ReplyQueuedAudioTarget)'
```

The next broad attempt was stopped at **256.259 s** (`split1-fixed-swift.log`, owned test process group only),
rather than reported as a pass. Bypassing pending snapshots for every request reference had also bypassed the
wait signal in an earlier **unbound, pre-text** `requestPending` probe. The exception now requires the ticket's
delivered-text destination to exist; an unbound probe retains the original wait/deadline behavior. The two
bound P2b regressions had passed before this interruption, but that incomplete broad attempt is not success
evidence.

The same `ReplyQueuedAudioExpiryTests` suite on the separate pinned-main worktree passed **all 4 tests in
1 suite**, **1.625 s** test / **9.676 s** work-command time (`split1-main-ab-expiry.log`), including the `check`
and `publish` cases. Its exact gated command, working directory `$SCRATCH/main-ab`, was:

```sh
taskpolicy -b swift test --no-parallel --skip-build --cache-path "$SCRATCH/swift-cache" \
  --filter 'ReplyQueuedAudioExpiryTests'
```

A build attempt then failed because a final source edit raced the gate opening: Swift reported
`input file ... HostReplyDelivery.swift was modified during the build` (**17.068 s**;
`split1-bound-build.log`). This is an editing error, not test or successful-build evidence. Sources were frozen
before the fresh verification. The same build command on the unchanged pinned-main worktree passed again:
**1.54 s** Swift / **6.392 s** work (`split1-main-ab-stable-build.log`).

### Executed round 5 first-branch results

| Phase | Result | Work-command time | Evidence under `$SCRATCH` |
| --- | --- | --- | --- |
| Stable fixed build | Passed; 84.08 s Swift | 88.684 s | `split1-final-build.log` |
| Broad Swift selection | 380 tests / 86 suites passed; 144.295 s test | 152.968 s | `split1-bound-swift.log` |
| Full Reply CLI suite | 174 tests passed; 377.950 s test | 381.217 s | `split1-cli.log` |
| Unchanged host harness | `test-host: OK` | 142.344 s | `split1-host.log` |
| P2b mutant build | Passed; 26.24 s Swift | 29.796 s | `split1-mutation-other-stop-build.log` |
| P2b mutant regression | Expected exit 1; 1 test, 4 assertion issues; 0.066 s test | 7.545 s | `split1-mutation-other-stop-test.log` |
| Restored build | Passed; 27.15 s Swift | 30.944 s | `split1-restored-build.log` |
| Restored broad Swift selection | 380 tests / 86 suites passed; 142.555 s test | 153.663 s | `split1-restored-swift.log` |
| Controller first-audio suite | 8 tests / 1 suite passed; 0.050 s test | 9.663 s | `split1-controller.log` |
| Final strict lint | All 20 changed Swift files; zero violations | — | `split1-final-lint.log` |

Both broad runs have only the same 8 deliberately matched known issues in publication-gate/handoff timeout
and cancellation probes. There are no unexpected failures in the final verification. The mutation reproduced
the intended failure: B's check was stopped, its publication status became absent, renewal deleted its request,
and unticketed publication failed. All four corresponding assertions failed; this was a real selected test,
not a compilation error, timeout, or empty selection.

Restoration compared the saved fixed source, restored working bytes, and staged bytes. All four production
files match their pre-mutation staged bytes (`split1-restoration.log`, `split1-restoration-scope.log`). The
restored build replaced the mutant binaries before the broad selection and controller check. The latter
also confirms the unchanged controller behavior underlying P2c, using this additional gated command:

```sh
taskpolicy -b swift test --no-parallel --skip-build --cache-path "$SCRATCH/swift-cache" \
  --filter 'ReplyPlaybackFirstAudioTests'
```

Final checker-based scope is **4/4 production files, zero renames**, against the supplied pinned main;
`split1-final-scope.log` verifies all working/staged source bytes, script identity, no HailCore/app changes,
and whitespace. This is one new local commit directly on the supplied head. P2a/P2c/P3 are delivered by the
stacked follow-up, whose separate record names this first branch's full parent SHA. Independent review of
these new heads remains pending; local test success is not an approving review.


## Full-suite host-gate corrections

The host gate's interleaved main/branch comparison identified two regressions in the first slice.
The original tests remain unchanged and fully enforced; no known-issue wrapper was added.

`CorrelatedReplyPublicationTests.expiryAfterReadySnapshotReturnsNonRetryablePublicationFailure`
uses `PublicationExpiryClock.expireAfter(reads: 2)` to expire causally after the original ready snapshot.
The queue-authority addition had introduced a third `requestClock()` read in that snapshot: one for
queue authority, one for request lifetime, and one under the policy/binding gates. Thus the synthetic
expiry occurred inside status selection, which returned `.absent`; the listener then reported
`.noRecipient` before any enqueue. This was introduced by the first slice, not a pre-existing failure.
The candidate now samples one instant for both queue deadline and request lifetime. Status still
rechecks lifetime under authority, and enqueue still independently rechecks lifetime, queue authority,
and the final transport gates. Expiry after a ready snapshot therefore retains the original
non-retryable `.publicationFailed` contract. Neither refusal expectations nor CLI retry policy change.

`AmbientPrivacyReplyRaceTests.aFastEntryAndExitNeverLetsAnOldReplyThrough` was fenced by the new
connection-stop cutoff before selection could reach the privacy hold, returning the wrong refusal.
The small refusal-classification correction previously in the stacked stop-scope slice is now in
this first slice's existing `HostReplyDelivery.swift`. Only while that connection's hold is active,
a retained committed candidate fenced by its cutoff is checked against the existing media,
selection, lifetime, policy and binding gates and sent through the existing `.privacyHeld` refusal
path. This never grants enqueue authority or bypasses the stop at transport commit. The second
slice inherits this correction; it no longer introduces it.

Verification commands (each phase runs the host-slot gate followed by the voice-quiet gate first):

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

The full Swift phase has a 45-minute work-command deadline. Temporary configuration and caches
remain in external scratch. All checks are local and synthetic; no installation, daemon restart,
live configuration change, simulator/device validation, push or PR is included.


The corrected first-slice full unfiltered run passed **4,238 tests in 887 suites**, with **13
expected known issues and zero unexpected failures**, in **1,882.337 s** test / **1,889.343 s**
work-command time (`gatefix-pr1-full.log`). The expected issues are deliberately matched by
`LocalDispatchPreflightWaitTests` (5), `RecipientPublicationGateTests` (3), and
`ReplyRecipientHandoffWaitTests` (5). No new known-issue wrapper was introduced. The HailCore
AudioInput load flake did not occur. No additional failure needed a main A/B exemption.
The build passed in **487.04 s** Swift / **492.121 s** work (`gatefix-pr1-build.log`); the unchanged
two affected suites passed **13 tests in 2 suites** in **5.543 s** (`gatefix-pr1-focused.log`).

The full Reply CLI suite passed **174 tests** in **454.117 s** test / **457.460 s** work
(`gatefix-pr1-cli.log`). Strict uncached lint of all **20 changed Swift files** passed with zero
violations (`gatefix-pr1-all-lint.log`). An initial single-file lint invocation omitted
`DEVELOPER_DIR` and failed to load SourceKit; the corrected environment passed immediately.

The unchanged isolated host harness returned **`test-host: OK`**, exit 0, in **138.523 s**
(`gatefix-pr1-host.log`). Final checker-based scope remains exactly **4 production files**, zero
renames, against pinned main. Scripts are identical to main; no HailCore/app source changes or
absolute home/private host-tool paths are added. The original commit message is retained when
amending the first slice. Independent exact-head review remains pending; no push or PR action
was performed.

## CI-only Stop harness correction (2026-11-19)

Part of #1246. The supplied PR #1268 macOS/Swift 6.3.3 failure excerpt reports the two new Stop ordering
probes timing out inside their synchronous enqueue callbacks. Those callbacks blocked a Swift cooperative
worker with `DispatchSemaphore.wait` while a GCD worker had to accept Stop. Their five-second deadlines
therefore tested scheduler availability as well as the intended ordering. This is consistent with starvation
under parallel runner load; the excerpt alone is not a thread-stack proof. Some neighboring timeout messages
are deliberately injected, expected known issues in the existing timeout-harness tests.

Production lock tracing found no circular wait in this path. `enqueueHostReply` holds policy/binding authority
while calling the supplied enqueue callback, but has not acquired the queue or request-stop commit mutex.
`captureStop` takes the queue mutex and then the request-stop mutex, without needing policy/binding authority
or a session actor turn. Final transport commit takes the same queue-to-request-stop order (skipping the
already-held queue mutex for ticketed publication). Network submission is synchronous; `prepared.result()`
awaits completion after those gates release. No production code is changed by this correction.

Both `noReservationMustOrderTransportWithAcceptedStop` and
`unticketedFinalEnqueueMustOrderWithStopAcceptance` now call synchronous `captureStop` directly in the enqueue
callback, after the preliminary admission check and before invoking `commit`. No gate, worker scheduling,
blocking wait or wall-clock race is needed for this interleaving. Both still assert accepted Stop before final
commit, refused commit, and zero transport submissions. The reserved and unreserved paths remain separate.

The audit covered all 21 test/support files changed by the first commit against the supplied main: 16 Swift
files and five Python files. Only these two Swift tests contained the cooperative-thread semaphore/GCD
handshake. Existing recipient-policy races deliberately use their dedicated executor; their synthetic timeout
self-tests retain their known-issue expectations. Other Swift holds suspend through continuations or async
sleep. Python thread/subprocess waits do not occupy Swift cooperative workers.

All commands below run with the selected Xcode developer directory and `taskpolicy -b`. Before each phase,
the external host-slot gate and then the full voice-quiet gate run. Builds use two jobs; temporary files,
module caches, package cache and logs are in `$SCRATCH/ci-fix`. No script, workflow, production file, installed
build or live configuration changes. This is local synthetic evidence, with no simulator/device proof,
installation, daemon restart, push, PR update, or new independent exact-head review.

### Correction commands and completed repetition evidence

The host reports Swift 6.2.4 and 16 logical CPUs. The exact Swift suite filter for changed test files is:

```text
(FinalDeliveryCommitTests|RecipientPublicationGateTests|ReplyNewRequestQueueTests|ReplyQueueAuthorityTests|ReplyQueueConnectionCheckTests|ReplyQueueLifecycleTests|ReplyQueueStopAcceptanceTests|ReplyQueueStopCoverageTests|ReplyQueuedAudioRoutingTests|ReplyRecipientAuthorityRaceTests|ReplySegmentsBackstopTests|ReplySegmentsHostSessionTests|ReplySegmentsListenerTests)
```

With that filter in `$PR1_SUITES`, the work commands were:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
taskpolicy -b swift build --build-tests -j 2 --cache-path "$SCRATCH/ci-fix/swift-cache" -Xswiftc -warnings-as-errors
# One gated repetition phase, 20 invocations:
taskpolicy -b swift test --skip-build --parallel --cache-path "$SCRATCH/ci-fix/swift-cache" --filter ReplyQueueStop
# One gated repetition phase, five invocations:
taskpolicy -b swift test --skip-build --parallel --cache-path "$SCRATCH/ci-fix/swift-cache" --filter "$PR1_SUITES"
taskpolicy -b swift test --no-parallel --skip-build --cache-path "$SCRATCH/ci-fix/swift-cache"
taskpolicy -b scripts/verify.sh test
```

- Cold warnings-as-errors test build: exit 0, 1151.787 seconds (`pr1-build.log`).
- `ReplyQueueStop` parallel loop: **20/20 passed**, seven tests in two suites each, 75.935 seconds total
  (`pr1-stop-20.log` and `pr1-stop-run-01.log` through `pr1-stop-run-20.log`).
- Changed Swift suites together: **5/5 passed**, 48 tests in 13 suites each, with three expected known issues
  from intentional timeout-harness tests; 23.507 seconds total (`pr1-files-5.log` and its per-run logs).
- Mutation: restore the two original semaphore/GCD tests byte for byte, rebuild successfully, then repeat
  the same 48-test parallel selection five times. **5/5 passed** (24.339 seconds); this host did not reproduce
  the CI timeout in this small selection. The broader parallel replay below subsequently reproduced both
  original Stop failures on this same Swift 6.2.4 host. The fixed files were restored in
  `finally` and rebuilt successfully (65.027 seconds) before the full-suite run.
- Strict SwiftLint on the two changed Swift files, with the selected Xcode environment: zero violations.

The CI-lane invocation uses scratch-only `swift` and `xcodebuild` wrappers: `swift build` receives `-j 2`
and the same external package cache, tests receive that cache, and the startup `xcodebuild -version` probe
is acknowledged without invoking `xcodebuild`. The script's filters, parallel/serial modes, event streams,
stall detection and test commands are unchanged. Repository scripts remain byte-identical to main.

### Full serial result and unrelated recheck

`pr1-full.log`: **exit 1**, 4238 tests in 887 suites, 1791.074 seconds of test time / 1796.334 seconds of work
command time. There were 13 known issues and one unexpected issue:
`AudioInputReconciliationFailureTests.automaticSelectionPropagatesQueuedReconciliationFailure`, line 12,
expected an error but none was thrown. Its remaining state assertions passed; all reply Stop tests passed.

`git diff f12ba2fb -- Sources/HailCore Tests/HailCoreTests/AudioInputReconciliationFailureTests.swift`
is empty. The fake backend emits `.routeChanged` through an `AsyncStream` and calls `Task.yield()` without
an acknowledgement that the controller has queued reconciliation before selection finishes. That ordering
can explain the missing throw; this is an inference from the unchanged source, not a production mutation proof.
No audio-input production or test files are changed in this correction.

A fresh gated isolated recheck used:

```sh
taskpolicy -b swift test --no-parallel --skip-build --cache-path "$SCRATCH/ci-fix/swift-cache" \
  --filter AudioInputReconciliationFailureTests
```

`pr1-audio-failure-recheck.log`: **exit 0**, all six tests passed, 5.566 seconds work-command time.
The full-suite result remains failed; the isolated pass is a separate result.

### CI-equivalent lanes and reproduced loaded mutation

The one `scripts/verify.sh test` invocation (`pr1-verify-test.log`) exited **1** after 135.498 seconds:

- Test build passed, using the scratch wrapper's two-job limit.
- Parallel core lane: **1314 tests in 305 suites passed**, 22.420 seconds.
- Parallel other-target lane: **2120 tests in 422 suites failed**, 97.013 seconds, with nine unexpected
  issues and 13 known issues. Both corrected Stop probes passed in that lane:
  `noReservationMustOrderTransportWithAcceptedStop` in 9.037 seconds and
  `unticketedFinalEnqueueMustOrderWithStopAcceptance` in 0.420 seconds.
- The script exited before its serial timing lane. The unchanged timing selection is run separately below.

The seven failing non-core test functions were the real-time backlog expectation in
`ReplyStreamPacerSocketBacklogTests` (7.295 seconds lead against the 5.25-second bound) and deadline failures
in `AmbientPolicyReloadRetryTests`, `AmbientPolicyQueuedRaceTests`, `AmbientPolicyProcessTests`,
`AmbientPolicyFreshStartTests`, and two functions in `AmbientPolicyProcessDeletionTests`. These test files
are unchanged from main, and they passed in the full serial run. Their failures remain reported; no tests
were moved into `TIMING_SUITES`, and no policy/pacer production or test changes are included here.

The earlier 48-test mutation was too small to recreate the problem. A second mutation restored both original
semaphore tests byte for byte, rebuilt successfully (64.908 seconds), and used the script's **entire non-core,
non-timing parallel selection**, with its core and timing regexes copied from the unchanged script:

```sh
CORE_PATTERN='^HailCoreTests\.'
# TIMING_PATTERN is the exact existing TIMING_SUITES alternation from scripts/verify.sh.
taskpolicy -b swift test --skip-build --parallel --cache-path "$SCRATCH/ci-fix/swift-cache" \
  --skip "$CORE_PATTERN" --skip "$TIMING_PATTERN"
```

`pr1-loaded-mutation.log` reproduced **both original CI failures**:

- `noReservationMustOrderTransportWithAcceptedStop`: `race gate timed out`, then `stopAccepted` false;
  failed after 10.588 seconds with two issues.
- `unticketedFinalEnqueueMustOrderWithStopAcceptance`: `Stop gate timed out; race is inconclusive`, then
  `stopWasAccepted` false; failed after 5.453 seconds with two issues.

The loaded mutation command exited 1 after 100.118 seconds. Other parallel-lane failures are also present;
only the two exact Stop timeout/acceptance failures above establish this mutation's detection. The same
selection passed those two probes with the fixes, and the smaller selection passed them even with the old
semaphores: the failure depends on test scheduling/load, not Swift 6.3.3 alone. Together with the production
lock trace, this establishes the blocking harness as the cause of the two reported Stop failures.

The fixed sources were restored in `finally` and rebuilt successfully (`pr1-loaded-restored-build.log`,
76.903 seconds) before continuing. Production, scripts and workflows still match the original PR 1 head.

The existing serial timing selection was then completed once, after both host gates, with:

```sh
taskpolicy -b swift test --skip-build --no-parallel --cache-path "$SCRATCH/ci-fix/swift-cache" \
  --filter "$TIMING_PATTERN"
```

`pr1-timing-serial.log`: **exit 0**, 804 tests in 163 suites passed, 433.640 seconds of test time /
441.308 seconds work-command time. The three lane selections therefore exercised all 4238 tests; the
script's own result remains failed at its parallel non-core lane. The full serial result also remains failed
at the separate unchanged audio-input test. These results are not represented as a green full suite or green CI.

Final correction scope is two Swift test files plus this evidence record. All four original production files
are byte-identical to `09851b8efbca8dcc42a64ba035797d41fc95aade`; the checker still counts **4/4**, zero renames,
against the supplied main. Scripts and workflows match that main. Commit message is preserved; independent
review of the new exact head remains pending.
