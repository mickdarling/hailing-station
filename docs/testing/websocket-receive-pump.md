# WebSocket receive pump

Part of #1120.

## Implemented invariants

Each peer has one receive pump and one application worker. Network callbacks classify close, error,
missing metadata, unsupported opcodes and missing application content before application dispatch.
Terminal events synchronously retire the peer's `ReplyTransportLifecycle` and clear queued messages
before scheduling actor cleanup. Missing metadata, nil application content and unsupported opcodes
then submit a protocol-error close frame (1002) before finishing, matching the prior close path.
Other terminal events cancel the connection. Neither path waits for the application worker.

Application callbacks decode once with `FrameCoding.decode`, enqueue the decoded result and
immediately arm the next receive. The same 91,477-byte whole-frame limit precedes decoding. A failed
decode is non-droppable; its ordered worker turn retains `HostSession`'s exact `malformed or oversized
frame` error and close disposition without decoding again. Successfully decoded frames reach
`session.receive(frame)`. Unknown types and anything not positively classified as eligible audio
are non-droppable. Classification uses no speculative JSON searches or second payload copies.

One ordered queue preserves the relative wire order of every retained message, including privacy,
input-route and other controls. Only queued, non-final `.audio` with `sequence > 0` can be evicted;
the active frame, sequence zero, final segments and all non-audio frames are protected.

| Bound (queued work only) | Value | Action at overflow |
| --- | --- | --- |
| Non-droppable messages, including sequence zero and final audio | 8 | Retire and terminate. |
| Audio window (`sequence > 0`, including protected finals) | 30 segments | Remove the oldest queued eligible non-final segment, then append in wire order; terminate if none exists. |
| Audio-window byte budget | `30 * 91,477` = 2,744,310 bytes | Bounded by the window count and per-frame limit. |
| Outside-window byte budget, including protected sequence zero | `2 * 91,477` = 182,954 bytes | Retire and terminate. |
| Hard aggregate bytes | `32 * 91,477` = 2,927,264 bytes | Retire and terminate before considering eviction. |
| Single message | 91,477 bytes | Retire and terminate. |

A final with positive sequence occupies an audio-window slot and the non-droppable count; a full
window makes room by evicting its oldest eligible non-final segment. Protected sequence zero stays
outside the audio window and consumes the protected count and outside-window bytes. Thus the queue
has at most 38 entries, and protected messages cannot borrow unbounded capacity. All byte accounting
uses original encoded sizes, including JSON whitespace. These bounds exclude the one active frame
and one listener-bounded receive. A 100 ms ambient segment normally contains 3,200 PCM bytes; the
ambient gate's 8 KB segment cap is narrower than the protocol's 64 KB audio cap. The window budget
conservatively accommodates 30 maximum protocol-sized wire frames.

Each eviction increments `droppedAudioCount`, retained after retirement for tests, and emits
`ambient_audio_dropped` with only `count=N stream_seq_range=a-b`. Each current event covers one
sequence; it carries no stream identity, text or audio bytes. Logging runs outside the pump lock.
The window retains about three seconds of 10 Hz audio, so it drops less than main's phone-side
approximately one-second, ten-segment backlog in the common case.

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
the exact surviving sequence `[0, 7...36]`, concatenated sink bytes (99,200 bytes) and final ending.
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
queued decoded frames, classification, eviction and byte accounting. This mutex is a leaf: no synchronous callback, lifecycle operation, session operation,
Network call or asynchronous wait runs while it is held. Worker task creation only records the task;
the task must acquire the state mutex separately before removing any data.

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

New audio tests park dispatch with an acknowledged barrier while virtual 100 ms sender ticks enqueue
more than 30 segments. They separately prove survival and ordered newest delivery, close retirement
before release, final and sequence-zero preservation under later pressure, real-session privacy and
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

## Existing test assertion accounting

The original three test-only carries remain below. This batch also adapts the pump worker seam from
raw data to decoded frames and moves transport classification tests to a separate file. No existing
assertion is weakened or removed; the original two-frame non-audio byte bound remains enforced.

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

All other tests in those files remain unchanged. The elapsed-age clock wait is intentionally a time
measurement, not a replacement for an ordering barrier. For paste and Enter, the responder executes
inside `launch.perform` on the guarded runner overload; the paste-launch park precedes that call.

## Verification

The verification lane is **Dev Work VM, Swift 6.3.3**. Each source/test snapshot is synchronized from
local HEAD with a Git bundle; no GitHub calls, push, host build or host test is used. The VM waits
until its shared iteration runner is idle before synchronization and before each phase. Each SSH
invocation uses stdin from `/dev/null` and is joined. A 600-second process-group watchdog terminates
and reaps a phase on timeout or interruption. The shared runner helpers are unchanged; their
SHA-256 checksums are compared before and after. Build and test concurrency is capped at four.
The warnings-as-errors helper uses a workspace-specific command wrapper to add `-j 4` to builds.

The targeted filter is run first and the changed-suite group is repeated three times. The same broad
groups as the original F4 verification then run, followed by the CLI unittest suite and the
warnings-as-errors build. Commands are shown with the VM runner helpers on `PATH` and the selected
verification workspace in `WS`; operational paths are intentionally omitted.

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

Final batch verification results are recorded after all phases complete.

Host strict lint and explicit line-length verification apply separately to every Swift file changed
from the original F4 base, including its test-only carries:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b swiftlint lint --strict <file>
awk 'length($0)>120 && $0 !~ /^[[:space:]]*\/\//' <file>
```

Production-file counting uses `scripts/pr-shape.py`'s exact prefix/suffix exclusions and both names
for renames, applied locally to the diff from `36259c17`. It counts **three production files**:
`WebSocketPeer.swift`, `WebSocketIngressPump.swift` and `HostSession.swift`. The GitHub-dependent
checker entry point is not invoked. Tests and this document are excluded by that checker.

No installation, upload, daemon restart, launch-agent change, host configuration change or host tmux
operation is part of this work. The evidence is synthetic VM and loopback evidence; there is no
simulator, physical-device or live captured-output round-trip claim.
