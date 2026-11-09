# WebSocket receive pump

Part of #1120.

## Implemented invariants

Each peer has one receive pump and one application worker. Network callbacks classify close, error,
missing metadata, unsupported opcodes and missing application content before application dispatch.
Terminal events synchronously retire the peer's `ReplyTransportLifecycle` and clear queued messages
before scheduling actor cleanup. Missing metadata, nil application content and unsupported opcodes
then submit a protocol-error close frame (1002) before finishing, matching the prior close path.
Other terminal events cancel the connection. Neither path waits for the application worker.

Application callbacks enforce the 91,477-byte whole-frame limit before decoding. A pump-side frame
above that limit retires the peer and cancels the connection; it is unreachable in production because
the listener's `maximumMessageSize` rejects it first. Classification decodes transiently on the
listener's shared serial Network callback queue, **outside the pump lock**, once per arriving frame.

Only positively eligible audio retains its decoded `Frame`. Every other message retains its original
raw `Data`, and the worker decodes it exactly once more before `session.receiveDecoded`. Thus non-audio
frames (and protected audio or malformed messages) are decoded twice: once to classify and once to
process. Eligible audio is decoded once. Raw retention bounds queued protected storage by original
wire bytes rather than the decoded object graph; eligible PCM retention stays roughly at wire size.
The second decode uses the identical `FrameCoding.decode` and original bytes, preserving the identical
Frame or nil failure mapping and exact `malformed or oversized frame` response and close disposition.
The one transient classification result, active worker value and listener-bounded receive are outside
the queued-storage accounting.

`AmbientAudioGate.isWindowEligible` is the single ingress eligibility predicate. It requires decoded
`.audio`, pcm16, 16 kHz, mono, no reply descriptor, a stream ID, no segment end, positive sequence,
non-final, 1...8,192 decoded bytes in whole Int16 samples, current protocol version and at most
15,020 original wire bytes. Everything else is protected. The predicate and gate admission share the
same shape helper. The full predicate deliberately mirrors window-only restrictions rather than
applying them to gate admission: the gate still accepts valid starts and finals, and envelope/version
and wire checks remain outside the gate. Admission's stream, selection, policy, rate and refusal
behavior is unchanged. A field-by-field parity test records those distinctions explicitly.

One ordered queue preserves every retained message's relative wire order, including privacy and
input-route controls. Only queued eligible audio can be evicted. The active frame, sequence zero,
final segments, over-bound or ineligible audio, unknown types and every non-audio frame are protected.

| Bound (queued work only) | Value | Action at overflow |
| --- | --- | --- |
| Protected messages | 8 | Retire and terminate; never evict audio to admit them. |
| Eligible audio window | 30 slots | Evict the oldest queued eligible segment, then append in wire order. |
| Eligible per-frame wire bytes | `(8,192 + 2) / 3 * 4 + 4 * 1,024` = 15,020 | Larger messages are protected. |
| Audio-window bytes | `30 * 15,020` = 450,600 | Count and per-frame eligibility enforce the budget. |
| Protected bytes | `2 * 91,477` = 182,954 | Retire and terminate. |
| Hard aggregate bytes, including incoming frame before eviction | `182,954 + 31 * 15,020` = 648,574 | Retire and terminate. |
| Single message | 91,477 | Retire and cancel. |

The hard cap allows a full protected budget plus 30 maximum-size eligible frames and one incoming
maximum-size eligible frame before eviction. Consequently an eligible frame can never terminate
where eviction would have made room. After eviction the queued maximum is 633,554 bytes and at most
38 entries. All bytes use original encoded sizes, including whitespace. Protected finals consume no
audio slot and cannot cause an eviction. A normal 100 ms segment contains 3,200 PCM bytes; the gate's
8 KiB segment cap, rather than the protocol's 64 KiB audio cap, sizes this roughly three-second window.

