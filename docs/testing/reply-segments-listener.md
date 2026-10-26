# Reply segment listener verification (#932, P3)

This is synthetic host-listener evidence on the Dev Work VM. It does not prove a device pause, microphone onset,
physical playback, a captured-output round trip, or the separate P2 producer/P4 device behavior. Segmented frames
are built directly in the tests. Only synthetic identities and loopback sockets are used; no private endpoint, recording or transcript is used.

## Implementation and acceptance coverage

Production changes are limited to four files, all under the security-critical `Sources/HailDaemonKit/Listener/`
path: `HostSession.swift`, `HostReplyDelivery.swift`, `WebSocketPeer.swift` and `WebSocketListener.swift`.
`HostSession` adds `reply_segments` to hello. Both built-in authorizers allow yield; the receiving session also
requires its own ready state and peer capability, and still honors a custom authorizer's denial.

`WebSocketPeer.prepareReplyPublication` asks the session for the peer-specific frame immediately before encoding.
It strips `isSegmentEnd` for legacy peers. Correlated publication, requestless single-selector/ambient-owner fallback,
last-input routing, and host clips (including clips enqueued under privacy holds) all use this preparation boundary.
A held/refused frame never updates segment tracking. Replay on the device consumes already-delivered audio; there
is no separate host replay send boundary. Echo observations still use the original frame as before.

`receiveReplyYield` checks only this session's `repliesInFlight` for reply authority. A successful yield reuses
`stopHeldReply`, refusing the whole reply's later frames without a `stop_playback`. The synchronous shared
`ReplyStopLedger` records stopped ids before the actor turn ends, so a disconnect cannot reroute those frames.
`segment` is logged as a count and never consulted for authority. Unknown, finished, already-stopped and
other-connection ids are silent no-ops.

