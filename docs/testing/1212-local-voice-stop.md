# Local voice stop: protocol and host evidence

Part of #1212, within #1211. This records PR 1a's protocol/host slice and PR 1b's queued-audio slice below.
All fixtures and evidence here are synthetic; there is no detector, app change, simulator or physical-device proof,
live captured-output round trip, installation or upload. PR 1a's records and deferrals are historical; the current
1b section records queue behavior and the remaining device requirements stay deferred.

## Implemented boundary

- `voice_stopped` carries only optional bounded integer `latency_ms` (0...60,000). Both encoding and decoding enforce
  the bound; decoding and schema reject unknown fields and explicit null. The host capability is `device_voice_stop`.
  This PR carries `protocol:compatible` and `security:critical`; this local revision changes no GitHub metadata.
- Negotiation, matching protocol version, authorization, the reporting connection's active ambient stream and privacy
  off gate the host stop. Unready, inactive and private reports have content-free reason tokens.
- The handler reuses `WebSocketListener.stopReplyPlayback(connection:)`, including the existing in-flight reply
  retirement and stopped-reply ledger. No request is withdrawn. No confirmation is played for a device report.
- A per-connection monotonic timestamp suppresses only the #418 confirmation of a later RightyO playback dismissal
  for less than ten seconds. The timestamp is replaced on every valid report and removed at teardown.
  Dismissal effects, guard holds, target policy, confirmation tier, mute/unmute and reply queueing are unchanged.
- `AmbientRightyoRouter.replyPlayback(_:connection:)` already forwards admitted `reply_playback_end` and playback-error
  diagnostics to RightyO as ended. Local `ReplyPlaybackController.stopPlayback` clears active playback;
  `DeviceDiagnostics.watch` observes the busy-to-idle edge and emits `reply_playback_end`. This report does not
  synthesize another end, avoiding a second source of truth.

## Deterministic tests

`DeviceVoiceStopProtocolTests` covers frame round trips with omitted and boundary latency, invalid encoding and
wire values, unknown-key refusal, the closed schema rule, and a helper that sends nothing to a simulated legacy host.
`DeviceVoiceStopSessionTests` covers capability advertisement only with both gate and handler, unnegotiated/closed
reports with `reason=not_ready`, unwired/read-only ignores, authorization, and attribution to the negotiated
connection rather than payload data.

`DeviceVoiceStopTests` uses loopback WebSockets and a synthetic child held at an explicit release point. It covers
retirement of multiple in-flight replies, event latency, absence of a device-stop confirmation, privacy/inactive
refusals, another connection's inability to stop the active one, and unchanged later replies. Its injected monotonic
clock tests RightyO confirmation at 0, 9, 10 and 11 seconds. The privacy refusal test seeds the existing host
private-state slot directly; it does not claim a real privacy-entry exchange. Negative socket assertions follow
completed handler logs and ping/pong barriers; none use a settling delay or block a cooperative thread. The existing
`AmbientWiringStopConfirmationTests` remain part of the focused repeat selection.

## Deferred expectations and PR 1b hook

PR 1b must prevent detached `haild reply` jobs waiting on `reply-audio.lock` from starting audio after a stop. The
hook belongs at the existing connection stop boundary, `WebSocketListener.stopReplyPlayback(connection:)`, and the
CLI's `ReplyBackground.awaitAudioTurn(socket:target:)` lock-acquisition/admission boundary: the current stopped-reply
ledger covers replies whose audio has already entered flight, not a job that has not published audio yet. This PR deliberately adds no queue-job clearance.

Later device work must tap echo-cancelled capture before masking, enforce privacy and the setting, stop local
playback/queue before sending, and validate owner latency and self-trigger rejection physically before default-on.
Those detector, device queue, reply-text guard timing, battery and physical proof expectations are not claimed here.

## Round 1 verification (historical)

The Dev Work VM uses a fresh `vw1212a` workspace at the requested main base, with the local source delta copied
without a push. Phases run sequentially after the shared lane is idle. Each phase has a 590-second deadline and
signal/finally cleanup that terminates and kills its process group. Swift package concurrency is capped at four
jobs and each compiler at one worker. No synthetic load workers, dependency fetch, installation or upload are used.
The workspace build directories are deleted after verification.

The exact build/test argument prefix is:

```bash
flags=(
  -j 4 --disable-automatic-resolution -Xswiftc -j1
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  -Xswiftc -plugin-path
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
)
taskpolicy -b swift build --build-tests "${flags[@]}" -Xswiftc -warnings-as-errors
# Each selection below runs as a separate capped phase:
taskpolicy -b swift test --skip-build --no-parallel "${flags[@]}" --filter '<selection>'
taskpolicy -b python3 -m unittest discover -s Tests/ReplyCLITests
taskpolicy -b swift run --skip-build hail-protocol-gen
```

The existing `vw-werr.sh vw1212a` wrapper runs under the same outer 590-second process-group cap. An external
`swift` shim adds `-Xswiftc -j1 --disable-automatic-resolution` to the wrapper's four-job build, so its separate
warnings-as-errors package/test build respects the worker cap. The wrapper's `werr build=0` marker and its build log
are checked, since wrapper exit status alone does not prove a successful build.