Eviction only increments counters and records a sequence range under the leaf lock. A dedicated
per-peer utility queue emits `ambient_audio_dropped` with only `count=N stream_seq_range=a-b` outside
the pump lock and off the Network callback queue. At most one reporting task is scheduled or running
per peer. Each report snapshots the accumulated count and minimum/maximum sequence; further drops
coalesce while logging blocks. On return the same task reports the remaining accumulation, including
the final summary after draining or stopping. There is no task per drop and no queued log payload per
frame. Transport rearming, close observation and retirement never wait for this logger. The retained
`droppedAudioCount` remains the lifetime total after retirement. Range tokens carry no stream identity,
text or audio. The window drops less than main's approximately one-second phone backlog in the common case.

### Existing gap limitation

Host drops deliberately have the same gap behavior as phone drops on main. The gate accepts a
strictly increasing sequence with holes and emits the surviving sequence and PCM
(`AmbientAudioGate.swift:430–444`); the listener discards the sequence when forwarding the bytes
(`WebSocketListener.swift:1107–1111`); `RightyoAmbientPipeline.swift:374–376` writes only raw PCM.
Consequently the ambient consumer receives no explicit gap signal for either drop location. This is
a pre-existing limitation. Explicit gap handling for both locations is deferred to
[#1147](https://github.com/mickdarling/hailing-station/issues/1147), outside this change.

`hostDropsMatchPhoneDropsAtGateAndAmbientSink` sends one stream through host eviction and another
with the identical segments already missing at phone arrival. It compares all emitted gate events,
the exact surviving sequence `[0, 6...36]`, concatenated sink bytes (102,400 bytes) and final ending.
It adds no gap semantics.

Protocol closure, hello timeout, listener shutdown, connection failure and send cancellation retire
the same lifecycle and stop the pump. The lifecycle's retirement observer clears the pump even when
listener-wide retirement precedes asynchronous peer cleanup. One receive already submitted to Network
may complete after local stop; it cannot enqueue application work or rearm receiving.

A submission already admitted at paste launch retains its bounded completion. Pending submissions
refuse after retirement. No application task is cancelled to recall an admitted submission. The pump
retains a worker-task snapshot so a caller can join outside the peer actor; closure and shutdown do
not join it. Tasks are created only when an idle worker becomes active, not for queued messages or
transport ping/pong.

## Lock order

The new pump state mutex protects only start/stop flags, receive reservation, worker ownership,
queued representations, eviction, coalesced drop counters and byte accounting. Classification and
worker decoding both run outside this mutex. This mutex is a leaf: no synchronous callback, lifecycle
operation, session operation, Network call or asynchronous wait runs while it is held. Worker task
creation only records the task; it must acquire the state mutex separately before removing data.

Pump stop first retires the lifecycle, releases its gates, and then acquires pump state to clear the
queue. Lifecycle retirement invokes its observer only after releasing the retirement mutex and the
transport publication authority. Registration is under the lifecycle mutex; an immediate observer
callback also runs after releasing it. Pump state never nests a lifecycle, reply-permit, binding,
router, privacy or policy lock. No new path acquires router, privacy or policy while holding lifecycle,
reply permit or binding lease. Existing delivery-stage order remains unchanged.

The worker holds no pump lock while entering the peer actor, `HostSession`, adapter or response send.
Neither pump callbacks nor peer closure turns wait for the worker. The worker's task snapshot is read
under pump state and awaited only after releasing it, by the tests.

## Synthetic evidence

`WebSocketReceivePumpTests.closeObservationRemainsActiveDuringDelivery` uses a loopback WebSocket,
production `TmuxAdapter`, and a guarded scripted runner. Its first message parks in `beforeResponse`
before paste `launch.perform`. After the acknowledged park, the client sends a second application
message followed by transport close. The test awaits the peer's disconnect event and asserts lifecycle
retirement and peer termination while the first delivery remains parked. Only then does it release
and join the recorded worker. No paste or Enter executes, and only the first paste command was prepared.
The companion argument parks before Enter after paste admission: that submission completes exactly
once after close, and the queued second message never starts delivery. Disconnect may be reported as
the classified close or Network cancellation; retirement precedes either cleanup notification.

Audio tests park dispatch with an acknowledged barrier. Burst pressure is equivalent to more than
3 s at 10 Hz; a separate parameter variant paces 36 arrivals at actual 100 ms deadlines for about
3.5 s. Wall-clock pacing shapes arrival only, while barriers establish ordering. These tests prove
survival and ordered newest delivery, close retirement before release, final and sequence-zero preservation under later pressure, real-session privacy and
input-route ordering, hard aggregate termination, fail-closed count overflow and gap parity. A wire
malformed-frame test checks the exact error followed by close code 1002.

Other cases cover ordered text/select/text through real sessions, a transport pong during suspended
application processing, a single active worker, exactly one outstanding receive, count and byte
boundaries, queue clearing on direct lifecycle retirement, malformed metadata, receive failure,
protocol closure, hello timeout and listener shutdown. Synthetic count/byte tests fill exactly to the
bound before overflowing and prove that receiving remains armed at the bound. Loopback count/byte
overflow cases prove peer termination before releasing delivery.

Ordering uses acknowledged entry, release, disconnect and completion barriers. Deadlines are
watchdogs, except the hello timeout and the existing elapsed-age assertion, which explicitly measure
time. No sleep or scheduler-yield loop establishes message ordering. Scripted runners execute no tmux
process. These tests do not establish device capture, playback or a live captured-output round trip.

## Parked text followed by malformed JSON

| Test | Synthetic loopback proof |
| --- | --- |
| `malformedBehindParkedTextCompletesThenCloses` | Ordered response/error/1002 and no later dispatch. |

`WebSocketReceivePumpTests.malformedBehindParkedTextCompletesThenCloses` uses the production
listener and peer, parking the first text before paste launch. Invalid JSON within the size limit,
a valid select and a valid text follow; a transport pong acknowledges wire progress before release.
The first paste and Enter complete once. Its synthetic provider response precedes the exact malformed
error and close 1002. Joining the application worker precedes checks for retirement, ended peer,
closed session, unchanged selection/generation and no later valid-frame authorization or command launch.

Successful text delivery itself returns no protocol acknowledgement. The scripted runner publishes the
synthetic response through `WebSocketPeer.send` after Enter, during the first submission's completion;
the test checks its exact frame before reading the malformed error. This is synthetic reply evidence,
not a provider process or captured-output round trip. The existing idle malformed-wire case remains
`malformedWireMessageSendsErrorThenCode1002`.

The recording authorizer observes valid frames entering authorization, not every invocation of
`HostSession.receiveDecoded`: a closed-session no-op would bypass authorization. The worker join,
closed peer and unchanged selection/command assertions establish no later observable processing;
there is no direct session-entry counter in the existing production seams.

Follow-up verification used the re-synchronized `vwf4` VM workspace at the requested baseline.
Every phase waited for the shared runner to be idle; SSH stdin was `/dev/null`, and all jobs were joined.
The shared helpers and production files were unchanged. The targeted command used the filter
`HailDaemonKitTests\.WebSocketReceivePumpTests/malformedBehindParkedTextCompletesThenCloses`;
the suite filter was `HailDaemonKitTests\.WebSocketReceivePumpTests`, and the final prefix filter was
`HailDaemonKitTests\.WebSocketReceivePump`. All used `WS=vwf4` and `vw327-run.sh`.

| Follow-up phase | Result |
| --- | --- |
| New test, three runs | 1 test each; 0.016, 0.016 and 0.014 seconds; every build/test exit 0. |
| Its suite, three runs | 30 tests each; 8.434, 8.466 and 8.206 seconds; every build/test exit 0. |
| All receive-pump suites, once | 30 tests; 8.513 seconds; build/test exit 0. |
| `~/codex-workspaces/vw-werr.sh vwf4` | `werr build=0`; wrapper exit 0; existing module-cache warnings. |
| Host strict SwiftLint | New Swift file: zero violations, exit 0, with the required Xcode developer directory. |
| Host width check | Swift output empty; document's 40 existing long lines unchanged; no new long lines. |

This follow-up is synthetic package evidence only. It performs no host build/test, physical-device
validation, upload, GitHub call or push.

## Existing test assertion accounting

The original three test-only carries and first-batch accounting remain below. The worker seam supplies
decoded values after removing queued work. No existing assertion is weakened or removed; the original two-frame non-audio byte bound remains enforced.

| Existing test / assertion | Status | Accounting |
| --- | --- | --- |
| `TaskProgressTmuxAdmissionTests.wakeAttemptCommitsOnlyAtPasteAdmission`: tainted refusal type | KEPT | Existing assertion unchanged. |
| Same: no committed attempt on tainted refusal | KEPT | Existing assertion unchanged. |
| Same: no later capture, buffer, paste or key commands on tainted refusal | KEPT | Existing assertion unchanged. |
| Same: established taint's delivered text and Enter | KEPT | Existing assertion unchanged. |
| Same: no attempt at set-buffer preparation | KEPT | Existing assertion unchanged; additional paste-launch case below. |
| Same: no delivered keys before preparation release | KEPT | Existing assertion unchanged. |
| Same: delivered outcome after release | KEPT | Existing assertion unchanged. |
| Same: committed attempt after release | KEPT | Existing assertion unchanged. |
| Same: exact text/Enter after release | KEPT | Existing assertion unchanged. |
| New `wakeAttemptRemainsUncommittedBeforePasteLaunch`: attempt boundary | TIGHTENED | Parks on recorded paste-buffer in `beforeResponse`; asserts no attempt and no delivery before `launch.perform`, then delivered outcome, committed attempt and text/Enter after release. |
| `TmuxRefusalEvidenceTests.aConfirmedInsertThatCameBackIsNamedStaleAndOwnWithItsLengthAndAge`: refusal type | KEPT | Existing assertion unchanged. |
| Same: delivered text and Enter remain unchanged by refusal | KEPT | Existing assertion unchanged. |
| Same: one confirmed submit evidence line | KEPT | Existing assertion unchanged. |
| Same: exactly one refusal evidence line | KEPT | Existing requirement unchanged. |
| Same: parsed whole-second age | KEPT | Existing requirement unchanged. |
| Same: age is within 1...30 seconds | KEPT | Same monotonic deadline; suspending clock wait replaces yield-based polling. |
| Same: exact refusal evidence with the observed age | KEPT | Existing assertion unchanged. |
| Same: token-only evidence excludes synthetic payloads | KEPT | Existing assertion unchanged. |
| `TmuxAuthorityBoundaryTests.retirementAfterPasteCompletesBeforeTheNextTerminalRefusal`: delivered first outcome | KEPT | Existing assertion unchanged. |
| Same: next terminal message has exact notAllowed response | KEPT | Existing assertion unchanged. |
| Same: only first text pasted | KEPT | Existing assertion unchanged. |
| Same: no subsequent capture, set-buffer, paste-buffer or send-keys | TIGHTENED | Each argv element is searched for each command substring, including if-shell command strings. |
| Same: exactly one Enter | KEPT | Existing assertion unchanged. |
| Same: empty input | KEPT | Existing assertion unchanged. |

| Existing F4 test / assertion | Status | Accounting for this batch |
| --- | --- | --- |
| `oneWorkerDrainsInOrderWhileReceivingControls`: parked first frame and ordered values `[1]`, then `[1, 2, 3]` | KEPT | Valid decoded marker frames replace raw one-byte markers; same entry/release barriers and values. |
| Same: peak worker count is one | KEPT | Same assertion. |
| Same: one outstanding receive, maximum one, six receives | KEPT | Same assertions. |
| `overflowTerminatesWithTheWorkerParked`: count eight and bytes two whole frames fit; next terminates | KEPT | Same count/byte inputs and assertions; non-audio budget retains this bound. |
| Same: no work beyond the active frame, termination reason, receive count frozen and maximum one | KEPT | Same assertions. |
| `retirementClearsQueuedMessagesBeforeWorkerRelease`: direct/transport retirement before release | KEPT | Test body and assertions unchanged. |
| Same: only active message processed and no receive rearm | KEPT | Same assertions. |
| `classificationRetiresMalformedAndFailedReceives`: terminal inputs never process, retire, end, one receive | KEPT | Moved unchanged assertions to the classification file. |
| Same: unsupported continuation opcode | TIGHTENED | Additional direct terminal-classification input. |
| `onlyOneSessionReceiveRunsWhileAuthorizationIsSuspended`: active one, no early replies, outstanding one | KEPT | Worker now uses `receiveDecoded`; same assertions and parked authorizer. |
| Same: peak one, final active zero, exact ordered pong replies and maximum outstanding one | KEPT | Same assertions. |
| `PumpRig` shared seam | TIGHTENED | Records drop count/sequence callbacks outside the pump lock in addition to existing termination signal. |

There are no WEAKENED assertions. Existing loopback overflow tests, including the two-frame byte
threshold, are unchanged. New tests assert the audio-specific bound policy separately.

Round-2 changes are accounted for separately below. The elapsed-age clock wait is a time
measurement, not a replacement for an ordering barrier. For paste and Enter, the responder executes
inside `launch.perform` on the guarded runner overload; the paste-launch park precedes that call.

## Round-2 assertion accounting

Every changed assertion is listed below. Unlisted assertions remain byte-for-byte unchanged. No
assertion is WEAKENED. Eligibility now protects finals outside the window, so exact survivor/count
expectations retain one additional legitimate segment; all ordering, retirement and overflow checks
remain enforced.

| Existing assertion | Verdict | Accounting |
| --- | --- | --- |
| `audioWindowSurvivesParkedDispatchAndObservesClose`: drop total before/after release | TIGHTENED | Exact 5 replaces 6 because the protected final cannot evict a segment. |
| Same: per-event counts and sequences | TIGHTENED | Coalesced report counts sum to exactly 5 and flattened ranges equal exactly `1...5`; explicit logging join replaces synchronous-callback timing. |
| Same: exact retained order | TIGHTENED | `[0, 6...36]` replaces `[0, 7...36]`; close still yields no queued processing. |
| Same: receiving armed, alive during pressure, no early processing, close reason/retirement, maximum one receive | KEPT | Same assertions, now also applied to the two real-time paced cases. |
| `hostDropsMatchPhoneDropsAtGateAndAmbientSink`: drop total and exact sequence | TIGHTENED | Exactly 5 drops and `[0, 6...36]`; both phone and host carry the same additional surviving segment. |
| Same: gate events, exact bytes, final ending | TIGHTENED | Exact event/byte equality remains; expected bytes increase to `32 * 3,200 = 102,400`. |
| `aggregateByteCapTerminatesBeforeAnyEviction` → `aggregateCapAllowsEvictionAtMaximumEligibleWireSize`: at-bound alive/zero drops | KEPT | Two full protected wire frames plus 30 eligible frames fit. |
| Same: incoming-frame termination/zero drops | TIGHTENED | Maximum eligible incoming frame must survive with exactly one eviction and receive still armed; the next protected byte still retires with the exact queue-limit reason before release. |
| `protectedAudioKeepsItsPositionDuringLaterPressure`: exact drop count/order | TIGHTENED | Exactly 35 drops and second-stream `6...35` replace 36 and `7...35`; protected starts/final retain identical positions. |
| `privacyControlRemainsAheadOfLaterAudio`: drop count and exact sink calls | TIGHTENED | Exactly 14 drops and `15...45` replace 15 and `16...45`; all audio remains after the preceding privacy/input controls. |
| `PumpAudioPark` release watchdog | KEPT | Entry/release ordering barriers are unchanged; the watchdog grows from 5 to 15 seconds to accommodate paced arrivals, without asserting elapsed processing time. |
| `PumpRig` drop recorder seam | TIGHTENED | Records coalesced counts/ranges on the reporting queue; blocked-logger test checks exact two-report accumulation and retirement before logger release. |

## Review-fix traceability

| Condition | Implementation and synthetic proof |
| --- | --- |
| Real audio sizing and hard cap | `AmbientAudioGate.swift:104`, `WebSocketIngressPump.swift:19` and `:236` define and enforce the budgets. `audioBoundsUseAmbientSegmentSize` checks all five constants; `wholeSampleBoundariesRemainEligible` covers 2 and 8,192 decoded bytes at the exact wire bound; `aggregateCapAllowsEvictionAtMaximumEligibleWireSize` fills both budgets and admits a maximum-size incoming eligible frame before protected-byte or hard-cap termination. |
| Positive shared eligibility | `AmbientAudioGate.swift:493` and admission's shared shape helper at `:500` preserve gate behavior. `ineligibleAudioUsesProtectedCapacity` checks every field, eight protected messages beside a full legitimate window, no eviction, exact retained order, and ninth-message termination. `eligibilityMirrorsGateShapeWithoutChangingAdmission` checks each field against gate acceptance. |
| Retained memory and decoding | `WebSocketIngressPump.swift:188` (`Message.retained`) stores only raw protected Data or decoded eligible audio. `retainedRepresentationMatchesEligibilityAndWorkerDecode` checks unknown and large typed payloads, eligible audio, exact worker Frame equality and sequence classification. Existing malformed response/closure equivalence remains. |
| No decode under lock | `WebSocketIngressPump.swift:106` (`Message.classify`) runs before `state.withLock`; the worker reads `Message.frame` after `next` releases the lock. The callback executes on the listener's shared serial queue. |
| Nonblocking, bounded drop reports | `WebSocketIngressPump.swift:242` (`recordDrop`) only updates counters/range; `:166` (`emitDrops`) uses one separate reporting task. `blockedDropLoggerCannotDelayCloseAndCoalescesRemainingDrops` acknowledges a blocked logger, creates nine more drops, observes retirement before release, then verifies exactly ten drops in ranges `1...1` and `2...10`. |
| Real-time stall | `WebSocketReceivePumpAudioTests.swift:10`, four parameter cases: burst/paced and drain/close. Paced arrivals use actual 100 ms deadlines over 3.5 s with acknowledged dispatch entry/release and close barriers. |
| Transport-terminal protocol error | Raw TCP clients complete a WebSocket upgrade and submit an unsolicited continuation or reserved opcode. Both receive wire close 1002, but Network reports `EPROTO` before delivering opcode metadata, so neither reaches the pump's `protocolError: true` branch. An end-to-end wire proof of that branch is therefore not feasible with these client forms and remains deferred. `networkWireProtocolErrorClosesWithCode1002` records the actual Network error/retirement path. Unit classification/code-1002 coverage remains; `transportProtocolErrorRetiresBeforeSingleCloseSubmission` proves synchronous retirement before close submission and concurrent-close exclusion. |
| Nits | `WebSocketPeer.swift:105` sends terminal protocol errors through actor `close` at `:163`, which checks/sets `closing`; `HostSession.swift:395` says processing; the pump-side 91,477-byte cancellation boundary and production listener rejection are documented above. |
| Existing conditions | Protected ordering, active/start/final preservation, fail-closed count/byte overflow, one worker/receive, closure during delivery and privacy/input ordering retain tests. The gap-parity test remains linked to #1147. |

## Verification

Dev Work VM verification uses Swift 6.3.3 and is synthetic Swift package evidence, with no host build/test, simulator,
physical-device proof, installation, upload or live captured-output round trip. No GitHub call or push
is performed. The VM workspace is re-synchronized after waiting for its shared runner to become idle.
Every SSH invocation uses stdin from `/dev/null` and is joined; no VM job is left running. Shared
helpers are unchanged. A 600-second process-group watchdog reaps each phase on timeout or interruption.
Build/test workers are capped at four; the warnings-as-errors command wrapper adds `-j 4` without
modifying the shared helper.

Commands below use `WS` for the selected VM workspace and runner helpers on `PATH`; operational paths
are deliberately omitted. The targeted changed-suite group runs once and then three repeats, followed
by the same broad groups as the preceding batch, CLI tests and warnings as errors.

```sh
while pgrep -f vw327-run.sh >/dev/null; do sleep 20; done
WS="$WORKSPACE" vw327-run.sh 'HailDaemonKitTests\.(WebSocketReceivePump|TaskProgressTmuxAdmission|TmuxRefusalEvidence|TmuxAuthorityBoundary)'
# Repeat the preceding changed-suite group three times.
WS="$WORKSPACE" vw327-run.sh 'HailDaemonKitTests\.(WebSocket|Listener|HostSession|FinalDelivery|DeliveryAdmission|TaskProgress|Held|LocalDispatch|HailHost|Host|Tmux|Reply|CommandLaunch)'
WS="$WORKSPACE" vw327-run.sh 'HailDaemonKitTests\.Ambient[A-M]'
WS="$WORKSPACE" vw327-run.sh 'HailDaemonKitTests\.Ambient([^A-M]|$)'
python3 -m unittest discover -s Tests/ReplyCLITests
vw-werr.sh "$WORKSPACE"
```

The source/test snapshot is `b176450e18c5130e64ee00f917e64f180269c020`. The final documentation
commit preserves that exact source/test tree; identity is checked on both host and VM after final
synchronization.

| Phase | Result |
| --- | --- |
| Targeted changed suites | 46 tests, four suites; 9.838 seconds; build/test exit 0. |
| Three changed-suite repeats | 46 tests, four suites each; 9.578, 9.797 and 9.873 seconds; all build/test exits 0. |
| Core regression | 520 tests, 105 suites; 149.484 seconds; ten expected known issues; build/test exit 0. |
| Ambient A–M | 111 tests, 21 suites; 93.306 seconds; build/test exit 0. |
| Remaining ambient | 507 tests, 107 suites; 432.575 seconds; build/test exit 0. |
| CLI unittest | 124 tests; 215.121 seconds; exit 0. |
| Warnings as errors | `werr build=0`, wrapper exit 0; 49.42-second build. |

The warnings-as-errors lane emitted the existing Command Line Tools module-cache warnings; the Swift
build and wrapper both exited 0. Shared-runner SHA-256 checksums matched before and after the full lane.
No verification process remains after final synchronization.

Strict host lint passed for all eleven changed Swift files using
`DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" taskpolicy -b swiftlint lint --strict <file>`, with the full
Xcode developer directory selected.
For each file, `awk 'length($0)>120 && $0 !~ /^[[:space:]]*\/\//' <file>` printed nothing. There was
no host build or test. The local production count uses `scripts/pr-shape.py`'s exact exclusions and
both names for renames: **four**, consisting of `AmbientAudioGate.swift`, `HostSession.swift`,
`WebSocketIngressPump.swift` and `WebSocketPeer.swift`. Its GitHub-dependent checks are not invoked.
This batch also changes seven test files and this document, twelve files total. The test files are
`WebSocketReceivePumpAudioTests.swift`, `WebSocketReceivePumpEligibilityTests.swift`,
`WebSocketReceivePumpLimitTests.swift`, `WebSocketReceivePumpLoggingTests.swift`,
`WebSocketReceivePumpPrivacyTests.swift`, `WebSocketReceivePumpTests.swift` and
`WebSocketReceivePumpTransportTests.swift`.

The ten known issues are the unchanged deadline/cancellation self-tests in
`LocalDispatchPreflightWaitTests` and `ReplyRecipientHandoffWaitTests`. Existing real-tmux suites remain
skipped when tmux is unavailable; all pump, session and loopback cases run. Independent round-2 reviews
requested changes; this local batch does not claim approval of its new head.