`noteLastInput` is the backstop hook: `handedOff` invokes it without suspension only after `.delivered` from phone
final text or an ambient dispatch from this connection (the #370 last-input condition). A pending/held adapter,
refusal, confirmation requirement, or handoff reported as `.unowned` never reaches it. On segment-capable
connections it stops every segmented in-flight reply on that connection, without sending `stop_playback`.
Unsegmented replies and other connections are unaffected. Legacy
connections do not run the backstop. This does not change the upstream owner/voice admission rules.

The session's `segmentedReplies` is a subset of the 64-entry `repliesInFlight` list. Oldest in-flight eviction
also removes the segment marker; final audio, per-reply stop, dismiss and teardown clear the appropriate markers.
The listener's stop ledger remains bounded to 64 ids, as does each session's `stoppedReplies`. Teardown clears
only the new segment markers; existing in-flight ids stay available to a dismiss already waiting on the session.

Logs use only the existing structured event fields and content-free details:

- `reply_yield`: `outcome=accepted|ignored|not_authorized segment=<integer>`.
- `reply_backstop`: `outcome=stopped count=<integer>`, only when at least one reply is stopped.

These events contain no reply id, stream id, request text or reply text. The existing session identifier is used
for connection attribution. Stop, dismiss and privacy still stop whole reply ids; acknowledgement/not-sent clips
and echo handling are unchanged.

| Acceptance | Synthetic test |
| --- | --- |
| Hello capability, two peers receiving the same reply, raw legacy byte equality, ordinary and privacy clip paths | `ReplySegmentsListenerTests.sameReplyIsGatedAtEverySendBoundary` |
| Correlated forwarding, connection isolation, another in-flight reply untouched, no stop frame, idempotence, log counts, `replyStopped` publication refusal and absent publication candidate, stop surviving disconnect | `ReplySegmentsListenerTests.yieldIsScopedIdempotentAndStopsPublicationWithoutAStopFrame` |
| Finished and unknown yield, no response or state change | `ReplySegmentsListenerTests.unknownAndFinishedYieldsDoNothing` |
| Legacy unauthorized keep-open refusal followed by `recipientSocketBarrier` and a continued publish | `ReplySegmentsListenerTests.legacyPeerIsRefusedAndRemainsHealthy` |
| Phone and ambient delivery stop multiple segmented replies; leave unsegmented/other-connection replies alone | `ReplySegmentsBackstopTests.deliveredOwnerInputStopsOnlyItsSegmentedReplies` |
| Delivered phone/ambient input with no segmented reply logs nothing | `ReplySegmentsBackstopTests.deliveredInputWithoutSegmentedRepliesDoesNotLog` |
| No backstop on legacy peer (ordinary state and a synthetic segment marker to isolate the capability guard) | `ReplySegmentsBackstopTests.legacyOwnerInputNeverCutsAReply` |
| Refused and held requests do not stop replies; complete released handoff does | `ReplySegmentsBackstopTests.refusedOrHeldInputDoesNotCutUntilACompleteHandoff` |
| Authorizer/capability matrix, pre-hello close without reply-state changes or yield log, custom denial | `ReplySegmentsHostSessionTests` |
| 64-entry bound, oldest eviction, final, yield, privacy stop, dismiss, teardown | `ReplySegmentsHostSessionTests.segmentTrackingIsBoundedAndClearedOnEndStopDismissAndTeardown`, `ReplySegmentsListenerTests.peerTeardownClearsSegmentTracking` |

## Schema/decoder alignment

No protocol production or fixture change is needed. `Schema.swift` requires `reply.audioStream` when `segmentEnd`
is present. `AudioPayload.init(from:)` already rejects reply audio when `streamID == nil` or
`reply.audioStreamID != streamID`. Since `segmentEnd` requires a non-nil stream, a missing/null descriptor stream
cannot pass that existing comparison. `ReplySegmentsProtocolTests.segmentEndRequiresDescriptorAudioStream`
proves missing, null and mismatched descriptor streams are refused; the ordinary round trip proves matching streams
are accepted. Swift also enforces UUID equality, which the JSON schema does not express.

## Verification commands and results

All Swift commands use `taskpolicy -b`, `-j 4`, and these testing flags:

```sh
FLAGS=(
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
)
```

Each phase is wrapped by a 580-second process-group watchdog. The load phase starts exactly four `yes` workers,
with an `EXIT INT TERM` cleanup trap; the watchdog also kills the complete process group on timeout/interruption.
No workers are left running. No network, install, push, remote update, device build or delivery is performed.

The initial implementation commands below were run under that watchdog/trap harness; their counts describe
that earlier test set. Fix-round commands and current counts follow separately.

```sh
taskpolicy -b swift build -j 4 -Xswiftc -warnings-as-errors "${FLAGS[@]}"
taskpolicy -b swift build --build-tests -j 4 "${FLAGS[@]}"
# Five serial repetitions, then five more under four yes workers:
taskpolicy -b swift test --skip-build --no-parallel -j 4 "${FLAGS[@]}" \
  --filter 'HailDaemonKitTests\.ReplySegments|HailProtocolTests\.ReplySegments'
# Broad serial sweep:
taskpolicy -b swift test --skip-build --no-parallel -j 4 "${FLAGS[@]}" \
  --filter 'HailDaemonKitTests\.(Reply|HostReply|PlaybackStop|Dismiss|Stop|Privacy|PrivateReply|HostSession|Negotiation|Capabilit|AmbientWiring|ReplySegments)'
# Additional existing whole-reply privacy/dismiss coverage (HostPlaybackStop is outside that prefix filter):
taskpolicy -b swift test --skip-build --no-parallel -j 4 "${FLAGS[@]}" \
  --filter 'HailDaemonKitTests\.(HostPlaybackStop|AmbientPrivacyReply|PrivateReplyHold|Dismiss)'
```

The repeated filter selects 23 test functions in four suites (56 parameter cases per run). Both five-run phases
pass: 230 function executions / 560 parameter cases across the ten requested repetitions. The build and
`--build-tests` commands pass. The initial broad sweep exposed two older exact hello capability expectations;
those expectations were updated to include `reply_segments` without relaxing the ambient-audio assertions.
The final broad serial sweep passes 258 tests in 57 suites (135.649 seconds), including five intentional known
issues exercised by the existing `ReplyRecipientHandoffWaitTests` watchdog tests. The additional privacy/dismiss
run passes 23 tests in five suites (9.699 seconds). The segment suites have no known-issue exemptions.

A hand check against `.swiftlint.yml` covers new function/type/file sizes, line lengths, parameter counts,
complexity, nesting and force operations. New test files are below the 200-line warning threshold, their function
bodies are at most 40 nonblank/noncomment lines, and their code lines are at most 120 characters. Existing
production file-length suppressions are preserved; no new suppression is added. The SwiftLint executable is not
installed, so this is a hand check, not a SwiftLint run. `git diff --check` passes. The local PR-shape classifier
counts exactly four production files and matches all four against `SECURITY_PATHS`; no GitHub API check is run.

### Fix round 1 verification (#954)

Both builds passed again, followed by three serial `ReplySegments` runs and the requested broader serial filter.
Every command below used `taskpolicy -b`, at most four workers (`-j 4`), the `FLAGS` above, and
`--disable-automatic-resolution --skip-update`. Each phase had a 580-second process-group watchdog with
SIGINT/SIGTERM/exit cleanup and a shell `EXIT INT TERM` kill trap. No load workers were started for this round.

```sh
taskpolicy -b swift build -j 4 -Xswiftc -warnings-as-errors "${FLAGS[@]}" \
  --disable-automatic-resolution --skip-update
taskpolicy -b swift build --build-tests -j 4 "${FLAGS[@]}" \
  --disable-automatic-resolution --skip-update
# Three separate bounded phases:
taskpolicy -b swift test --skip-build --no-parallel -j 4 "${FLAGS[@]}" \
  --disable-automatic-resolution --skip-update --filter ReplySegments
taskpolicy -b swift test --skip-build --no-parallel -j 4 "${FLAGS[@]}" \
  --disable-automatic-resolution --skip-update \
  --filter 'HailDaemonKitTests\.(ReplySegments|HostSession|Negotiation|AmbientAudioSession|PlaybackStop|Privacy)'
```

The focused filter now includes device tests: 26 test functions in five suites, 61 case executions per run.
All three runs passed (0.812, 0.805 and 0.856 seconds): 78 function executions / 183 case executions total.
The broader filter passed 29 test functions in six suites / 35 case executions (0.316 seconds), with no known
issues. This records the exact requested prefix filter; it does not select suites with other prefixes.
The pre-hello test checks the existing malformed-frame close, unchanged reply/selection state, no delivery,
and no `reply_yield` log. Delivered phone and ambient requests without segmented replies produce no backstop log.
SwiftPM emits its existing `--skip-update` deprecation warning. These are synthetic host/package checks;
no simulator or physical-device proof is claimed. `git diff --check` passed.

## Mutation probes

Each probe runs in an isolated scratch copy, restores the baseline source before applying the next mutation,
and rebuilds/tests with the flags and resource bounds above (without `--skip-build`). The scratch baseline first
passes all 26 test functions in five suites / 61 case executions (0.855 seconds, after a 77.61-second build).
These probes were rerun for fix round 1. All four built successfully and were killed by test assertions,
not compiler failures or timeouts. No mutation is applied to the delivery workspace.

| Mutation | Killing test | Result |
| --- | --- | --- |
| Return the original frame from `replyFrameForPeer`, dropping the strip | `sameReplyIsGatedAtEverySendBoundary` (legacy raw bytes and decoded frame), plus correlated legacy forwarding | Killed: five assertions, exit 1 |
| Unconditionally call `stopHeldReply` for the claimed yield id, allowing B to stop A through the shared ledger | `yieldIsScopedIdempotentAndStopsPublicationWithoutAStopFrame` (cross-connection ledger assertion), plus finished/unknown no-op checks | Killed: three assertions, exit 1 |
| Return `stop_playback` on an accepted yield | `yieldIsScopedIdempotentAndStopsPublicationWithoutAStopFrame` (ping/pong barrier sees the unexpected frame) | Killed: one assertion, exit 1 |
| Remove the peer-capability guard from the backstop | `legacyOwnerInputNeverCutsAReply(seededSegment: true)` (synthetic marker isolates the capability guard; in-flight state, marker, stop ledger, event and continued publication) | Killed: four assertions plus `replyStopped`, exit 1 |

The strip, cross-connection and stop-frame mutants use
`--filter 'HailDaemonKitTests\.ReplySegmentsListenerTests'`; the legacy-backstop mutant uses
`--filter 'HailDaemonKitTests\.ReplySegmentsBackstopTests'`.

The legacy probe uses a synthetic marker because ordinary legacy publication strips segment ends and creates no
marker. With zero-count logging suppressed, removing the guard is otherwise silent in that ordinary state.
The first three probes each run five test functions / six cases; the legacy probe runs four functions / seven cases.

A passing parser or test record is not an independent security review. No independent review is claimed here.