Final source results (function counts are Swift Testing's summary; case executions include parameterized rows):

| Selection / phase | Runs | Functions / suites | Case executions per run | Result / seconds |
| --- | ---: | ---: | ---: | --- |
| `DeviceVoiceStop\|AmbientWiringStopConfirmation\|HostPlaybackStop` | 3 | 29 / 5 | 55 | pass; 7.177, 6.340, 7.035 |
| `HailProtocolTests` | 1 | 167 / 31 | 573 | pass; 0.307 |
| `HailDaemonKitTests\.Ambient[A-M]` | 1 | 134 / 25 | 207 | pass; 102.863 |
| `HailDaemonKitTests\.Ambient[N-S]` | 1 | 317 / 65 | 488 | pass; 336.532 |
| `HailDaemonKitTests\.Ambient[T-Z]` | 1 | 214 / 49 | 395 | pass; 134.498 |
| `HailDaemonKitTests\.Rightyo` | 1 | 186 / 17 | 228 | pass; 35.109 |
| `HailDaemonKitTests\.(WebSocketListener\|WebSocketPeer\|Listener\|HostReply\|Dismiss\|StopConfirm)` | 1 | 22 / 5 | 67 | pass; 0.868 |

The three ambient partitions exactly cover the requested `Ambient` family. Together with RightyO and the listener
partition, the requested broad daemon selection passed 873 functions and 1,385 case executions. Every selection
started tests. The final warnings-as-errors package/test build preceding these runs passed in 35.45 seconds.
SHA-256 comparison confirmed identical host and VM contents for all nine changed Swift files.

Initial build attempts exposed test-helper compile errors, and the first focused run exposed a private-state
fixture that could not enter privacy with its unsupported child. Those test setup errors were corrected before the
final runs above. A final ingress audit also added tokenized ignores for read-only/unwired sessions; all results
above were rerun after that correction.

The full Reply CLI command above passed **126 tests in 232.676 seconds**, exit 0. The VM generator regenerated
57 canonical fixtures and the v1 schema; only the schema changed. Host conformance checks then passed:

```bash
python3 scripts/check_schema.py
python3 -m unittest scripts/tests/test_check_schema.py
```

Results: **57 valid fixtures, 121 negative fixtures rejected, zero failures; 11 schema-checker unit tests passed**.

Host strict SwiftLint, the 120-column check and whitespace validation exited 0 and emitted no output for all nine
changed Swift files, including all tests and test support. Reproduce against the requested base after committing:

```bash
swift_files=( $(git diff --name-only f3f97bc71a3501db2fc59887f0af208d7af3a50f HEAD -- '*.swift') )
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftlint lint --strict --quiet "${swift_files[@]}"
awk 'length($0)>120 {print FILENAME ":" FNR ":" length($0)}' "${swift_files[@]}"
git diff --check f3f97bc71a3501db2fc59887f0af208d7af3a50f HEAD
```

No added `#expect` chains string additions. No lint suppression was added; the existing receive method moved to
an extension to keep the actor within the configured type-body limit.

The PR-shape checker's exact exclusions yield **four production files**: `Control.swift`, `Schema.swift`,
`HostSession.swift` and `WebSocketListener.swift`. There are no renames. Tests, documentation and the canonical
schema JSON are excluded by that checker. The two listener files require `security:critical`; the capability-gated
v1 extension requires `protocol:compatible`. This PR carries both labels; no labels were changed locally.

The separate warnings-as-errors wrapper completed in **232.10 seconds**, reported **`werr build=0`**, and exited 0.
Its build log contains zero errors and 120 CLT debug-symbol warnings about missing module-cache files; all warning
lines belong to that category, with no other warnings. This is a successful Swift warnings-as-errors build, with
that toolchain debug-symbol limitation recorded rather than a claim of warning-free output.

A final SHA-256 comparison matched all nine changed Swift files and the canonical schema JSON between host and VM.
Both job build directories (the workspace `.build` and the separate wrapper build), plus the external compiler shim,
were deleted. No job build/test processes remained. No generated build product is included in the change.

No online PR-shape, CI check or independent review is claimed. Only the two authorized issue reads were made;
the existing PR was neither updated nor published by that local verification session.

## Round 2 fixes and deterministic coverage

The actual listener now passes no report callback without ambient wiring. `AmbientListenerWiring.deviceVoiceStopped`
is required, so a wiring cannot silently inherit a no-op. Pre-hello reports fail closed with a malformed error;
authorization denial always logs `reason=unauthorized`, including the read-only probe authorizer. All ingress and
router refusal/coalesced lines are bounded per reason and connection to one per ten seconds; the next line includes
the suppressed count. Accepted reports less than one second apart refresh the window and retire pending clips but
send no second `stop_playback`. The hyphenated dismissal token `reason=device-voice-stop` is intentional: it follows
RightyO's `reason=stop-phrase` convention.

Stop confirmations now prepare a whole clip, then check the connection's window and pending-confirmation token
under the same lock as the final enqueue. An accepted report retires every pending confirmation on that connection,
including work paused for longer than ten seconds. Known ordering bound: a RightyO dismissal whose confirmation
has already enqueued before the host records the device report can still speak. PR 3 must have the device drop a
host stop-confirmation clip arriving within a short window after its local stop; that device mitigation is deferred.

- `DeviceVoiceStopRaceTests`: hold a confirmation, accept a device stop, advance eleven seconds and release;
  assert exactly the `device_stopped` token and a ping/pong with no text/audio clip. Also cover a stop on A followed
  by B's ordinary spoken RightyO confirmation; queued take-over/reload refusal; and teardown followed by a new
  stream on the same connection ID with normal spoken confirmation.
- `DeviceVoiceStopTests.anotherConnectionCannotStopTheActiveConnectionsReplies`: publish first audio on the active
  connection, report from another, then assert the active reply's final audio still publishes and arrives.
- `DeviceVoiceStopAdmissionTests`: negotiate through the actual listener with/without ambient wiring; assert one
  stop for a burst, one coalesced token and the exact later suppressed count; test independent refusal reasons at
  the nine/ten-second boundary. `DeviceVoiceStopSessionTests` adds read-only refusal log coalescing with exact counts.
- Five negative `voice_stopped` fixtures cover extra keys and latency -1, 60001, null and 1.5. Both
  `scripts/check_schema.py` and `LimitsAndNegativesTests.everyNegativeFixtureIsRejectedByItsPayloadRule` discover
  the directory automatically; neither consumer needs a production change. A positive canonical fixture is deferred:
  it needs `Sources/HailProtocolFixtures/Fixtures.swift`, which would be a fifth production file.

Round 2 uses only the authorized `gh issue view 1212` read. No remote publication or existing PR update is performed.
This remains synthetic host evidence; device detection, app delivery and physical proof are outside this revision.

## Round 2 verification

Verification uses a fresh `vw1212a2` checkout seeded from the host's local bundle at
`681fb23acdd3b9b2e305c52463168550f841fd9a`, with the working source delta copied locally. It uses the same
four-worker flags, background priority, disabled automatic resolution, sequential phases and 590-second process-group
watchdog above; every phase has signal/finally TERM/KILL cleanup. No dependency fetch or synthetic load workers run.
The separate wrapper starts with a fresh `vw1212a2-werr` build path and the same external Swift shim.

The final focused selection is:

```bash
selection='DeviceVoiceStop|AmbientWiringStopConfirmation|HostPlaybackStop'
selection+='|TaskProgressGuardedWake|TaskProgressHostIntegration|LocalSessionUpdate'
selection+='|AmbientWiringOwnerReplyRouting|AbandonedReplyEcho904'
taskpolicy -b swift build --build-tests "${flags[@]}" -Xswiftc -warnings-as-errors
# Three separate capped phases:
taskpolicy -b swift test --skip-build --no-parallel "${flags[@]}" --filter "$selection"
```

The broad selections and CLI command are identical to round 1's table above. Schema verification on the VM uses:

```bash
taskpolicy -b swift run --skip-build hail-protocol-gen
taskpolicy -b python3 scripts/check_schema.py
taskpolicy -b python3 -m unittest scripts/tests/test_check_schema.py
```

All final phases passed. Swift Testing reports functions separately from parameterized case executions:

| Selection | Runs | Functions / suites | Case executions per run | Result / seconds |
| --- | ---: | ---: | ---: | --- |
| Final focused selection | 3 | 67 / 14 | 126 | pass; 14.654, 13.192, 14.204 |
| `HailProtocolTests` | 1 | 167 / 31 | 578 | pass; 0.241 |
| `HailDaemonKitTests\.Ambient[A-M]` | 1 | 134 / 25 | 207 | pass; 107.422 |
| `HailDaemonKitTests\.Ambient[N-S]` | 1 | 317 / 65 | 488 | pass; 334.761 |
| `HailDaemonKitTests\.Ambient[T-Z]` | 1 | 214 / 49 | 395 | pass; 135.120 |
| `HailDaemonKitTests\.Rightyo` | 1 | 186 / 17 | 228 | pass; 34.380 |
| Listener partition (round 1 selection) | 1 | 22 / 5 | 67 | pass; 0.818 |

The requested broad daemon families passed **873 functions and 1,385 case executions**. The final focused repeats
include complete confirmation audio-payload assertions; three preliminary repeats also passed before those assertions
were tightened. Production sources were identical throughout these test runs. The final default-path
warnings-as-errors test build passed in **16.49 seconds**. Earlier compile attempts caught callback type inference
and an unused lock result; both were corrected before the reported test runs.

The full Reply CLI suite passed **126 tests in 230.982 seconds**, exit 0. The VM generator regenerated 57 canonical
fixtures and the v1 schema without content drift. Both VM schema checks passed: **57 valid fixtures, 126 negatives
rejected, zero failures; 11 checker unit tests in 0.003 seconds**. The Swift conformance log explicitly includes all
five new `control-voice-stopped-*` negative fixtures.

The separate warnings-as-errors wrapper passed in **233.61 seconds**, with **`werr build=0`**, wrapper exit 0 and
zero build errors. Its 120 warning lines all belong to the existing CLT missing-module-cache debug-symbol category;
there are no other warning categories. This is a successful Swift warnings-as-errors build, with that toolchain
limitation recorded, rather than a claim of warning-free linker output.

Host strict SwiftLint (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`), the awk 120-column check and
whitespace validation passed and printed nothing for **all 16 changed Swift files** against the PR base. The
PR-shape checker's exact exclusions still give **four production files**: `Control.swift`, `Schema.swift`,
`HostSession.swift` and `WebSocketListener.swift`; there are no renames. The production/test source commit is
`dfc6085836bde7c456573ffe411936594264fdc1`.

Final SHA-256 verification matched all 16 changed Swift files, the canonical schema and the five new negative
fixtures between host and VM (22 files). The scoped cleanup removed the workspace `.build`, separate wrapper build
and both compiler shim paths after verification; no job build/test processes remained. No generated build product
is committed. No simulator, physical-device, captured-output round-trip or installation proof is claimed.


## Round 3 fixes and deterministic coverage

The router refreshes only the ten-second confirmation-suppression timestamp on every valid device report. Each
report reaches the session's stop ledger, including a coalesced report. The session atomically compares a separate
last-accepted stop timestamp and reply-ledger revision before retiring replies. The revision observes every ledger
write, including admission of final-only audio. Only the outbound `stop_playback` frame and redundant dismissal log
are coalesced, and only within one second of the last accepted stop with no intervening audio. A coalesced report
retains the accepted timestamp, snapshotting the post-retirement revision so its own ledger write cannot slide or
invalidate the window. The round-2 description of a sliding window above is historical and superseded here.

Ignored-report log registration now checks live listener membership and transport retirement before touching the
router map. Confirmation registration uses the same listener membership boundary and checks the router's closed and
latest-stream state. Confirmation cleanup removes an empty token set. A confirmation retired by connection teardown
uses `reason=connection_closed`, rather than attributing it to a device stop. The listener's unreachable ambient
fallback is removed, the acknowledgement hold documents both callers, and the unnegotiated-session test injects its
clock. These changes use only the PR's existing `HostSession.swift` and `WebSocketListener.swift` production files.

- `DeviceVoiceStopCoalescingTests.audioSinceTheAcceptedStopRequiresAnotherStop`: an accepted stop at zero,
  audio at 0.2 seconds and another stop at 0.5 seconds. Streaming audio's remaining frame is refused exactly as
  `replyStopped`; streaming, completed and final-only audio each require a second outbound stop.
- `DeviceVoiceStopCoalescingTests.coalescedReportsDoNotSlideTheAcceptedStopWindow`: six reports every 0.9 seconds
  yield exactly three outbound stops, at 0, 1.8 and 3.6 seconds, with a ping/pong barrier after each completed report.
  The existing `DeviceVoiceStopAdmissionTests.repeatedAcceptedStopsSendOneStopAndCoalesceTheirLog` still covers bursts.
- `DeviceVoiceStopTeardownTests`: await real listener teardown, then a late report and a late dismissal; directly
  assert no connection entry in the report-log, device-stop and confirmation maps. Also await a completed spoken
  confirmation and assert its empty token set was removed, with exact text/audio assertions. Hold another confirmation
  with a continuation, tear down its router connection, release and await completion; assert exactly
  `outcome=skipped reason=connection_closed` and a ping/pong with no clip.

All new tests use Swift Testing, an injected monotonic clock, awaited operations or continuation barriers, and exact
state/frame assertions. No negative assertion follows `settle()` or a delay, and no cooperative thread is blocked.
This remains synthetic host evidence; no simulator, device detector, physical-device, captured-output round trip,
installation or upload is claimed. Only `gh issue view 1212` is used; no push, PR or GitHub metadata update is made.


## Round 3 verification

The fresh Dev Work VM workspace `vw1212a3` was cloned from a local bundle at the requested starting revision
`15accec68bf2f719acdeb1a6089e97373797ec03`, then received the local delta without a push. The verified production
and test source commit is `446807a75c31e2c93bef201a578832228f3cbad3`; the subsequent verification record changes
only documentation. Apple Swift 6.3.3 targets `arm64-apple-macosx26.0`. Phases are sequential, wait for the shared
lane to be idle, run at background priority and have the round-1 590-second process-group cap with signal/finally
TERM/KILL cleanup. SwiftPM uses four jobs, each compiler one worker; automatic resolution is disabled. No dependency
fetch, synthetic load, installation or upload is used. The wrapper's separate `vw1212a3-werr` build path starts fresh.

The exact flags and commands are the round-1 prefix and phase commands above, with the round-2 focused selection
unchanged (the `DeviceVoiceStop` prefix includes the new coalescing and teardown suites). In particular:

```bash
taskpolicy -b swift build --build-tests "${flags[@]}" -Xswiftc -warnings-as-errors
taskpolicy -b swift test --skip-build --no-parallel "${flags[@]}" --filter "$selection"
# The same command with each broad filter below, as a separate capped phase.
taskpolicy -b python3 -m unittest discover -s Tests/ReplyCLITests
taskpolicy -b swift run --skip-build hail-protocol-gen
taskpolicy -b python3 scripts/check_schema.py
taskpolicy -b python3 -m unittest scripts/tests/test_check_schema.py
# Separate capped phase, with the external one-worker/disabled-resolution Swift shim:
/bin/zsh ~/codex-workspaces/vw-werr.sh vw1212a3
```

An initial build exposed an invalid `Frame.kind` assertion in the new teardown test. It was replaced with exact
text/audio payload assertions before final verification. The corrected warnings-as-errors test build passed in
**64.77 seconds**. Every reported runtime selection started tests and passed:

| Selection | Runs | Functions / suites | Case executions per run | Result / seconds |
| --- | ---: | ---: | ---: | --- |
| Round-2 focused selection, including new suites | 3 | 72 / 16 | 133 | pass; 19.675, 20.853, 20.476 |
| `HailProtocolTests` | 1 | 167 / 31 | 578 | pass; 0.140 |
| `HailDaemonKitTests\.Ambient[A-M]` | 1 | 134 / 25 | 207 | pass; 107.753 |
| `HailDaemonKitTests\.Ambient[N-S]` | 1 | 317 / 65 | 488 | pass; 344.520 |
| `HailDaemonKitTests\.Ambient[T-Z]` | 1 | 214 / 49 | 395 | pass; 133.806 |
| `HailDaemonKitTests\.Rightyo` | 1 | 186 / 17 | 228 | pass; 34.355 |
| Round-1 listener partition | 1 | 22 / 5 | 67 | pass; 0.662 |

The requested round-1 daemon families total **873 functions and 1,385 cases**. The listener partition's exact filter
is `HailDaemonKitTests\.(WebSocketListener|WebSocketPeer|Listener|HostReply|Dismiss|StopConfirm)`.

The full Reply CLI suite passed **126 tests in 232.053 seconds**, exit 0. The VM generator regenerated **57 canonical
fixtures** and the v1 schema with no fixture/schema drift. The VM schema check passed **57 valid fixtures,
126 negatives rejected, zero failures**; all **11 checker unit tests** passed in 0.003 seconds.

The separate warnings-as-errors wrapper completed in **233.68 seconds**, reported **`werr build=0`**, and exited 0.
Inspection of its full build log found **zero errors** and **120 warnings**, all in the existing CLT
missing-module-cache debug-symbol category; there were no other warning categories. This is a passing Swift
warnings-as-errors build, rather than a claim of warning-free linker output.

Host strict SwiftLint used `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; it and the awk 120-column check
exited 0 and printed nothing for **all 18 Swift files changed by the PR**. Their captured output files are empty.
Whitespace validation also passed. The checker's exact production-file exclusions still yield **four production
files**: `Control.swift`, `Schema.swift`, `HostSession.swift`, and `WebSocketListener.swift`, with no renames.
Round 3 touches only the latter two production files; no fifth file was needed and no lint suppression was added.

A final SHA-256 comparison matched **24 files**: all 18 changed Swift files, the canonical schema, and the five
negative fixtures. Scoped cleanup deleted the workspace `.build`, the separate wrapper build directory, and both
external compiler shim paths. Cleanup confirmed that no job build/test processes remained. No generated build
product is committed. All requested VM phases passed under their individual caps. No simulator or physical-device
proof, live captured-output round trip, online CI result, independent review, installation, upload, push, or PR
update is claimed.

## 1b round 1: queued reply audio (historical synthetic evidence)

This local slice starts at PR #1214's unmerged head `ad25cb8c7ea339ac0455a191747e5caf997283c3`, on
`feat/1212-queued-reply-stop`. At that historical verification, no push, PR, install, upload or installed-build
replacement was in scope. This is
host-side synthetic evidence, not a device detector, physical hearing or live captured-output round trip.

The ordering and coverage descriptions in this round-1 section are historical; round 2 supersedes them below.

### Ordering, destination and retained text

One daemon-owned counter issues queue tickets over the existing secured reply socket, only after a detached job
finds `reply-audio.lock` busy. A ticket includes a daemon epoch; stale/invalid tickets fail closed. Accepted stops
record the current position per connection. A job is skipped exactly when its position is at or below the mark
of the connection ordinary routing resolves for it. The existing request owner or text/first-frame routing pin
wins; otherwise current last-input/single-selector/ambient-owner resolution applies. No wall clock or time window
compares jobs with stops. Ticket allocation after a stop always yields a greater position.

The CLI checks after lock acquisition and carries its ticket on every audio publication. A shared synchronous
lock linearizes stop marks and final transport enqueue, closing the admission-to-first-frame race. Probes send
no audio to a device, mutate no request/flight state and mint no pin. Skips leave delivered text and Markdown
intact, preserve the request, log `reply_audio_skipped reason=stopped request=<UUID|none> ticket=N`, and take a
non-error CLI path with the stderr note `reply audio skipped after a stop`. The existing detached-job readiness
policy redirects later stderr to `/dev/null`; use the daemon event to observe a job skipped after caller release.
A job that never waited retains its existing behavior. Both stop sources mark; a voice mute does not.

### Scope and deferred carried LOW

(C) is implemented: a held confirmation resumed after real listener-wide teardown logs exactly
`outcome=skipped reason=connection_closed`. `DeviceVoiceStopTeardownTests` exercises `listener.stop`, not only a
router or gate teardown.

(D) is deferred to a separate follow-up: session-update audio admission lives in
`WebSocketListener+SessionUpdateAudio.swift` / `WebSocketListener+SessionUpdate.swift`; fixing its revision would
require a fifth production file in this slice. Within one second of an accepted device stop, session-update speech
can still leave a follow-up outbound `stop_playback` coalesced because that path does not advance
`replyFlightRevision`. A device report is defined to follow its local halt; this bound is not a claim that
session-update revision tracking is fixed. Proposed split: bump the revision at session-update audio admission with a dedicated regression.

The checker exclusions and rename handling give four production files, relative to the specified PR 1a head:
`HostReplyDelivery.swift`, `WebSocketListener.swift`, `LocalReplyEndpoint+Submission.swift`, `ReplyCommand.swift`.
There were no renames. Listener edits made this `security:critical`; at that historical verification independent
exact-head review was pending.
No review, GitHub check or PR-shape network validation is claimed.

### Deterministic coverage

- `ReplyQueuedAudioTests`: two pre-stop tickets skip, a strictly later ticket plays at an injected 100 ms;
  text survives, exact content-free logs, both the actual RightyO dismissal and device frame paths; stop after
  admission but before publication.
- `ReplyQueuedAudioRoutingTests`: correlated ownership scopes a stop to its own connection, request-id logging,
  retained request ownership, foreign/zero/future ticket refusal.
- `ReplyQueuedAudioMuteTests`: actual spoken mute still permits queued audio publication.
- `ReplyQueuedAudioRaceTests`: a continuation holds publication after recipient resolution; a completed stop
  wins at final enqueue, with no stray frame after an awaited publication and ping/pong barrier. Coalesced device
  reports still mark jobs enqueued since the previous stop.
- `ReplyQueuedAudioEndpointTests`: real secured local socket issuance/check/publication, text retention, later
  admission, malformed queue shapes. `DeviceVoiceStopTeardownTests` adds the real listener-teardown regression.
- `QueuedReplyStopTests` in the full Python Reply CLI suite: actual waitable jobs behind a held kernel flock;
  text and metadata precede waiting, stopped speech/PCM jobs exit 0 with no audio publications, admitted jobs use
  their issued ticket on all audio; explicit rate/pending refusal retries, a stop at first publication, and legacy
  daemon refusal. The existing shared mock transparently models the new queue contract for
  prior CLI queue tests; ordinary frame assertions remain unchanged.

All new negative assertions follow completed jobs/handlers or explicit continuation and socket barriers, without
`settle()`-then-negative assertions, detached tasks with synchronous waits, or fixed settling delays.


### 1b verification commands and load controls

Verification uses the fresh Dev Work VM checkout `vw1212b`, seeded entirely from local git bundles at the requested
PR 1a base, then synchronized to source/test commit `5221aebe7d98cd5eaa999a8295719ca5651fb7e3`. Subsequent changes
record results in documentation only. All phases run sequentially after the shared lane is idle, at background
priority, with an outer 590-second process-group deadline and signal/finally TERM/KILL cleanup. SwiftPM uses four
jobs and each compiler one worker; automatic resolution is disabled. No dependency fetch, synthetic load workers,
installation or upload occurs. The separate wrapper build starts fresh in `vw1212b-werr`.

Use the round-1 `flags` array above (the same CLT Testing framework/plugin/linker flags) with these exact commands;
each build, test selection, CLI run and wrapper is a separate capped phase:

```bash
taskpolicy -b swift build --build-tests "${flags[@]}" -Xswiftc -warnings-as-errors
# Run this selection three times:
taskpolicy -b swift test --skip-build --no-parallel "${flags[@]}" --filter \
  'ReplyQueuedAudio|DeviceVoiceStop|AmbientWiringStopConfirmation|HostPlaybackStop|AmbientWiringVoiceMute|LocalReplyEndpoint|LocalVoiceGuardsStatus'
taskpolicy -b python3 -m unittest discover -s Tests/ReplyCLITests
# One invocation per selection below:
taskpolicy -b swift test --skip-build --no-parallel "${flags[@]}" --filter "$selection"
# With the external Swift shim appending -Xswiftc -j1 --disable-automatic-resolution:
/bin/zsh ~/codex-workspaces/vw-werr.sh vw1212b
```

The selections exactly cover `HailDaemonKitTests` Ambient, Rightyo, Listener, WebSocket, HostSession, Host, Reply
and DeviceVoiceStop families; the `Host` prefix includes all `HostSession` suites. The focused selection also
covers the changed endpoint path and all device-stop/protocol suites. The wrapper's build log and actual
`werr build=0` marker are checked separately from its shell exit status.


The final source/test build with warnings-as-errors passed in **19.12 seconds**. Initial iterations corrected a
missing explicit Swift optional type, actor-isolated test inspection, socket path lengths, and a test helper that
captured router events but not listener events. A local bundle-ref typo interrupted one launch before final
verification; the listed runs use the confirmed committed head and matching host/VM source checksums.

| Selection / phase | Runs | Functions / suites | Case executions per run | Result / seconds |
| --- | ---: | ---: | ---: | --- |
| Focused selection above | 3 | 88 / 19 | 133 | pass; 37.003, 36.790, 37.737 |
| Full Reply CLI | 1 | 132 Python tests | — | pass; 239.768 |
| `HailDaemonKitTests\.Ambient[A-M]` | 1 | 134 / 25 | 207 | pass; 106.682 |
| `HailDaemonKitTests\.Ambient[N-S]` | 1 | 317 / 65 | 488 | pass; 339.992 |
| `HailDaemonKitTests\.Ambient[T-Z]` | 1 | 214 / 49 | 395 | pass; 134.558 |
| `HailDaemonKitTests\.Rightyo` | 1 | 186 / 17 | 228 | pass; 33.560 |
| `HailDaemonKitTests\.(Listener\|WebSocket\|Host\|DeviceVoiceStop)` | 1 | 154 / 27 | 286 | pass; 31.915 |
| `HailDaemonKitTests\.Reply` | 1 | 83 / 19 | 107 | pass with five intentional known issues; 53.388 |

Every selection started tests and exited 0. The broad daemon selections comprise **1,088 functions and 1,711 case
executions**, including all required families. The five known issues are expected `withKnownIssue` injections in
`ReplyRecipientHandoffWaitTests`: one missing-handoff timeout, two cancellation cases, and the timeout/cancellation
cases checking that a second waiter survives. They are existing assertions of the failure-reporting contract,
not new failures, skips or unresolved queue-stop findings. The new and changed focused suites have no known issues.

The separate fresh warnings-as-errors wrapper passed in **237.87 seconds**, reported **`werr build=0`**, and exited
0. Its full build log has **zero errors**, 120 CLT missing-module-cache debug-file warning lines, and no other
warning category. This is a successful Swift warnings-as-errors build with the existing linker debug-info
limitation recorded, not a claim of warning-free linker output.

Host strict SwiftLint and the 120-column check on **all 12 changed Swift files** both exited 0 and produced empty
logs (zero bytes). No lint suppression was added. The exact host commands, relative to this slice's base, are:

```bash
swift_files=( $(git diff --name-only ad25cb8c7ea339ac0455a191747e5caf997283c3 HEAD -- '*.swift') )
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftlint lint --strict --quiet "${swift_files[@]}"
awk 'length($0)>120 {print FILENAME ":" FNR ":" length($0)}' "${swift_files[@]}"
git diff --check ad25cb8c7ea339ac0455a191747e5caf997283c3 HEAD
```

SHA-256 comparison matched all **14 changed Swift/Python source and test files** between host and VM before and
after verification. The workspace `.build`, the separate `vw1212b-werr` build directory, and the temporary compiler
shim/directory were removed after verification; no job build/test processes remained. Build, runtime, wrapper,
checksum and cleanup logs are retained outside the repository under the task's `vw1212b` log names. No generated
build product is committed. Only the authorized `gh issue view 1212 --comments` and `gh pr view 1214` calls were
made; there was no push, PR, GitHub metadata change, online PR-shape/CI check or independent-review claim.

## 1b round 2: target stop marks and every detached job

This round starts at `13ce1b808b3455f9a9cbdf1ca97411123ababe53`, based on main
`cc36af90ccb4bfcc3dc6f282ad13f0bc6f8081a8`. New commits only; the authorized GitHub read is
`gh issue view 1212 --comments`. No push, PR, installation, upload or installed-build replacement is performed.
All tests are synthetic host/CLI checks; no simulator, physical hearing or captured-output round trip is claimed.

### Fixes and design

- `HostReplyDelivery.swift`: stops snapshot the connection's selected target, all covered configured voice-route
  targets, pinned reply targets, in-flight reply targets and request-owner targets. A separate in-flight map follows
  the existing 64-flight bound per connection and is discarded at teardown. Pins retain their global 64-entry bound.
  The queue retains the 256 most recently stopped targets, refreshing order only on another host stop; socket
  enqueue/check/publish never creates or refreshes marks. Target marks survive peer teardown, until eviction or
  daemon epoch replacement. Neither Hello name nor device kind is an identity key.
- The target check precedes recipient resolution, so even an unavailable old text pin produces a content-free skip.
  Resolved admission and final enqueue also compare against both the connection and frame-target marks under the
  stop lock. Existing routing remains authoritative for actual delivery. No extra original-destination record is
  needed: target marks cover pin eviction and reconnection while retaining ordinary routing for post-stop jobs.
  A ticket strictly greater than both marks plays, including after reconnect. Shared-target stops cover both owners.
- `ReplyCommand.swift`: every detached audio job allocates a ticket at `awaitAudioTurn` entry, before attempting
  the lock, checks it after acquisition and carries it on every audio frame. Uncontended jobs are covered during
  the previous reply's playout tail. Only jobs that actually wait emit the queued note/readiness signal.
- `WebSocketListener.swift`: `markQueuedAudio` has no default; every listener call chooses explicitly. Device
  `voice_stopped` and RightyO playback dismissal pass true; mute and privacy entry pass false. Privacy's delivery
  hold continues to govern publication while private.
- `LocalReplyEndpoint+Submission.swift`: queued-audio refusals use ordinary refusal logging and doctor audit
  counts, including the existing audit-failure/request-pending/reply-stopped exclusions. Missing targets are refused
  before a pushed audit entry. Queue allocation/probes do not produce pushed entries.
- Restart outcome: a stale ticket remains a refusal. A waitable CLI job exits 1, keeps text/metadata, sends no audio
  and emits no stop-skip event. No compatibility fallback bypasses the ticket.
- Skip diagnostics retain the last 256 skipped ticket positions, avoiding duplicate probe/publish or mid-stream
  terminal-marker lines for a job. After that bounded cache evicts a position, repeating it can log again.

### Deterministic regressions

- `ReplyQueuedAudioTargetTests`: stop, real disconnect/reconnect, then admission, with retained and evicted text
  pins; preserved delivered text; audio-only pre-stop silence; post-stop audio on the fresh connection; eviction
  plus a real delivered input on B after A's stop; target bound and teardown lifetime.
- `ReplyQueuedAudioAssociationTests`: independent selected, covered, pinned, in-flight and request-owner target
  associations, an unrelated target, and a continuation-held final enqueue to B stopped through A's target mark.
- `ReplyQueuedAudioProbeTests`: request-owner check twice then publish with exact request/frame/flight/pin-state
  assertions; single-selector and ambient-owner audio-only decision sites; real privacy entry and exit through
  `announceEntry`, with the pre-entry ticket still admissible.
- `ReplyQueuedAudioEndpointTests`: real local socket refusal, no missing-target pushed audit, and the exact
  `RefusalSummary` count consumed by doctor. `ReplyQueuedAudioRoutingTests` records shared-target ownership and
  asserts invalid/stale tickets produce no stop-skip log. Existing queue/race suites retain post-stop playback
  without reconnect, both stop sources, coalescing and the final-enqueue race on the same connection.
- Python `QueuedReplyStopTests`: uncontended jobs checked while owning the kernel lock, skipped before rendering
  or admitted with a ticket on every frame; a stale waiting job's exact error/text-only outcome. Existing cases
  retain speech/PCM contention, explicit retry, first-publication stop and legacy refusal coverage.

Negative assertions follow awaited handlers/jobs, explicit continuation gates or socket ping/pong barriers.
There are no settle-then-negative assertions or blocked Swift cooperative threads in the new coverage.

### Round 2 verification commands and load controls

The fresh Dev Work VM workspace is `vw1212b2`, seeded from a host-local bundle without fetching dependencies.
Final Swift source/test verification uses `3198672311f1496a26d0cf8097d4084b0487e339`; the later Python fixture-only
commits culminate in `cce4021a884f42545455bb46bc071ad65ccaea1c`, synchronized before the final full CLI and broad
daemon phases. The Swift files are identical at these heads. Subsequent commits record evidence only. The shared lane is checked
before each phase. Each phase runs at background priority under its own 590-second process-group watchdog,
with signal/finally TERM/KILL cleanup. SwiftPM uses four jobs, each compiler one worker, and automatic resolution
is disabled. The wrapper's separate `vw1212b2-werr` build starts fresh under the same outer cap and external shim.
No synthetic load worker, dependency fetch, simulator, installation or upload runs.

The CLT framework/plugin/linker `flags` array is the same as round 1 above. Exact commands, each a separate phase:

```bash
taskpolicy -b swift build --build-tests "${flags[@]}" -Xswiftc -warnings-as-errors
# Three invocations of the focused Swift selection:
taskpolicy -b swift test --skip-build --no-parallel "${flags[@]}" --filter \
  'ReplyQueuedAudio|DeviceVoiceStop|AmbientWiringStopConfirmation|HostPlaybackStop|AmbientWiringVoiceMute|LocalReplyEndpoint|LocalVoiceGuardsStatus'
# Three invocations of the changed Python suite:
taskpolicy -b python3 -m unittest discover -s Tests/ReplyCLITests -p test_queued_reply_stop.py
taskpolicy -b python3 -m unittest discover -s Tests/ReplyCLITests
# One invocation per broad daemon selection listed below:
taskpolicy -b swift test --skip-build --no-parallel "${flags[@]}" --filter "$selection"
# With the external Swift shim appending -Xswiftc -j1 --disable-automatic-resolution:
/bin/zsh ~/codex-workspaces/vw-werr.sh vw1212b2
```

Initial verification caught test-only actor reads inside assertion expansions, then a genuine missing-target
classification gap (Frame provenance decoding preceded the target guard). The final source fixes that gap before
frame decoding and normalizes malformed queue decoding to `decodeFailure`. A Python iteration caught a fixture
that released contention at ticket issuance, now earlier than lock acquisition; it now waits for the job's shared
waiter flock. The stale-job error was also incorrectly expected on stderr after readiness; the fixture now checks
its error exit, retained text/metadata, no audio and no skip. Existing post-readiness stderr redirection is retained.
These initial failures are preserved in logs; they are not counted as final passing runs.

The first full CLI attempt exposed two additional synthetic-server assumptions: its outcome server and frame
collector treated enqueue/check controls as ordinary reply frames. The outcome fixture now models controls without
consuming frame-response slots, and the collector reuses the existing queue-aware shared server. The known-failed
phase was stopped with TERM/KILL cleanup of its two owned processes before restarting; no other lane was touched.
The full CLI suite is repeated three times after these shared-fixture changes, covering the changed suite as well
as the full requested regression selection.

The carried session-update `replyFlightRevision` LOW (D) remains deferred as described in round 1; this round
does not edit the separate session-update admission files or claim that coalescing bound is fixed. The round-2
fixes require only the four allowed production files.

All final runtime phases passed. Swift Testing functions and parameterized executions are counted separately:

| Selection / phase | Runs | Functions / suites | Case executions per run | Result / seconds |
| --- | ---: | ---: | ---: | --- |
| Final source/test build, warnings as errors | 1 | — | — | pass; 18.72 |
| Focused Swift selection above | 3 | 97 / 22 | 144 | pass; 43.909, 42.472, 42.856 |
| Changed Python `QueuedReplyStopTests` | 3 | 9 Python tests | — | pass; 6.704, 6.861, 6.971 |
| Full Reply CLI | 3 | 135 Python tests | — | pass; 241.855, 240.340, 240.424 |
| `HailDaemonKitTests\.Ambient[A-M]` | 1 | 134 / 25 | 207 | pass; 103.796 |
| `HailDaemonKitTests\.Ambient[N-S]` | 1 | 317 / 65 | 488 | pass; 337.479 |
| `HailDaemonKitTests\.Ambient[T-Z]` | 1 | 214 / 49 | 395 | pass; 135.010 |
| `HailDaemonKitTests\.Rightyo` | 1 | 186 / 17 | 228 | pass; 34.541 |
| `HailDaemonKitTests\.(Listener\|WebSocket\|Host\|DeviceVoiceStop)` | 1 | 154 / 27 | 286 | pass; 30.934 |
| `HailDaemonKitTests\.Reply` | 1 | 92 / 22 | 118 | pass with five intentional known issues; 57.561 |

The broad daemon families comprise **1,097 functions and 1,722 case executions**. Every selection starts tests
and exits 0. The five known issues are the existing `ReplyRecipientHandoffWaitTests` injected missing-handoff
and cancellation reports: one timeout, two cancellation registration cases, and timeout/cancellation of the first
of two waiters. They assert failure-reporting behavior, not new failures or unresolved stop findings. The focused
new/changed Swift suites and all CLI runs have no known issues or skips.

The separate fresh warnings-as-errors wrapper passed in **246.77 seconds** (248 seconds including its wrapper),
reported **`werr build=0`**, and exited 0. Inspection of its full build log found **zero errors and 120 warnings**,
all CLT missing-ModuleCache debug-file warnings, with no other warning category. This is a successful Swift
warnings-as-errors build; it is not a claim of warning-free linker debug-info output.

Host strict SwiftLint and the independent 120-column awk check on **all 16 changed Swift files** both exit 0
and print nothing (zero-byte logs), without new lint suppressions. Exact commands relative to the requested main:

```bash
swift_files=( $(git diff --name-only cc36af90ccb4bfcc3dc6f282ad13f0bc6f8081a8 HEAD -- '*.swift') )
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftlint lint --strict --quiet "${swift_files[@]}"
awk 'length($0)>120 {print FILENAME ":" FNR ":" length($0)}' "${swift_files[@]}"
git diff --check cc36af90ccb4bfcc3dc6f282ad13f0bc6f8081a8
```

Offline source counting uses `scripts/pr-shape.py`'s exact excluded prefixes/suffixes and both names for a rename.
There are **four production files**, both from the round-2 starting head and from main: `HostReplyDelivery.swift`,
`WebSocketListener.swift`, `LocalReplyEndpoint+Submission.swift`, and `ReplyCommand.swift`. There are no renames
and no fifth production file or checker exception is needed. No network PR-shape run is claimed.

SHA-256 comparison matches all **18 changed Swift/Python source and test files** between host and VM before and
after verification. The VM workspace `.build`, separate `vw1212b2-werr` directory, and temporary compiler shim
and directory were deleted after verification; no job build/test processes remain. Logs, checksums and initial
failure evidence are retained outside the repository under the task's `vw1212b2` names. No generated product is
committed. Only the authorized issue read was used; no push, PR, GitHub metadata write, online CI check,
independent-review claim, simulator/device proof, installation or upload is made.
